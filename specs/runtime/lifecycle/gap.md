---
type: gap
title: "Runtime Lifecycle — Known Gaps"
description: "Verified open differences between the accepted runtime lifecycle spec and the implementation."
tags: [runtime, lifecycle, gap]
---

# Runtime Lifecycle — Known Gaps

## <a id="g-rt-lc-008"></a>G-RT-LC-008 — No concurrent `zipPar` composition

- Spec: [`spec.md#composition-and-concurrency`](spec.md#composition-and-concurrency) and R-UC-RT-LC-022 require a `zipPar` getter on a record of 2 to 8 `Dependency` values, whose branches overlap and release at the same time, with `branchFailures` on the activation exceptions.
- Implementation: [`dependency.dart`](../../../packages/fp_di/lib/src/model/dependency.dart) defines only `zip`, whose `_zip2` awaits the left `Dependency` before it starts the right one. [`exception.dart`](../../../packages/fp_di/lib/src/model/exception.dart) has no `branchFailures` field and no `BranchFailure` type. `_Runtime.activate` in [`runtime.dart`](../../../packages/fp_di/lib/src/runtime/runtime.dart) reports `ActivationCanceledException` whenever the token was canceled before its catch, whatever the reason, so a branch failure that cancels with `CancelReason.failure` would be misreported. The same path throws before `node.activationFailed = true`, so `ComponentNode.state` and `describe` would show such a node as `inactive`, not as `activation failed`.
- Impact: A component cannot create independent owned values at the same time. Its activation and release take the sum of the branch latencies.
- Resolution condition: The runtime implements the linked design and V-T-RT-LC-024 passes, or the accepted spec is revised.
- Evidence: Inspected code path `_zip2` in `packages/fp_di/lib/src/model/dependency.dart`; no `zipPar` symbol under `packages/fp_di/lib`. Inspected the `canceledBy != null` branch of `_Runtime.activate`, which precedes the only assignment of `activationFailed`.

## <a id="g-rt-lc-011"></a>G-RT-LC-011 — No module in the state of a scope

- Spec: [`spec.md#state-of-the-runtime`](spec.md#state-of-the-runtime), R-UC-RT-LC-028, and R-UC-RT-LC-029 require the member `module` of a `ScopeState`, and an equality of two `ScopeState` values that compares their modules by identity.
- Implementation: `ScopeState` in [`state.dart`](../../../packages/fp_di/lib/src/model/state.dart) has the members `phase`, `nodeStates`, `childStates`, and `changedSince`. Its `==` and its `hashCode` read the phase, the nodes, and the children only.
- Impact: A tool that holds only the root cannot read the declarations of a child scope: `childStates` gives values without a module and without a scope. Two child scopes in the phase `declared` with different modules have equal values.
- Resolution condition: `ScopeState` satisfies the sentences on the module of R-UC-RT-LC-028 and R-UC-RT-LC-029 and V-T-RT-LC-034 passes, or the accepted spec is revised.
- Evidence: Inspected `packages/fp_di/lib/src/model/state.dart`: the constructor `ScopeState._` takes `phase`, `nodeStates`, and `childStates`, and `operator ==` compares those three members.

## <a id="g-rt-lc-014"></a>G-RT-LC-014 — No order exploration for tests

- Spec: [`spec.md#order-exploration`](spec.md#order-exploration) and R-UC-RT-LC-033 require `exploreOrders` in `package:fp_di/testing.dart`, and pumps that start one chosen ready item at a time during an exploration.
- Implementation: `packages/fp_di/lib` has no `testing.dart` and no `exploreOrders` symbol. The pump of `activateMembers` in [`runtime.dart`](../../../packages/fp_di/lib/src/runtime/runtime.dart) and the pump of `releaseAlongReads` in [`runtime_teardown.dart`](../../../packages/fp_di/lib/src/runtime/runtime_teardown.dart) start every ready item and read no choice function.
- Impact: An author who follows the lifecycle notes and tests a module in more than one completion order writes the gates by hand. An order dependence between overlapping effects shows only in a run whose completion order happens to expose it.
- Resolution condition: The implementation satisfies the linked design and V-T-RT-LC-039 and V-T-RT-LC-040 pass, or the accepted spec is revised.
- Evidence: Inspected `packages/fp_di/lib`: the libraries are `fp_di.dart` and `tooling.dart`. Inspected the two pumps, which call `start` for each ready item while items remain.

## <a id="g-rt-lc-015"></a>G-RT-LC-015 — No holds of a disposal

- Spec: [`spec.md#scope-declaration-and-initialization`](spec.md#scope-declaration-and-initialization) (**Holds of a disposal**), R-UC-RT-LC-034, and the paragraph on holds in [`spec.md#formal-verification-boundary`](spec.md#formal-verification-boundary) require `Scope.disposeHold(debugLabel:)`, `DisposeHold.close`, `Scope.dispose(ignoreHolds: true)`, the closing of `Lazy` holders at the request, a disposal mutation that waits for the open holds outside the queue, `Scope.openHolds` with `HoldState` values, the labels of the open holds in `describe`, the `HoldState` values in a `SlowMutation` report of a long wait, an `IgnoredHoldsException` on `Scope.errors` for each call that ignores open holds, and a `Disposal.tla` that models the holds.
- Implementation: `Scope.dispose` in [`scope.dart`](../../../packages/fp_di/lib/src/runtime/scope.dart) takes no argument, and it calls `_runtime.mutate` right after `requestScopeDisposal`. `packages/fp_di/lib` has no `disposeHold` and no `DisposeHold` symbol, and no `openHolds`, `HoldState`, or `IgnoredHoldsException` symbol. `SlowMutation` in [`change.dart`](../../../packages/fp_di/lib/src/model/change.dart) has no `holds` field, and `Scope.errors` documents only automatic reactivation failures. `verification/tla/disposal/Disposal.tla` has no hold.
- Impact: A consumer outside the runtime cannot delay a disposal. A host that must not dispose a scope while a page still reads it waits for the page with its own code and its own time limit.
- Resolution condition: The runtime and `Disposal.tla` implement the linked design, V-T-RT-LC-041 and V-T-RT-LC-042 pass, and the `Disposal` scenarios pass, or the accepted spec is revised.
- Evidence: Inspected `Scope.dispose` in `packages/fp_di/lib/src/runtime/scope.dart`; searched `packages/fp_di/lib` for `disposeHold`.

