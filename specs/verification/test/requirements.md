---
type: requirement
title: "Verification Test Strategy Requirements"
description: "Observable test policy and evidence boundaries for the Dart runtime and Flutter adapter."
tags: [verification, testing, dart, flutter]
id_prefix: "VR-TEST"
---

# Verification Test Strategy Requirements

[Test design](spec.md) · [Runtime lifecycle requirements](../../runtime/lifecycle/requirements.md) · [Lifecycle specification](../../runtime/lifecycle/spec.md)

## Problem Statement

`fp_di` has two lifecycle boundaries: a Dart runtime that owns mutations and
dependencies, and a Flutter adapter that publishes scopes to the widget
tree. Tests need to make ordering, ownership, rollback, and visibility
observable without relying on scheduling luck.

The lifecycle topic defines the runtime contract and its `RT-LC` requirement
and verification IDs. This topic defines how package tests provide bounded,
repeatable evidence for that contract. A passing package test is evidence for
its named fixture and assumptions; it is not a proof of the whole lifecycle
contract or of every Flutter platform.

A gated fixture covers only the completion orders that its author chose. A
defect that needs an unusual order of completions, failures, and disposals can
pass every such fixture. Random histories with a reproducible seed explore
more of these orders and keep each failure reproducible.

## Scope

- Deterministic Dart tests for activation, rollback, teardown, publisher withdrawal, reconciliation, and composition.
- Explicit `Completer<void>` gates and event traces for asynchronous overlap and ordering assertions.
- Core scope and Flutter widget-scope tests for visibility, ownership, unmount, late completion, and context replacement.
- Package-boundary commands and static analysis evidence for changed lifecycle code.
- Traceable mapping from this topic's test-policy IDs to the canonical `RT-LC` criteria.
- Bounded random command sequences over create and dispose callbacks that the harness owns, with a reproducible seed, a reduced failing sequence, and invariant checks over an event trace.
- Random histories that mix callbacks on gates with callbacks that settle synchronously or in a microtask, optional and collection reads, a tree of scopes with shadowed keys, calls into the runtime from callbacks, listeners, and the `errors` stream, and the cause of a lookup without a value.
- Persistent fuzz run manifests, source provenance, coverage counts, and failure reports.
- Persistent benchmark manifests, source provenance, operation timings, and sample statistics.

## Out of Scope

- Redefining the runtime lifecycle contract or copying the canonical `RT-LC` requirements into this topic.
- Claiming that package tests prove the paper's general theorems, all interleavings, arbitrary user dispose functions, or all Flutter platforms.
- A Lean proof or a CI workflow.
- A reference model of the whole lifecycle that a random run compares against. Random runs check invariants over the recorded trace instead.
- Random exploration of timers, timeouts, or wall-clock behavior. Unit tests own the slow-mutation warning.
- Random exploration of the order of Dart microtasks. A random run controls only the order in which callbacks on gates complete; a callback without a gate settles at a fixed point.
- A call of `Scope.child` from a callback or a listener. The lifecycle contract does not state the result of a child creation inside a mutation.
- Treating the known lifecycle gaps as closed because adjacent tests pass.

## User Stories

- <a id="r-us-vr-test-001"></a>**R-US-VR-TEST-001** — As a runtime maintainer, I want lifecycle tests to control asynchronous completion explicitly, so that failures identify a reproducible ordering or ownership violation.
- <a id="r-us-vr-test-002"></a>**R-US-VR-TEST-002** — As an application author, I want core and Flutter checks to run at their package boundaries, so that adapter regressions and runtime regressions are distinguished.
- <a id="r-us-vr-test-003"></a>**R-US-VR-TEST-003** — As a reviewer of formal or lifecycle evidence, I want each result to state its fixture bounds and known gaps, so that a passing test is not mistaken for full conformance.

## Use Cases

- <a id="r-uc-vr-test-001"></a>**R-UC-VR-TEST-001** — Exercise a controlled runtime mutation
  - Actor: test author
  - Trigger: activation, disposal, publisher replacement, or the initialization of a scope
  - Preconditions: a fresh `Scope` and a bounded fixture
  - Main flow: declare components with explicit dispose functions, use event traces and completer gates, then assert publication, release attempts, and ordering.
  - Alternative flows: inject a failing acquisition or dispose function and assert aggregation and remaining cleanup.
  - Postcondition: the test has a deterministic pass/fail assertion and disposes its scope.

