---
description: Verification workflow for shared lifecycle state and Dart/Flutter integration.
paths:
  - "packages/fp_di/lib/src/**"
  - "packages/fp_di_flutter/lib/src/**"
  - "packages/**/test/**"
  - "agents/scripts/validate_specs.dart"
  - "specs/runtime/lifecycle/**"
  - "specs/verification/**"
  - "specs/architecture/**"
globs:
  - "packages/fp_di/lib/src/**"
  - "packages/fp_di_flutter/lib/src/**"
  - "packages/**/test/**"
  - "agents/scripts/validate_specs.dart"
  - "specs/runtime/lifecycle/**"
  - "specs/verification/**"
  - "specs/architecture/**"
---

# Lifecycle Verification Workflow

Canonical test policy: [automated tests](../../specs/verification/test/spec.md).
Canonical formal policy: [formal verification](../../specs/verification/formal/spec.md).
Runtime behavior: [lifecycle spec](../../specs/runtime/lifecycle/spec.md).
Requirements and acceptance criteria: [lifecycle requirements](../../specs/runtime/lifecycle/requirements.md).
Known implementation differences: the `gap.md` of a topic, while one is open.
Accepted rationale: [lifecycle decision log](../../specs/runtime/lifecycle/log.md).
This rule owns operating instructions. The canonical topic owns properties and
assumptions.

This rule adapts the formal-verification workflow of the reference repository.
`fp_di` has no native modules. [CI](../../.github/workflows/ci.yml) runs the
checks below and every formal scenario on each push to `main` and each pull
request. The formal runner, eight
focused models, and one integration model exist under `verification/tla/`:
`lifecycle/Lazy.tla`, `reconcile/Reconcile.tla`, `initialize/Initialize.tla`,
`cancellation/Cancellation.tla`, `disposal/Disposal.tla`,
`reentrancy/Reentrancy.tla`, `reporting/Reporting.tla`,
`teardown/Teardown.tla`, and `integration/Integration.tla`. Preserve
lifecycle IDs in the action-to-code mapping.

## Select the boundary

Apply lifecycle verification when changing shared stateful infrastructure or
scope coordination, especially:

- component shape derivation, activation, rollback, cleanup, or dependency
  withdrawal in `packages/fp_di/lib/src/`;
- `Scope` child scope, binding, and disposal behavior;
- Flutter `ScopeProvider` and `ScopeBuilder` mounting, unmounting, scope replacement, and
  context lookup;
- tests that exercise ordering, concurrency, publisher identity, or failure
  aggregation.

Do not require a formal model for a stateless documentation or example-only
change. Record a justified omission in the owning design when a lifecycle
change is impractical to model or test.

## Environment and execution

Use the repository's configured Dart/Flutter toolchain:

```sh
dart analyze
dart run agents/scripts/test_core.dart
flutter test packages/fp_di_flutter/test
```

`dart test` cannot resolve this Flutter workspace, and `flutter test` runs on
the Flutter engine. Use `agents/scripts/test_core.dart` for core tests so they
run on the Dart VM (V-T-AR-DI-001). Run `flutter pub get` once before it.

Run the smallest affected command first, then the full relevant package checks
when shared lifecycle code changes. The standalone spec validator is:

```sh
dart run agents/scripts/validate_specs.dart --final
```

Formal checks need Java 11+ and the pinned TLC jar:

```sh
dart run verification/check.dart --fetch   # first run downloads and verifies the jar
dart run verification/check.dart --scenario LazyConforming
dart run agents/scripts/test_core.dart verification/test   # the runner's evidence rules
```

The validator checks the canonical requirements/spec/log triad, stable IDs,
ID anchors and ID links, cross-links, gaps, and verification mappings. The root `specs/spec.md` file is
an index document. Topic validation intentionally excludes the index.

## Lifecycle changes

1. Read the owning requirement and current design before changing a boundary.
2. Identify the state owner and the publisher-identity edges. Identify the
   async, mutation, and activation boundaries, the cleanup order, and the
   terminal paths.
