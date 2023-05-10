---
title: "CPU Profiling Java applications"
date: 2023-05-04
draft: true
---
For me, one of the most fun parts of software development is making software run as fast as possible. Performance tuning has very simple objective metrics - maximize throughput, minimize latency and compute cost. It can sometimes require detective work and intuition to understand where a bottleneck might be coming from. Fortunately, there is some excellent tooling for the JVM which I'll talk about here.

Performance is a very broad topic, so for this post I'll focus on CPU bottlenecks. Generally speaking, the approach is to identify hotspots in your code, and rewrite them in a couple of ways:
* Make the expensive thing you're calling faster. Often this means finding a more efficient algorithm or library.
* Call the expensive thing less often, perhaps using caching. There are many instances where you can tradeoff memory for CPU. An in-memory cache is a good way to store computations for future use.

# Tooling
## Profiling
Your first go-to is to run a profiler in production. [async-profiler](https://github.com/async-profiler/async-profiler) is a low-overhead sampling profiler that can provide a very accurate picture of where CPU time is being spent, and does not suffer from the infamous [safepoint bias](http://psy-lob-saw.blogspot.com/2016/02/why-most-sampling-java-profilers-are.html) problem.

You can attach the profiler as a java agent following the instructions here: https://github.com/async-profiler/async-profiler#launching-as-an-agent. You can then load the profiles into a flamegraph visualization tool like [speedscope](https://www.speedscope.app).

## Microbenchmarking
Even once you've narrowed in on the hotspot in code, it's not always obvious what the fix is, and often your intuition can mislead you. What you want is a fast feedback loop as you attempt various fixes to improve performance. [jmh](https://github.com/openjdk/jmh) is a microbenchmarking framework that can be used to accurately benchmark Java code. In particular, it can help ensure that the JVM doesn't optimize away the function you're trying to measure (i.e. prevent dead code elimination).

JMH also supports emitting profile data that can be loaded into speedscope. You can run something like:
```shell
java -jar <bench.jar> -- -prof async:libPath=/path/to/async-profiler/build/libasyncProfiler.so\;output=collapsed\;dir=/path/to/profiles/
```

## Example
TODO
