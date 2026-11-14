---
type: research
title: "Parallel Dependency Effects"
description: "Prior parallel composition, functional resource libraries, and candidate contracts for parallel Dependency effects."
tags: [runtime, lifecycle, concurrency, research]
---

# Parallel Dependency Effects

## Subject

Parallel `Dependency` composition with tracked ownership, cancellation, and inverse execution.

## Why

The [composition contract](../spec.md#composition-and-concurrency) currently sequences every step inside one component.
The [cancellation contract](../spec.md#cancellation) already defines failure regions, atomic primitives, and rollback laws.
This research informs a possible extension of those contracts for bootstrap work with repeated parallel branches and joins.
The findings and candidate contracts below do not change accepted runtime behavior.

## Findings

### Previous fp_di behavior

The inspected Git history contains `Component.zipWith`, `Component.all`, and a concurrent record `zip`.
The history search found no `zipPar` symbol under `packages/fp_di`.

Commit `4701f3a2535b4f11882bcd697a51b5f2976dedf6` contains the implementation immediately before removal:

- `packages/fp_di/lib/src/model/component.dart`, `_Zip._independent`: declared reads and publications select concurrent execution, unless `ordered` is set.
- `packages/fp_di/lib/src/model/context.dart`, `_ActivationContext.branch`: each branch has separate staged publications, cleanup entries, and tracked dependencies.
- `branch` starts both computations and waits for both futures to settle.
- Success absorbs the left branch before the right branch, irrespective of completion order.
- Failure discards the right branch before the left branch. Each branch releases its completed acquisitions in reverse order.
- The parent owns the absorbed cleanup entries after success. The branches do not release successful resources at the join.

Commit `a484d61` removed this composition layer.
The [2026-11-06 decision](../log.md#2026-11-06-decision--split-a-component-into-a-source-and-its-publications) explains the simplification.
Components previously combined publication, resource ownership, and subcomponent composition.
The recorded production usage did not need those combined features.
The decision retained concurrent module activation and made component internals sequential.

Earlier log entries also describe signal trees and parallel rollback laws.
The removed `branch` implementation inspected above waits for `Future.wait` before discarding branches; it does not itself signal sibling cancellation.
Historical design statements therefore do not establish conformance of that implementation to the current cancellation contract.
A restoration needs verification against the current contract, rather than a direct transplant.

### Functional library comparison

The following evidence was inspected on 2026-11-09.
This comparison reads public API contracts and source; it does not execute the external libraries.

| Library and source revision | Computation composition | Resource ownership and finalization |
|---|---|---|
| [fpdart Task][fpdart], commit `27e0576669fc86197db02f042ef3455b2ec153ee` | `flatMap` and `map2` sequence. `traverseList` and `sequenceList` use `Future.wait`; their `Seq` variants sequence. | These Task combinators carry results, without an acquisition journal or registered finalizers. Their parallelism does not supply fp_di rollback. |
| [Cats Effect Resource][cats], 3.x branch, commit `de84c01f76b2f42fcee9d43aba66c82992add103` | `Resource.both` acquires concurrently. Its `Parallel` instance exposes the same behavior through `parMapN`. | Each side records its own finalizers. The sides finalize concurrently; nested resources within each side finalize in reverse acquisition order. Successful resources remain owned through `use`. |
| [ZIO][zio], 2.x branch, commit `d61cf786eac52652e60ffd03c670315792e66bef` | `zip` sequences. `zipPar` runs concurrently and interrupts the other side after failure. Its implementation awaits both fiber outcomes after interruption. | `acquireRelease` registers a finalizer in a `Scope`. Acquisition and release are uninterruptible by default. Scoped finalizers default to sequential reverse registration order; `parallelFinalizers` selects parallel execution. |
| [Effect][effect], npm version `4.1.2` | `Effect.all` accepts a concurrency policy. Concurrent failure can interrupt started effects and skip unstarted effects. | `Effect.acquireRelease` registers a release in the current scope after acquisition succeeds. Acquisition is uninterruptible by default. [Scope][effect-scope] separately selects sequential or parallel finalization. |

These libraries distinguish value composition, execution concurrency, and resource lifetime.
The combination name alone does not establish finalizer order.
Cats Effect gives `Resource.both` an explicit parallel-finalizer contract.
ZIO and Effect also expose finalizer scheduling through scope policies.

The resource mechanisms execute registered finalizers; they do not derive an inverse for arbitrary application effects.
The [paper mapping](spatiotemporal-composability.researches.md#findings) makes the same distinction for fp_di.
A sent request or emitted event is not undone merely because its owning resource closes.

### Current runtime boundaries

[`Dependency.map` and `_zip2`](../../../../packages/fp_di/lib/src/model/dependency.dart) execute sequentially.
[`_ActivationContext.acquire`](../../../../packages/fp_di/lib/src/runtime/runtime_state.dart) records a successful acquisition's cleanup in the activation journal.
Parallel branches need a defined ownership and ordering policy for those entries.
Replacing the two awaits with `Future.wait` alone does not define that policy.

[`activateMembers`](../../../../packages/fp_di/lib/src/runtime/runtime.dart) already schedules new module members along their declared reads.
The same file's `_activateDormant` currently activates eligible existing nodes sequentially.
Parallel component composition and concurrent dormant activation are separate changes.

The component currently waits for every required external key before activation.
A parallel combinator can preserve this derived union shape without providing independent readiness for its internal key reads.
Per-branch external-key readiness would be an additional scheduling contract.

## Implications

### Candidate composition and ownership

Keep the public ownership vocabulary as `Dependency(create:, dispose:)` and `map(create, dispose:)`.
An internal execution structure can represent sequential and parallel composition without adding a public resource or lease type.

```text
forward:  S -> parallel(A1 -> A2, B1 -> B2) -> C
release:  C -> parallel(A2 -> A1, B2 -> B1) -> S
```

The release diagram assumes the parallel branches have independent forward and inverse effects.
Sequential branch cleanup is also a valid scheduling policy under that assumption.
The existing reverse declaration-order rule would need explicit revision before accepting parallel branch cleanup.

Recommended candidate obligations:

- Preserve `map` and `zip` sequencing. Add an explicitly named parallel operation.
- Track each branch's completed acquisitions, failure outcome, and cleanup ownership.
- Transfer successful branch ownership to the containing activation at the join, without releasing the resources.
- Run each branch's cleanup in reverse precedence order. Release downstream users before the resources they use.
- Keep a shared predecessor alive until all consuming branches have settled and their dependent cleanup has finished.
- Commit the component's publication only after every required branch and the downstream creation succeed.
- Preserve the existing derived required, optional, and collection shapes.
- Treat repeated evaluation of a `Dependency` as repeated acquisition unless an explicit sharing contract says otherwise.

Parallel branches can use nested journals or a structured cleanup tree.
Nested regions can also represent a shared-prefix fork.
General DAG scheduling is a separate choice for arbitrary shared nodes and precedence edges.
Nested parallel joins alone do not imply automatic memoization or common-subexpression sharing.

### Candidate failure and cancellation contract

Failure handling needs more than waiting for two successful values:

1. Signal the failing region and its affected siblings promptly. Propagate uncaught failure through the enclosing failure regions.
2. Prevent new forward steps after cancellation. Keep cleanup independent of that cancellation signal.
3. Await started acquisitions before releasing resources they can still use. Include resources acquired after cancellation in cleanup ownership.
4. Attempt each owned cleanup once. Continue other cleanups after a cleanup fails.
5. Return failure after the affected work and cleanup settle. Publish no result from the failed component activation.

Successful atomic acquisition and cleanup registration need one uninterrupted ownership transition.
An acquisition that throws before returning remains responsible for its own partial work, as the current atomic-primitive law states.
An exactly-once cleanup attempt does not guarantee successful state restoration when `dispose` throws.

Dart cancellation remains cooperative inside callbacks.
A future that ignores cancellation and never settles can prevent completion; a signal does not prove termination.
Fail-fast signaling and early return are separate promises.

Specify primary-error selection, additional branch failures, and cleanup failures separately.
Completion order need not determine diagnostic order.
The current module convention suggests declaration order for deterministic reporting, while retaining every relevant failure.

### Algebraic guarantee boundary

The paper's Definition 8 requires a witnessed effect: applying `e` to `s` yields `(s', undo)` with `undo(s') = s`.
Returning a Dart `dispose` callback does not prove this equation.
The relevant state can be an owned state projection, with its observational equivalence stated explicitly.

For sequential effects, the inverse-composition law follows directly:

```text
s0 --A--> s1 --B--> s2
undoB(s2) = s1
undoA(s1) = s0
therefore undoA(undoB(s2)) = s0
```

Theorem 16 needs valid inverse witnesses and actual reverse application order.
It needs no additional independence assumption between these sequential effects.
The law does not validate arbitrary callbacks, failed disposals, or interfering mutations outside the modeled history.

Parallel branches lack a single branch execution order.
Branch-local LIFO and sequential branch cleanup do not recover an arbitrary interleaved history.
Consider four individually invertible operations on a rational state:

```text
branch A: A1 = add 1; A2 = multiply by 2
branch B: B1 = add 3; B2 = multiply by 5

actual application: A1, B1, A2, B2
state:              0 -> 1 -> 4 -> 8 -> 40

actual inverse order: B2^-1, A2^-1, B1^-1, A1^-1 -> 0
whole B, then A:     B2^-1, B1^-1, A2^-1, A1^-1 -> 3/2
whole A, then B:     A2^-1, A1^-1, B2^-1, B1^-1 -> 4/5
```

Both branch cleanup orders preserve local LIFO, yet neither restores the initial state.
This counterexample uses total, correct inverses; an invalid `dispose` is not the cause.
The example does not satisfy the independence condition required for parallel composition.
It shows why that condition cannot be omitted.

A complete journal of actual atomic applications could reconstruct their reverse order.
Future completion order does not identify application order inside asynchronous callbacks.
The current atomic-primitive ownership contract also does not make callback mutations atomic or linearizable.

Definition 42 adds cross-effect transformation commutation and stability of state-selected inverses.
Theorem 43 then permits arbitrary inverse order for pairwise independent witnessed effects.
For structured parallel branches, the corresponding obligation concerns incomparable effects across branches, while each branch preserves its own precedence.
An implementation still needs to establish that its asynchronous histories refine those abstract effects.

The paper's pages 12 and 15-17 were re-read for this distinction on 2026-11-09.
The source and hash are recorded in the [paper mapping](spatiotemporal-composability.researches.md#source).
The existing [formal boundary](../../../verification/formal/spec.md#verification-boundary) treats callbacks as opaque outcomes.
Its scheduling checks do not prove these callback equations or independence conditions.

### Independence and inverse execution

A parallel call under the current unrestricted callback model expresses an author assertion about independent effects.
Disjoint DI keys alone do not prove independence of external mutations or their inverses.
The [paper mapping](spatiotemporal-composability.researches.md#findings) includes forward/inverse commutation and stability of the selected inverse.
Two branches can access the same database safely through independent operations, or conflict despite requiring different keys.
The current API cannot infer either case from key equality alone.

Section 3.4 already provides a proved alternative to asserting independence for every pair.
Theorem 45 establishes independence for operations confined to distinct keys.
Theorem 47 establishes independence for key-mediated effects when all shared keys are commutative and neither provides a key at which the other operates.
Definition 44 also requires stable operation outcomes; forward-write commutation alone is insufficient.
The publisher owns its interface's commutativity obligation (p. 29).
The [key-commutativity research](effect-independence.researches.md) records this discipline and the remaining fp_di mapping obligations.
The abstract result is established; complete mediation, sound footprints, and runtime conformance remain to be supplied.

For established independent branches, parallel cleanup with branch-local reverse order matches Cats Effect's resource composition.
Choose that scheduling policy only after establishing the required independence contract.
Retaining the previous right-to-left cleanup policy while overlapping acquisition does not remove the independence obligation.
The same boundary applies to existing concurrent module activation and teardown.

An unrestricted parallel API can expose an author obligation, but cannot claim unconditional inverse safety.
Stronger guarantees require controlled effect primitives, enforceable ownership boundaries, or explicit proof of the relevant independence laws.
An `independent` Boolean or wrapper alone would remain an assertion, rather than a proof.
The [footprint proposal](footprint-independence.researches.md) evaluates compositional read/write checking and the additional boundary required for deferred effects.

### Verification evidence needed

Use gates and completion events to verify ordering instead of relying on elapsed-time thresholds.

| Fixture | Observable obligation |
|---|---|
| Two gated acquisitions | Both start before either gate opens; result positions follow declaration order. |
| Sequential work inside two branches | Each branch preserves its precedence; the branches overlap. |
| One failed branch, one pending branch | Cancellation is signaled before cleanup; shared predecessors stay alive while the pending branch can use them. |
| A resource returned after cancellation | Its cleanup is attempted once; no later forward step or publication occurs. |
| Failure in the post-join step | All branch resources remain owned and are released after their downstream users. |
| Simultaneous branch failures and failing cleanup | Relevant causes survive aggregation; cleanup continues; reporting order follows the selected policy. |
| Owner disposal, withdrawal, and lazy creation | Cancellation reaches the correct region; resources have one cleanup owner; no failed activation commits. |
| Shared-prefix branching and repeated descriptors | Shared resources follow explicit sharing rules; descriptor reuse alone does not silently memoize. |

Extend the relevant lifecycle model before claiming coverage of branch ownership, late completion, and inverse precedence.
Existing module-concurrency tests and models do not automatically cover new internal parallel regions.

## Open Questions

- Choose `zipPar`, `parZip`, or another public spelling; no parallel getter is accepted yet.
- Decide whether parallel composition retains pairwise author assertions or adopts the paper's key-mediated contracts and a sound conflict checker.
- Choose parallel or reverse declaration-order cleanup between independent branches.
- Define how additional creation failures fit the public exception model, separately from `rollbackIssues`.
- Decide whether the first extension includes shared-prefix branching or only independent dependency composition.
- Decide whether collection traversal and bounded concurrency belong to the same extension.

[fpdart]: https://github.com/SandroMaglione/fpdart/blob/27e0576669fc86197db02f042ef3455b2ec153ee/packages/fpdart/lib/src/task.dart
[cats]: https://github.com/typelevel/cats-effect/blob/de84c01f76b2f42fcee9d43aba66c82992add103/kernel/shared/src/main/scala/cats/effect/kernel/Resource.scala#L248
[zio]: https://github.com/zio/zio/blob/d61cf786eac52652e60ffd03c670315792e66bef/core/shared/src/main/scala/zio/ZIO.scala
[effect]: https://github.com/Effect-TS/effect/blob/effect%404.1.2/packages/effect/src/Effect.ts
[effect-scope]: https://github.com/Effect-TS/effect/blob/effect%404.1.2/packages/effect/src/Scope.ts
