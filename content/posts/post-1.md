---
title: "Server-side gRPC Streaming in Java"
date: 2023-04-18
type: "post"
---

One useful feature of gRPC is server-side streaming. You can use this to stream over
large amounts of data, for example the result of a large database query.

The "blocking" API for this looks like:
```java
Iterator<StreamResponse> iterator = blockingStub.makeStreamingCall();
while (iterator.hasNext()) {
    StreamResponse response = iterator.next();
    // do stuff
}
```

However, there are a few hidden issues here:
1. What happens if we get a network error halfway through the stream?
2. What if we want to terminate the stream early?

The answers:
1. Streams are stateful, so generally we need to restart the stream from the beginning.
2. We need to explicitly cancel the context to close the stream, otherwise this will leak memory. We
   can do this by either wrapping the call in a CancellableContext, or by interrupting the thread 
   (from another thread).

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

          // Handle early termination
          if (shouldTerminateEarly(response)) {
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

Not so simple anymore! This litters our actual business logic with complicated retry/termination
handling code.

## AutoCloseable
We can improve the situation by introducing our own iterator that implements `AutoCloseable`:

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

We can then use errorprone to enforce that all callers close the Iterator.

## Retries
Retries are a different story - we cannot escape the fact that our stream is
stateful. One small optimization we can make is to buffer some of our records in
the Iterator itself (with retries!). For example, if we're querying from a
datastore, we can fetch the first several thousand records and store those in an
iterator. We can only do this for the first batch.

## Tracing
One last topic is on tracing. gRPC interceptors are the ideal place to handle
all tracing logic, see https://github.com/opentracing-contrib/java-grpc.