- <a id="r-uc-vr-test-002"></a>**R-UC-VR-TEST-002** — Exercise a scope boundary
  - Actor: test author
  - Trigger: child-scope lookup or scope replacement in a widget tree
  - Preconditions: parent and child environments or a `WidgetTester`
  - Main flow: assert nearest-publisher visibility, sibling isolation, owned teardown, and late-completion cleanup.
  - Alternative flows: remove a publisher and assert the documented result.
  - Postcondition: caller-owned contexts remain caller-owned and owned scopes are disposed.

- <a id="r-uc-vr-test-003"></a>**R-UC-VR-TEST-003** — Report bounded evidence
  - Actor: maintainer
  - Trigger: a lifecycle change or verification run
  - Preconditions: the relevant package command and test target are known
  - Main flow: record the exact command, target files, fixture assumptions, and observed assertions.
  - Alternative flows: a missing regression or known implementation gap remains identified as incomplete evidence.
  - Postcondition: the result does not claim more than the executed checks establish.

- <a id="r-uc-vr-test-004"></a>**R-UC-VR-TEST-004** — Explore random lifecycle histories
  - Actor: test harness
  - Trigger: a test run with a given seed
  - Preconditions: a small fixed component graph in a fixed tree of scopes. The harness owns every create and dispose callback: a callback waits on a gate that the harness owns, or settles without a gate. The declaration order of the graph MUST NOT follow its dependency order.
  - Main flow: The harness MUST run a random sequence of lifecycle commands and gate completions. The graph MUST fix every choice that a callback, a listener, or a subscriber makes, so no callback draws a random value. After each command, the harness MUST let the runtime reach its next wait before the next command. The harness MUST hold every future that a command, a callback, a listener, or a subscriber gets from the runtime. The harness MUST check each value that a create reads against the graph and the trace, so the runtime is not checked against itself. At the end, the harness MUST complete every open gate in a fixed order and check the invariants over the recorded trace.
  - Alternative flows: A violated invariant, an incomplete held future, or a result that no injected failure or requested cancellation explains MUST fail the run. The report MUST name the seed and a reduced command sequence that still fails. An invalid run setting, or a run that exercises no activation, acquisition, or teardown, MUST fail instead of passing empty. A run that does not reach each kind of callback, read, scope, and call that the graph can generate MUST also fail.
  - Postcondition: The same seed gives the same graph, the same command sequence, and the same trace. Every rerun and every shrink candidate of one case uses the same graph.

