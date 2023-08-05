---
title: "Robust iterators for gRPC server-side streams in Java"
date: 2023-04-18
tags:
  - gRPC
  - Java
description: "How to consume gRPC streams in Java using iterators, with retries and without leaking memory."
---

One useful feature of gRPC is server-side streaming. A client can use this to
stream over large amounts of data from a server, for example the result of a
large database query.

The "blocking" API for this has a familiar Iterator API:
```java
Iterator<StreamResponse> iterator = blockingStub.makeStreamingCall();
while (iterator.hasNext()) {
    StreamResponse response = iterator.next();
    // do stuff
}
```

However, there are a few hidden issues to think about here:
1. What happens if we get a network error halfway through the stream?
2. What if we want to terminate the stream early?

Answers:
1. Streams are stateful, so generally we need to restart the stream from the
   beginning. If the server we're connected to crashes, we'll have to start over
   on a different server.
2. We need to explicitly cancel the context to close the stream; otherwise, this
   will leak memory. We can do this by either wrapping the call in a
   CancellableContext, or by interrupting the thread (from another thread).

In practice, our iteration may need to look more like this:
```java
for (int attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
  try (CancellableContext c = Context.current().withCancellation()) {
    Context toRestore = c.attach();
    try {
      Iterator<StreamResponse> iterator = blockingStub.makeStreamingCall();
      try {
        while (iterator.hasNext()) {
          StreamResponse response = iterator.next();

          doStuff(response);

          if (someCondition(response)) {
            // Terminate early.
            break;
          }
        }
      } catch (StatusRuntimeException sre) {
        if (attempt == MAX_ATTEMPTS) {
        // Give up and re-throw.
        throw sre;
        }
      }
    } finally {
      c.detach(toRestore);
    } 
  } 
}
```

Not so simple anymore! This litters our actual business logic with complicated
retry/termination handling code. What we'd like to build is an `Iterator` that
hides this complexity and lets us write simple business logic.

## AutoCloseable
We can improve the situation by introducing our own iterator that implements
`AutoCloseable`:

```java
// Use try-with-resources to automatically clean up
try (Iterator<T> closeableIterator : blockingStub.makeStreamingCall()) {
    while (closeableIterator.hasNext()) {
        T next = closeableIterator.next();
        // do stuff
    }
}
```

The iterator itself will look something like this:
```java
@MustBeClosed
public class CloseableIterator<T> implements AutoCloseable, Iterator<T> {

  private final Iterator<T> grpcIterator;
  private final CancellableContext cancellableContext;
  private final Context toRestore;
  
  public CloseableIterator(Iterator<T> grpcIterator) {
    this.grpcIterator = grpcIterator;
    this.cancellableContext = Context.current().withCancellation();
    this.toRestore = c.attach();
  }
  
  @Override
  public void close() {
    // Detach whenever we exit the try-with-resources block.
    cancellableContext.detach(toRestore);
  }
  
  // delegate the other methods to the underlying Iterator
}
```

We can then use something like the [errorprone
MustBeClosedChecker](https://errorprone.info/bugpattern/MustBeClosedChecker) to
enforce that callers must close the Iterator using try-with-resources.

## Retries
Retries are a different story - we cannot escape the fact that our stream is
stateful and has a single point of failure - the server we're currently
streaming from. One small optimization we can make is to buffer some of our
records in the Iterator itself (with retries!). For example, if we're querying
from a datastore, we can fetch the first several thousand records and store
those in an iterator. Unfortunately we can only do this for the first batch -
once the stream is broken we have to create a new stream and start over.

A better option is to add a pagination parameter to your stream request. If
you're making a database query, a simple approach is to sort your query on some
monotonically increasing field like creation time (with a caveat that these are
typically not truly monotonic and you'll need some buffer). That way anytime the
stream is broken, you can re-establish the stream and resume from the last seen
creation time. You can then hide this pagination in your iterator.

```java
class PaginatingIterator<T> implements Iterator<T> {

  // Start from the epoch
  private long lastSeenTime = 0;
  private Iterator<T> grpcIterator = getNewIterator(lastSeenTime);

  @Override
  boolean hasNext() {
    try {
      return grpcIterator.hasNext();
    } catch (StatusRuntimeException sre) {
      // Iteration failed. Reset our iterator based on the last seen token and
      // try again.
      grpcIterator = getNewIterator(lastSeenTime);
      return grpcIterator.hasNext();
    }
  }

  @Override
  T next() {
    T value;
    try {
      value = grpcIterator.next();
    } catch (StatusRuntimeException sre) {
      // Iteration failed. Reset our iterator based on the last seen token and
      // try again.
      grpcIterator = getNewIterator(lastSeenTime);
      value = grpcIterator.next();
    }
    lastSeenTime = value.getLastSeenTime();
    return value;
  }
}
```

Note that this example is oversimplified - it is essential to take care that
your Iterator does not return duplicates, or to inform your callers that they
should expect at-least-once delivery semantics.

This PaginatingIterator can be combined or chained with the previous
AutoCloseable iterator.

## Tracing
One last topic I'll briefly mention is tracing. gRPC interceptors are the ideal
place to handle tracing logic across all your requests. See
https://github.com/opentracing-contrib/java-grpc for a great example client
interceptor. You can also safely instrument your `AutoCloseable` iterator, which
can be useful for understanding issues that happen above the gRPC layer.
