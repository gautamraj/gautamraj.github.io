---
title: "Diagnosing memory leaks in Java applications"
date: 2023-07-01
tags:
  - Java
  - profiling
  - memory
---

Despite being a garbage-collected language, memory leaks are still possible (and quite common) in
Java. The simplest example is an in-memory data structure that grows with every unit of work
performed by the system. For example, imagine you store an in-memory log for every request/response
you process, and never bound the size or flush to disk.

Some other examples include:

* File leaks, where a file or socket is not closed. These consume both memory and OS file handles
  and will eventually fail.
* ThreadLocal leaks, where threads are reused between work and threadlocals are not explicitly
  cleared
* Classloader leaks, which involve the use of custom classloaders and class unloading.

# Detection

Memory leaks can be surprisingly challenging to detect. If you just look at a heap diagram of a
normal (non-leaky) application you'll see some sort of sawtooth behavior.

With a leak the floor of the sawtooth rises as each successive GC fails to release some of the
long-lived memory.

In practice what we're looking for is memory pressure. There are a few approaches to identifying
issues.

1. Look at "live" heap
   We can look at the size of the "live" heap that remains after each GC cycle. With a generational
   garbage collector this is roughly the size of the tenured generation.

2. Look at time spent in GC
   Often as a memory leak progresses we'll see a steadily increasing amount of time spent in GC.

All of this information is available from the GarbageCollectorMBean from JMX, the Java Management
Extensions.

# Diagnosing a leak

Now that we know there's a memory leak, how do we actually find and fix it?

Let's use an example:

```java
class LeakyFunction {

  // Track inflight actions.
  private final Set<String> inflightActions = ConcurrentHashMap.newKeySet();

  /**
   * Do something.
   */
  public String call(String actionId, String input) {
    // Record that we're doing something.
    inflightActions.add(actionId);

    String result = doSomeAction(input);

    // BUG: Forget to release resources 30% of the time.
    boolean shouldSkip = RandomUtils.nextDouble(0, 1) < 0.3;
    if (!shouldSkip) {
      // Remove the inflight action.
      inflightActions.remove(actionId);
    }

    return result;
  }
}
```

## Class Histogram

The quickest/simplest option is to take a class histogram using `jcmd`. With our example leak class
we see something like this:

```
[1] % jcmd <pid> GC.class_histogram
num     #instances         #bytes  class name (module)
-------------------------------------------------------
   1:        521778       29893184  [B (java.base@17.0.2)
   2:        511434       20457360  java.util.concurrent.ConcurrentHashMap$Node (java.base@17.0.2)
   3:        520698       16662336  java.lang.String (java.base@17.0.2)
   4:            76        8992320  [Ljava.util.concurrent.ConcurrentHashMap$Node; (java.base@17.0.2)
   5:          2311         440400  java.lang.Class (java.base@17.0.2)
   6:          2345         262640  java.lang.reflect.Field (java.base@17.0.2)
   7:          2525         242160  [Ljava.lang.Object; (java.base@17.0.2)
   8:          1497         206240  [Ljava.util.HashMap$Node; (java.base@17.0.2)
   9:          1142         164448  java.lang.reflect.Method (java.base@17.0.2)
  10:          3275         131000  java.util.HashMap$Node (java.base@17.0.2)
  ...
```

This tells us that `byte[]`, `ConcurrentHashMap$Node`, and `String` take up most of our heap, but it
doesn't tell us where they're coming from. The `ConcurrentHashMap$Node` is the only interesting
piece of information we can really gather from this.

## Full Heap dump

Another option is to take a full heap dump. This lets us look inside of memory and understand which
objects are retaining the most amount of space. We can also trace the objects back to their GC roots
to understand what is holding onto the memory.

We can take a heap dump using:
```shell
jcmd <pid> GC.heap_dump
```

In our example we get a ~100MB file. I've intentionally set the max heap size to 128MB to limit the
size of this heap dump.

(NOTE: The following screenshots are from YourKit but you can also use jvisualvm.)

First we can look for the largest retained objects in memory:

![retained sizes](/profiling/memory_leaks/retained_sizes.png)

Then we can calculate the shortest path to GC roots:

![shortest path gc root](/profiling/memory_leaks/shortest_path_gc_root.png)

We can see that the `inflightActions` Map has been identified as the culprit. Note that this doesn't
tell us which code path is actually causing the leak, but this is typically enough information to
track it down.

The main problem with heap dumps is that they're difficult to take in live production environments.
They can be very large (they are at least the size of the retained set), they lock up applications
while they run, and they can expose sensitive information from production environments like PII and
encryption/decryption keys.

## Java Flight Recorder events

JDK11 introduced Java Flight Recorder (JFR), a low overhead tool for profiling Java applications.

The most relevant ability is to sample events for "Old Objects", including their heap usage and
paths back to the allocation roots. This is available in JDK17.

We run the application for 60s with:
```shell
java -XX:StartFlightRecording:memory-leaks=gc-roots,maxsize=1G,filename=/tmp/ ...
```

The resulting snapshot is only ~700KiB!

Loading this into YourKit we see that there are Old Object Sample Events:
![event counts](/profiling/memory_leaks/old_object_event_count.png)

We can group by the Object Class type and see the 3 classes we saw in the histogram above:
![grouped by event class](/profiling/memory_leaks/group_by_object_event_class.png)

And the stack trace now takes us right to the cause!
![event stack trace](/profiling/memory_leaks/object_event_stack_trace.png)

# References
1. https://hirt.se/blog/?p=1055
2. https://www.theserverside.com/blog/Coffee-Talk-Java-News-Stories-and-Opinions/Fix-Java-memory-leaks-JVM-heap-dumps-Recorder-Mission-Control
