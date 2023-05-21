---
title: "Retries"
date: 2023-05-10
draft: true
tags:
- reliability
- distributed-systems
---
Retries are a simple but incredibly important part of any system. This post is to share some of my
learnings on the topic.

Retries are necessary in any system that is subject to failures, which is true for any distributed
system.

## When to retry

When we get a failure, we want to retry **if and only if** there is a reasonable
chance that repeating the request may succeed. This means we **should** retry in the following scenarios:

* When we receive a transient failure, e.g. a connection error or timeout.

We _may_ want to retry in the following scenarios:

* When we receive an internal error (e.g. 500). If we choose to retry on internal errors, we should
  be careful to classify all terminal errors under a more specific code, e.g. 4xx/INVALID_REQUEST.
* When a large percentage of retries have failed. At some point we have to consider circuit breaking and returning an error to our client to reduce load on the system.

We should **not** retry in the following scenarios:
* We receive a 4xx error indicating an invalid request.

## Where to retry

Let's say you have a deep callgraph, i.e. A -> B -> C -> D -> E. If E fails, where should you retry?
It may be tempting to initiate all retries from A, because this covers any failures in the entire
system. However, consider that this puts unnecessary load on B, C and D.

You generally want to retry as close to the failure site as possible. In our example, only D knows
what the actual failure is - everything upstream of D only sees that D is returning failures.

## Deadlines

## Retry strategies

## Preventing cascading retries

## Budgets / Circuit Breaking

# References
1. https://landing.google.com/sre/sre-book/chapters/addressing-cascading-failures/
2. https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/