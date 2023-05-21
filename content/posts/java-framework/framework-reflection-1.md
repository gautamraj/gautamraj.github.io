---
title: "Reflections on building a Java service framework (part 1)"
date: 2023-04-19
tags:
- Java
- framework
---

## Background
I spent several years at Stripe building a Java services framework, as a replacement for the existing aging Ruby monolith. There aren't a lot of resources around building a framework, so I thought I'd share some details about the framework, and some of the lessons we learned along the way.

The framework I describe here wasn't built by only me, but was a collaborative effort from across the company, and with a lot of helpful input from our internal developers. My goal in writing about it is to share what we built and the lessons we learned along the way, so that others can benefit from it.

## Philosophy
Our guiding principle was that a service's data should be isolated. The service (and its various supporting components) could access its data, but anything outside the service had to go through a public interface, e.g. a gRPC request or a Kafka event. This is the primary distinction between SoA and a monolith - if you break this rule you end up with a distributed monolith.

The service framework is a point of leverage - you can standardize on a common set of abstractions that everyone learns. Then as engineers switch teams, they still stay within a familiar framework, just with different business logic.

Lastly, we also set out to build an _opinionated_ framework. It was not a goal to support every edge case, but we wanted to have a good set of defaults.

## Design choices

### Service Bundle
We relaxed the data isolation constraint slightly in that we allowed a small set of tightly coupled servers to talk directly to the database. We called this data isolation layer the "service bundle". Within it, there could be multiple kubernetes pods, and each pod had a type of "flavor" (e.g. "rpc-server" for handling gRPC traffic, or "worker" for processing async traffic). These flavors were opinionated about what could run on them, e.g. you couldn't consume from a queue on an "rpc"-flavored pod - that had to happen on a "worker" pod.

### On Open Source
One important decision was to build our own framework instead of using an open-source framework like Spring. This mainly came down to our requirements: we wanted to use gRPC, the Bazel build system, and compile-time dependency injection. At the time there weren't any frameworks that supported both. That said, at the end of the day a framework is mostly concerned with integrating various libraries, and we made _heavy_ use of open-source libraries.

## Configuration
We chose to go with a declarative approach using config files as the source of truth, and tooling that generated code based on what was specified in the config. In other words, you declare what you want in config files and protocol buffers, and the tools will generate a combination of (mostly hidden) glue code, and templates to fill in with your business logic.

### Example
Suppose your want to build a chat service, which has an rpc interface and some asynchronous worker processes for admin actions. A simplified config might look like:

```yaml
bundle_name: chat
pods:
  - flavor: rpc-server
    services:
      - ChatService
  - flavor: worker
    workflows:
      - ExpireOldChats
databases:
  - type: mongo
    name: chatdb
```

From this single file you could then run a tool to generate the skeleton for an entire service. You would then add your business logic to the generated `.java` files, write tests, and then customize the generated kubernetes configuration as needed.

Note that this config is very sparse - there are hidden conventions here. If your pod flavor is rpc-server and there's only one of them, we default its name to `rpc-server`, and its endpoint is `chat-grpc`.

## Code generation

There are several types of code generation:

1. Generating one-off checked-in files that are meant to be edited.
2. Dynamically generating files on the fly from config.
3. Dynamically generating files on the fly from annotations.

In the beginning we made heavy use of type (1) - generating files to check in and edit. We quickly learned that our code generator tools kept breaking because developers would edit these files in ways we didn't expect.

One of the things a framework team has to be good at is migrations. But migrations become very difficult when you expose a large surface area. When you generate one-time checked-in code, any change to the template requires a codemod to migrate all existing code, and also requires approval from that team to modify their code.

This led us to move to type (2), using Bazel macros to generate hidden java files on the fly. This made it slightly more difficult to see the glue code, but it also made it very clear what files were supposed to edited, lowering the cognitive overhead of working with the codebase.

One drawback of type (2) is that anything you want to generate has to be defined in the config, which means you constantly have to re-run the code generator to make any changes. For example, if you want to add a new collection to an existing database you have to re-run the entirety of code generation.

This led us to adopting type (3), where you use annotations to register components of your system. For example, you could declare a database model as:

```java
@Model(db = "chatdb", collection = "ChatLog")
@Id(prefix = "cl", type = RANDOM)
public abstract class ChatLog implements Model<ChatLogPb> {
  public static ChatLog create() {
    return new ChatLogImpl();
  }
}
```

Then the annotation processor can generate a concrete implementation that statically registers this model with the appropriate datastore, and generates all the boilerplate around getters/setters.

### Example tree
A simplified tree then looks something like this:

```shell
.
|-- pub
|   |-- api
|   |   `-- chatapi
|   `-- event
|       `-- chatlog
|-- db
|   `-- chatdb
|       `-- model
|           `-- ChatLog.java
`-- server
    |-- worker
    |   |-- WorkerComponent.java
    |   |-- WorkerModule.java
    |   `-- workflows
    |       `-- CleanupExpiredChatsWorkflow.java
    `-- rpcserver
        |-- RpcServerComponent.java
        |-- RpcServerModule.java
        `-- ops
            `-- chatapi
                `-- PostMessageOp.java

```

It's important to have conventions that separate what is publicly exportable from your bundle (client APIs, events) from the internals (database models and server implementations). You can then use bazel visibility rules to lock down internal packages.

## Dependency Injection
All Java frameworks need _some_ kind of dependency injection framework for modularity and managing complexity. We used [Dagger](https://github.com/google/dagger), which has the nice property of detecting problems with the graph at compile-time. Beware that there is a learning curve to these frameworks, so keeping things simple and avoiding advanced features (like non-Singleton scopes) is a good strategy.

## Ops
At the core of each rpc server is the Op. It connects business logic written in Java to RPC methods - every RPC method has a corresponding op. The op has a synchronous interface - you implement a method that looks like:

```java
public class MyOp implements ServiceOp<Request, Response> {
  
  public Response call(Request request) {
    // do stuff
  }
}
```

We chose to only support synchronous calls for simplicity. Each op runs on a single thread, so we are limited on the number of concurrent requests we can process. However, we decided that the ergonomic benefits of synchronous code were worth the hit to throughput, especially at the scale we typically operate at.

With [Project Loom](https://wiki.openjdk.org/display/loom/Main) expected to be released as stable in JDK21 this is likely to be a good decision in hindsight.

## Workflows
We use Temporal [Workflows](https://docs.temporal.io/workflows#:~:text=Workflow%20Execution%E2%80%8B) to define tasks that run asynchronously, for example periodic hourly tasks, or for cleaning up partial failures in the online RPC path. It's a powerful framework that supports reliable execution of complex multi-step operations with retries. You can read much more about this on the [Temporal](https://temporal.io/) website.

## Observability
The last important piece I'll touch on is the observability story - metrics, logging, tracing. You want a mix of tagged metrics for alerting and dashboards (e.g. prometheus), the ability to query server logs (e.g. splunk), and distributed tracing across multiple systems.

Debugging services in production is difficult, and the best thing you can do to make it easier is to make it easy to instrument code. All gRPC calls should be instrumented out of the box with something like OpenTelemetry with both client and server interceptors. Within the application, an AOP annotation-based AOP approach is the most ergonomic - simply annotate your functions with the metrics you want them to emit. See [this link](https://opentelemetry.io/docs/instrumentation/java/automatic/annotations/) for some great examples.

(to be continued in part 2...)