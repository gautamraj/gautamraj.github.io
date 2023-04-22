---
title: "Reflections on building a Java service framework (part 2)"
date: 2023-04-20
draft: true
---
## Lessons learned
Outline
1. Go easy on dependency injection
2. Lean into AOP
    - Not everything has to be in DI. Ideally we want the framework to be invisible, and you should be able to get by with a few `@Inject` annotations. Similarly, lean into static loggers, statically accessible configs, static timers/tracing.
3. Limit generating checked-in files
   - Avoid too much indirection / too many files
4. Stateful services were a miss
5. IDE tooling is extremely important
6. BUILD file tooling is also important
7. Decide on where config lives: what goes in the yaml vs proto vs Java
8. gRPC+Bazel were great choices
    - gRPC is a great choice to standardize on because of its support for many languages, and its use of typed schemas
    - Bazel encourages project modularity and minimizing common dependencies
9. Cross-service testing
    - Police the codegen and be judicious about what is checked in - checked in code can be modified and is future migration debt. Changing dynamically generated code is much easier than writing brittle codemods.
10. Version your protos and detect breakages
    - Something I wish we did earlier

## Conclusions
* Building a framework is a lot of work
* Organizational challenges