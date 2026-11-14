---
type: log
title: "Formal Verification Decision Log"
description: "Accepted verification approach and evidence boundaries."
tags: [verification, formal, decisions]
---

# Formal Verification Decision Log

## [2026-09-08] decision | Check lifecycle transitions with TLA+ before optional algebra proofs

- Context: The observed defects concern ownership and dependency-state histories. The paper also has algebraic hypotheses that arbitrary Dart callbacks do not satisfy automatically.
- Decision: Define a bounded TLA+/TLC model of the selected serialized runtime as the primary formal verification target, with negative controls and explicit code/test correspondence. Keep Lean optional for separately stated algebraic theorems.
- Consequences: Transition counterexamples have a concrete regression path, while model bounds and callback assumptions remain visible. A model pass supplies neither a Dart refinement proof nor full paper conformance. Model/runner implementation is still absent.
- References: [Model design](spec.md), [paper mapping](../../runtime/lifecycle/researches/spatiotemporal-composability.researches.md).

## [2026-11-02] decision | Start executable verification with the memoized-resource model

- Context: `lazy` added acquisition outside the activation transaction, with single-flight, failure retry, and release that awaits in-flight work. Those interleavings are small enough to check exhaustively and are hard to cover with selected Dart schedules.
- Decision: Add `Lazy.tla` with one `Fault` constant selecting deliberate defects, pin TLC 1.7.4 by SHA-256 (the latest stable release; 1.8.0 is a prerelease), and implement `verification/check.dart` to classify pass, named violation, or incomplete against `scenarios.json`.
- Consequences: Memoized-resource properties have executable bounded evidence and eight matching negative controls. The whole-lifecycle model, evidence-harness tests, and refinement to Dart remain open in G-VR-FORM-001.
- References: [spec](spec.md#artifact-and-runner-contract), G-VR-FORM-001 (closed; its `gap.md` is removed), [model](../../../verification/tla/lifecycle/Lazy.tla).

## [2026-11-09] decision | Close G-VR-FORM-001 and add an integration model for cross-model histories

- Context: A review found three limits. `ClosedActivation` and a stale-node rebuild combined with a rollback had no model (G-VR-FORM-001). Histories that cross the cancellation, disposal, and reporting models, such as a late release failure after a disposal request with several dispose callers, were never checked as one history. A collection membership that shrinks by disposal was outside the fixed reads of `Reconcile.tla`.
- Decision: `Initialize.tla` gains episodes per node, a rebuild of a stale descendant node in the closing reconcile and after a rollback, and escaped activation contexts whose requests the runtime must reject; `ClosedActivation` becomes an invariant. Stale members are not rebuilt there, because their feedback belongs to `Reconcile.tla`. `Reconcile.tla` computes collection membership from the current state, and adds `VisibleBinding`. A new `Integration.tla` composes the cancellation, disposal, and reporting abstractions for two histories and checks the issue routing that the code implements: a late release issue reaches the caller of the canceled activation, not the dispose callers. Each focused model keeps its scope; the integration model checks only histories that cross them.
- Consequences: G-VR-FORM-001 is closed and the topic has no `gap.md`. The run has 131 scenarios. Modeling `ClosedActivation` showed that the runtime guard `_activating` accepted a request from a committed or failed activation while its node stayed registered; the guard now also requires the open episode (`identical(node.inFlight, this)`). No public API reaches that path, so the property has no Dart bridge. Two Dart tests in `cancellation_test.dart` bridge the integration histories.
- References: [spec](spec.md#bounds-and-scenario-matrix), [Initialize model](../../../verification/tla/initialize/Initialize.tla), [Reconcile model](../../../verification/tla/reconcile/Reconcile.tla), [Integration model](../../../verification/tla/integration/Integration.tla), [runtime_state.dart](../../../packages/fp_di/lib/src/runtime/runtime_state.dart), [cancellation_test.dart](../../../packages/fp_di/test/cancellation_test.dart).

## [2026-11-11] decision | Name the dispose failure in the models

- Context: The public type `DisposeIssue` became `DisposeFailure`. The models and the specs named the same thing an issue: one release that ran and failed.
- Decision: The models and the specs use the term dispose failure. The property `NoLostIssue` is `NoLostDisposeFailure`, and `NoCycleIssuePair` is `NoCycleDisposeFailurePair`. The constant `MaxIssues` is `MaxDisposeFailures`. The defect `IssueReplacesCause` is `DisposeFailureReplacesCause`. The scenarios `ReportingNegIssueReplacesCause` and `TeardownWitnessCycleIssues` are `ReportingNegDisposeFailureReplacesCause` and `TeardownWitnessCycleDisposeFailures`. The check of the random histories has the prefix `NoLostDisposeFailure:`.
- Consequences: No state, action, or property changes its meaning. The word failure alone keeps its meaning in the models: a failed creation or a failed activation, as in `MaxFailures`. Each scenario has the same expected result as before. Each scenario of the four changed models that explores its whole state space has the same state counts as before.
- References: [formal specification](spec.md), [lifecycle log](../../runtime/lifecycle/log.md), [test specification](../test/spec.md#traceability-chain).
