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