3. Preserve meaningful interleavings in tests. Keep cancellation distinct from
   underlying work termination. State assumptions about the Dart event loop.
4. Add a failing regression test for a discovered behavior bug before fixing
   the implementation. Then run the related package checks.
5. Recheck code/spec correspondence after source changes, even when the test
   shape is unchanged. Tests do not replace the canonical contract.
6. Turn a TLC counterexample into a gated Dart fixture. Confirm that the fixture
   fails under the same defect before you name it as a bridge.
7. Turn a reduced fuzz failure into a fixed regression test. Check the models
   for the property that should have found it.
8. Give a new check of the random histories a deliberate defect and a
   detection control (V-T-VR-TEST-006). Read the defect only inside `assert`.

## Add or update a model

Use the [formal artifact contract](../../specs/verification/formal/spec.md#artifact-and-runner-contract)
for model paths, tool pinning, configurations, and evidence. Keep domain properties
in the lifecycle requirements. Keep verification-specific properties in the formal
topic. Run positive and negative configurations with their exact expected results.
A tool error is not a detected counterexample. Report the `report.json` path,
bounds, and state counts. Properties outside existing models remain unexecuted
until the documented gap closes. Run the scenarios of the model that owns the changed code:

| Change | Scenarios |
|---|---|
| `Dependency.lazy`, `Lazy`, or cleanup order in `runCleanups` | `Lazy*` |
| `reconcile`, `deactivate`, `resolve`, or scope disposal | `Reconcile*` |
| `initialize`, `activateMembers`, `activate`, or rollback | `Init*` |
| the cancellation design or its implementation | `Cancel*` |
| `dispose()` callers or the shared disposal | `Disposal*` |
| `disposeScope`, `_releaseOwned`, or the order of scope teardown | `Teardown*`, `Reconcile*` |
| `inMutation`, the mutation zone, or `_RuntimeMutation` | `Reentrancy*` |
| how rollback or release failures reach callers | `Reporting*`, `Integration*` |
| a history that crosses cancellation, disposal, and failure delivery | `Integration*` |
| collection membership, `contributionKeysOf`, or `plainReads` | `Reconcile*` |
| `zipPar`, branch journals, or `branchFailures` | `Cancel*`, `Teardown*`, `Lazy*`; no model covers the branches, so V-T-RT-LC-024 carries their evidence |
| `ScopeProvider`, its inherited widgets, or the reads of `DiBuildContext` | No model covers the adapter, so V-T-AR-UI-011 and V-T-AR-UI-012 carry its evidence: `flutter test packages/fp_di_flutter/test` |
| `ScopeBuilder` | No model covers it, so V-T-AR-UI-013 carries its evidence: `flutter test packages/fp_di_flutter/test/scope_builder_test.dart` |
| `ScopeBoundary` | No model covers it, so V-T-AR-UI-014 carries its evidence: `flutter test packages/fp_di_flutter/test/scope_boundary_test.dart` |
| `disposeHold`, `DisposeHold.close`, or `ignoreHolds` | `Disposal*`; V-T-RT-LC-041 and V-T-RT-LC-042 cover the zone of a close inside a mutation and the `Lazy` holders |
| the inspector in `runtime_inspector.dart` or the extension app `fp_di_devtools` | No model covers the inspector; it only reads. V-T-TL-DT-001 to V-T-TL-DT-005 carry its evidence: `dart run agents/scripts/test_core.dart packages/fp_di/test/devtools_inspector_test.dart` and `flutter test packages/fp_di_devtools/test` |

## Interpret results

- Passing Dart/unit/widget tests are evidence only for their stated fixtures,
  bounds, and platform assumptions.
- A timeout, tool error, skipped test, or unfinished exploration is incomplete
  evidence, not a pass.
- Report finite bounds and assumptions. No package test or future model pass
  proves the whole codebase, every platform lifecycle, or an unconditional
  production guarantee.
