---
type: log
title: "Verification Test Strategy Decision Log"
description: "Accepted decisions governing lifecycle test evidence and its limits."
tags: [verification, testing, decisions]
---

# Verification Test Strategy Decision Log

## [2026-11-10] decision | Explore lifecycle histories with seeded random command sequences

- Context: Gated fixtures cover only the completion orders that their authors chose, and the repository had no generator of random histories.
- Decision: Add a stateful property test on `kiri_check` that runs seeded sequences of lifecycle commands and gate completions over a small graph. Check invariants over the event trace, not a reference model of the whole lifecycle. Control only callback completion; use no `fake_async`.
- Consequences: `packages/fp_di` gains a dev dependency. A failure is reproducible from its seed and shrinks to a shorter sequence. Evidence stays bounded by the graph size, seeds, and cycles, and the runs do not explore microtask order or timers. `glados` was rejected because it has no stateful testing of command sequences and has had no commit since December 2023.
- References: [`kiri_check` changelog](https://pub.dev/packages/kiri_check/changelog), [`glados`](https://pub.dev/packages/glados), [Random lifecycle histories](spec.md#random-lifecycle-histories).

## [2026-11-13] decision | Mix callback modes, reads, and scopes in the random histories

- Context: Every `create` and `dispose` of the random histories waited on a gate. The graph had plain reads only, one root scope and at most one child, and no key that a nearer scope shadows. A defect on the path of a synchronous callback, a callback that settles in a microtask, an optional or collection read, or a deeper tree of scopes could pass every history. `DependentFirst` read the edges of the descriptor, which say nothing about the value that an optional or collection read received.
- Decision: The graph fixes a mode for each callback: on a gate, synchronous, or in a microtask, with the failing invocations of a callback without a gate fixed by number. It generates optional reads, set and map collections, map entry reads, a tree of up to four scopes, and keys that a descendant shadows. Each `create` receives the values that it read, and the new check `ReadsCurrent` compares them with the trace. `DependentFirst` and `ReleaseOverlap` read the edges between acquisitions from those values. The commands take a scope index, `DisposeParent` is a `StartDispose` of an ancestor, `RetryInitialize` calls `initialize` again after a failed call, and `InitializeBeforeParent` initializes a child before its parent. The descriptor steers the draw toward members of a descendant that read an ancestor key and fail at their first `create`, and toward an optional read of a key of the same scope, because a uniform draw rarely reaches a failed node behind a key or an optional read that gives a value. The run fails when it does not reach a floor for each new kind. The defect `RuntimeDefect.farthestBinding` selects the farthest binding of a key.
- Consequences: The checks see the reads that the runtime made, not the reads that the descriptor declares, so an optional reader that received `null` has no edge. The fixed history of `DropLate` takes the new command names. A callback without a gate fails at a fixed invocation, so a retry can succeed. The order of microtasks between two commands stays out of the runs. The existing controls MUST still detect their defects with the new generator. V-T-VR-TEST-005 and V-T-RT-LC-032 change.
- Alternatives: A random draw at the call of a callback would give a shrink candidate another failure for the same command. A mode for each call instead of each callback adds nothing that the order of the gates does not give. An edge from the descriptor for an optional read would require a release order that the runtime does not owe a reader that received `null`.
- References: [Random lifecycle histories](spec.md#random-lifecycle-histories), [requirements](requirements.md#v-t-vr-test-005), [Explore lifecycle histories with seeded random command sequences](#2026-11-10-decision--explore-lifecycle-histories-with-seeded-random-command-sequences).

## [2026-11-13] decision | Call into the runtime from callbacks, listeners, and the errors stream in the random histories

- Context: The callbacks and the listener of the random histories only recorded events. The lifecycle contract rejects a mutation that a callback requests inside a running mutation, and lets a listener outside a mutation join an accepted disposal. No history requested either, and no listener threw.
- Decision: The graph fixes call sites. The start of a `create` reads its scope and requests the disposal of its scope or of a member, and the request MUST fail with `ReentrantMutationError` and start nothing. A `dispose` callback, a listener of each scope, and the `errors` subscriber read their scope and call into a disposal that a command already requested. One listener throws at a fixed call. The new checks are `NestedCall` and `ListenerFailure`. The defect `RuntimeDefect.lateReentrancyCheck` records the disposal request and cancels the setup in flight before the rejection, and `RuntimeDefect.keepThrowingListener` keeps a listener that threw.
- Consequences: A release that runs after its mutation finished is a site from which the runtime accepts a call, so the sites other than `create` call only into a requested disposal, and the model of the preconditions stays exact. A call of `Scope.child` from a site is out of scope, because the lifecycle contract does not state its result inside a mutation. V-T-VR-TEST-005 and V-T-VR-TEST-006 change.
- Alternatives: A request from every site into any scope makes the result depend on whether the site runs inside a mutation, which the harness cannot read. A subscriber that throws reaches the zone of the runtime and not a recipient that the contract names.
- References: [Random lifecycle histories](spec.md#random-lifecycle-histories), [lifecycle requirements](../../runtime/lifecycle/requirements.md#r-uc-rt-lc-028).

## [2026-11-13] decision | Check the error of get and Module.requiring in the random histories

- Context: The cause in the error of `get` and the selection of the members that require absent keys had unit tests only. Their search depends on the phases of nodes over a tree of scopes and on collection reads, which unit tests fix by hand.
- Decision: After each command, `UnavailableCause` compares `failedNodeStates` of the `get` of each declared key without a value with a search that the harness runs over the generated reads and the reported states. At the start of each case, `RequiringPartition` compares `requiring` and `withoutRequiring` of each module with a fixed point of the harness, for keys that the descriptor fixes. The defect `RuntimeDefect.dropFailedNodes` empties `failedNodeStates`.
- Consequences: The search of the harness repeats the rules of R-UC-RT-LC-030 and reads `missing` from the state, which `RuntimeState` checks. `RequiringPartition` has no defect, because the runtime holds no defect switch in its model code. V-T-VR-TEST-005 and V-T-VR-TEST-006 change.
- References: [Random lifecycle histories](spec.md#random-lifecycle-histories), [lifecycle requirements](../../runtime/lifecycle/requirements.md#r-uc-rt-lc-030).