- <a id="r-uc-vr-test-005"></a>**R-UC-VR-TEST-005** — Confirm that a check of the random histories detects its defect
  - Actor: test harness
  - Trigger: a run of the core suite
  - Preconditions: Dart assertions are enabled. The runtime has a test-only deliberate defect for the check, read only inside an `assert` ([R-UC-RT-LC-024](../../runtime/lifecycle/requirements.md#r-uc-rt-lc-024)).
  - Main flow: The harness MUST set one deliberate defect, run the random histories with a fixed seed and small bounds, and expect a violation of the named check. A fixed history MAY replace the random histories when it reproduces a formal counterexample. One test MUST set the defect, run the histories, decide detection, and reset the defect, so test order and test selection cannot separate them. When the defect is also a self-check fault, the harness MUST mute the self-checks, so the check of the histories meets the defect and not the self-check.
  - Alternative flows: A run that reports no violation of the named check MUST fail and name the defect, the seed, and the checks that reported instead. A check without a reachable defect MUST be listed as without automatic evidence.
  - Postcondition: The harness resets every defect, fault, and mute after each control, so no other test sees them.

- <a id="r-uc-vr-test-006"></a>**R-UC-VR-TEST-006** — Retain fuzz run evidence
  - Actor: maintainer
  - Trigger: the repository test command selects a lifecycle fuzz suite or its detection controls
  - Preconditions: the workspace dependencies are resolved
  - Main flow: Each invocation MUST create a distinct evidence directory under `output/`. The evidence MUST identify the selected suites, arguments, seeds, bounds, SDK, dependency lock, and actual source content. The evidence MUST retain observed coverage counts and any reported reduced failure sequence.
  - Alternative flows: A failed invocation MUST retain its evidence. A missing completion, malformed event log, or selection without executed fuzz tests MUST NOT count as passed evidence. A detected source change or provenance collection problem MUST prevent passed evidence. An interrupted invocation MUST retain its initial manifest without a passed result.
  - Postcondition: Later invocations preserve earlier evidence directories, including concurrent invocations.

- <a id="r-uc-vr-test-007"></a>**R-UC-VR-TEST-007** — Retain reproducible benchmark samples
  - Actor: maintainer
  - Trigger: an explicit benchmark invocation
  - Preconditions: the workspace dependencies are resolved and the requested sample count is positive
  - Main flow: Each invocation MUST retain a distinct manifest and source provenance under `output/`. The record MUST identify its workloads, timing boundaries, units, sample count, execution order, VM mode, and warm-up policy. Each sample MUST retain its raw operation timings and execution result. Complete results MUST include the samples, median, minimum, and maximum for each expected metric.
  - Alternative flows: A failed sample MUST retain its logs and partial observations. A missing sample or metric MUST NOT become a zero measurement. Failed, incomplete, or source-inconsistent execution MUST NOT produce passed benchmark evidence. An interrupted invocation MUST retain its initial manifest without a passed result.
  - Postcondition: Later invocations preserve earlier evidence. Benchmark statistics describe the recorded environment and workloads; they do not establish a production latency target.

## Verification

- <a id="v-t-vr-test-001"></a>**V-T-VR-TEST-001** `[test]` Given a core runtime lifecycle scenario, when its package test runs with a fresh context and explicit event assertions, then activation failure, rollback, teardown, and publisher withdrawal outcomes are asserted without timing-based ordering checks. Covers: R-US-VR-TEST-001, R-UC-VR-TEST-001.
- <a id="v-t-vr-test-002"></a>**V-T-VR-TEST-002** `[test]` Given independent module members and a member that requires a token key, with gated acquisitions, when completer gates are opened in the test-controlled order, then overlap or sequencing, settlement before rollback, and release in reverse creation order are observable in the recorded trace. Covers: R-US-VR-TEST-001, R-UC-VR-TEST-001.
- <a id="v-t-vr-test-003"></a>**V-T-VR-TEST-003** `[test]` Given parent, child, and sibling scopes and a scope published to widgets, when lookup, publisher change, or scope replacement occurs, then visibility, ownership, and cleanup are asserted at the corresponding package boundary. Covers: R-US-VR-TEST-002, R-UC-VR-TEST-002.
- <a id="v-t-vr-test-004"></a>**V-T-VR-TEST-004** `[test]` Given a lifecycle change, when the relevant runtime and adapter test commands complete, then the recorded result names the command and finite fixture scope and reports failures or skipped checks as incomplete evidence. Covers: R-US-VR-TEST-002, R-US-VR-TEST-003, R-UC-VR-TEST-003.
- <a id="v-t-vr-test-005"></a>**V-T-VR-TEST-005** `[test]` Given a small component graph in a shuffled declaration order, in a tree of up to four scopes with keys that a nearer scope shadows, with plain, optional, and collection reads, set contributions, and map entries, whose create and dispose callbacks wait on gates or settle synchronously or in a microtask and fail where the graph fixes it, with reads and mutation requests into the runtime from callbacks, listeners, and an `errors` subscriber, and with a fixed seed, when random sequences of initialize, a retry of a failed initialize, dispose, member withdrawal, child scope creation, the opening and the closing of holds of a disposal, a disposal that ignores the holds, and gate completion or failure run to the end, then the shape of each built module matches the reads of the generated graph; every held future is complete; every error of a held future and of the `errors` stream is an injected failure, the cancellation of a requested disposal or withdrawal, the report of a listener that throws, or the report of a disposal that ignored open holds; no disposal of a scope starts while a hold of the scope or of a descendant is open, unless a call ignored the holds; no member of a scope whose disposal was requested starts a setup; `openHolds` lists the open holds of each scope and of its descendants; each value that a create reads is the current value of a node that the reader may read: for a plain key the value of the nearest scope that holds an active node of the key, for an optional key `null` only when no scope holds one, and for a collection key the values of the visible contributions in their order; no acquisition starts its release before every acquisition that read its value finished its release; the releases of one node do not overlap; every acquired resource has at most one release attempt, and exactly one after its scope is disposed; during a scope disposal, a node whose readers finished their releases starts its release while an unrelated release waits on a gate; a failed activation leaves no published value; every failed release reaches exactly one mutation result; all calls that join one disposal in progress receive the same result; a call after the disposal finished completes at once with success and starts no release; a mutation that a create requests fails with `ReentrantMutationError` and starts nothing; a call from a callback, a listener, or a subscriber into a requested disposal or withdrawal gets `ReentrantMutationError`, the result of that disposal, or an immediate success; a read in a callback changes no `revision`; a listener that throws is removed and reported once; the `UnavailableKeyException` of `get` for a key without a value holds the failed nodes that a search over the generated reads and the reported states finds; for each module and the keys that the graph fixes, `requiring` and `withoutRequiring` partition the module as their rules state; a failing run reports its seed, a reduced command sequence, and the shape of the failing graph; and an invalid run setting, an empty run, or a run that does not reach each generated kind of callback, read, scope, and call fails. Covers: R-US-VR-TEST-001, R-US-VR-TEST-003, R-UC-VR-TEST-004.
- <a id="v-t-vr-test-006"></a>**V-T-VR-TEST-006** `[test]` Given assertions enabled and one deliberate runtime defect for each check of the traceability chain that has one, with the self-checks muted when the defect is a self-check fault, when the random histories run with a fixed seed and small bounds, then each run reports a violation of its named check, also under a random test order; given the fixed history of `DropLate`, then it passes without the defect and reports `NoLostDisposeFailure` with it; given a defect that records a reentrant disposal before it rejects it, a defect that drops the failed nodes from the error of `get`, a defect that reads the farthest binding of a key, and a defect that keeps a listener that threw, then the runs report `NestedCall`, `UnavailableCause`, `ReadsCurrent`, and `ListenerFailure`; given a self-check fault without the mute, then the run reports an unexplained outcome; and a control whose check reports nothing fails and names the defect, the seed, and the checks that reported. Given the fixed history of a member of two steps whose disposal is requested while its first `create` waits, then it passes without a defect and reports `NoSetupAfterRequest` with the defect that skips the checkpoint. Covers: R-US-VR-TEST-003, R-UC-VR-TEST-005.
- <a id="v-t-vr-test-007"></a>**V-T-VR-TEST-007** `[test]` Given a manual zone that stops after its body, a scope and its nodes used in and outside that zone, and a Flutter `testWidgets` body with a `setUp` and a `tearDown`, when an operation in one zone is followed by an operation in the other, then the later operation completes within a bound, and the check is red when the runtime awaits a future of the earlier zone. Covers: R-US-VR-TEST-001, R-US-VR-TEST-002, R-UC-VR-TEST-001.
- <a id="v-t-vr-test-008"></a>**V-T-VR-TEST-008** `[test]` Given successful, failed, skipped, and truncated fuzz event logs, when the evidence recorder completes, then only a complete successful execution receives a passed manifest. Separate invocations retain distinct directories. A source edit changes the recorded source identity. An actual fuzz invocation retains its configuration, coverage, and test results under `output/`. Covers: R-US-VR-TEST-003, R-UC-VR-TEST-006.
- <a id="v-t-vr-test-009"></a>**V-T-VR-TEST-009** `[test]` Given complete benchmark samples and failed, skipped, malformed, or missing observations, when the benchmark recorder completes, then only complete consistent execution receives passed evidence. Each expected metric retains its original values and correct median, minimum, and maximum. Missing or duplicate metrics prevent complete results. An actual invocation retains its manifest, source identity, logs, and measured samples under `output/`. Covers: R-US-VR-TEST-003, R-UC-VR-TEST-007.
- <a id="v-l-vr-test-001"></a>**V-L-VR-TEST-001** `[lint]` Given the workspace and the configured Dart/Flutter SDK, when static analysis runs, then the relevant package analysis completes without analyzer diagnostics. Covers: R-US-VR-TEST-002, R-UC-VR-TEST-003.

The exact runtime behavior represented by these tests remains owned by the
[canonical lifecycle verification criteria](../../runtime/lifecycle/requirements.md).
This topic's `V-*` IDs describe test method and evidence quality; they do not
replace or restate any `RT-LC` ID.

## References

- [Canonical lifecycle requirements](../../runtime/lifecycle/requirements.md), including the `RT-LC` acceptance and verification IDs.
- [Canonical lifecycle design and evidence boundary](../../runtime/lifecycle/spec.md).
- [Lifecycle verification workflow](../../../agents/rules/verification.rules.md).
