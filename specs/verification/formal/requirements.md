---
type: requirement
title: "Formal Verification Requirements"
description: "Model scope, reproducibility, and evidence obligations for lifecycle verification."
tags: [verification, formal, lifecycle]
id_prefix: "VR-FORM"
---

# Formal Verification Requirements

[Spec](spec.md) · [Decisions](log.md)

## Problem Statement

Examples and unit tests exercise selected histories. Ownership and reconciliation
also depend on histories that are difficult to anticipate: delayed acquisition,
publisher withdrawal, optional absence, rollback, and scope disposal. A useful
formal model exposes those histories without confusing abstract correctness with
correctness of unrestricted Dart callbacks.

## Scope

- Bounded transition checking of the serialized Dart lifecycle profile.
- Safety properties, conditional liveness, negative controls, and model-to-code mapping.
- Reproducible evidence and translation of counterexamples into regression fixtures.
- Conditions for optional algebraic proofs.

## Out of Scope

- Proving arbitrary resource adapters, OS behavior, Flutter rendering, or external I/O reversible.
- Full paper mechanization, Cordis compatibility, per-node inertia, and arbitrary cyclic optional feedback.
- Claiming Dart refinement from a bounded model pass.
- Installing tools or implementing the model as part of authoring these documents.

## User Stories

- <a id="r-us-vr-form-001"></a>**R-US-VR-FORM-001** — As a runtime maintainer, I want lifecycle counterexamples tied to code boundaries, so that model findings can detect implementation defects.

## Use Cases

- <a id="r-uc-vr-form-001"></a>**R-UC-VR-FORM-001** — Check a lifecycle model
  - Actor: verification runner
  - Trigger: a change to ownership, ordering, eligibility, or reconciliation
  - Preconditions: explicit model bounds and assumptions
  - Main flow: the runner MUST check specified safety properties and a separately configured conditional liveness obligation.
  - Alternative flows: timeout, evaluation error, missing tools, or incomplete search MUST produce an incomplete/failed result.
  - Postcondition: evidence identifies the exact checked model and properties, not the whole package.

- <a id="r-uc-vr-form-002"></a>**R-UC-VR-FORM-002** — Establish a meaningful oracle
  - Actor: model author
  - Trigger: a new property or changed transition
  - Preconditions: executable model
  - Main flow: a deliberate defect MUST yield the expected named counterexample; the conforming configuration MUST pass the same property.
  - Alternative flows: a parser/tool error MUST NOT count as successful defect detection.
  - Postcondition: corresponding concrete fixtures and source mappings identify the affected contract.

- <a id="r-uc-vr-form-003"></a>**R-UC-VR-FORM-003** — Reproduce and qualify evidence
  - Actor: maintainer
  - Trigger: publishing a verification result
  - Preconditions: captured run output
  - Main flow: results MUST include tool identity, model/config hashes, bounds, assumptions, enabled properties, completion status, and source correspondence.
  - Alternative flows: a Lean proof MAY support algebraic claims only with explicit hypotheses and an audited axiom set; unproved placeholders MUST NOT close a claim.
  - Postcondition: another checkout can reproduce the stated result and its limits.

## Verification

- <a id="v-t-vr-form-001"></a>**V-T-VR-FORM-001** `[test]` Given the finite conforming configurations, when model checking completes, then all enabled safety properties and the conditional liveness check pass within the declared bounds. Covers: R-UC-VR-FORM-001.
- <a id="v-t-vr-form-002"></a>**V-T-VR-FORM-002** `[test]` Given deliberately defective configurations, when each runs, then the expected property is violated with a usable trace; paired conforming runs pass and tool errors fail the harness. Covers: R-US-VR-FORM-001, R-UC-VR-FORM-002.
- <a id="v-t-vr-form-003"></a>**V-T-VR-FORM-003** `[test]` Given retained counterexample scenarios, when corresponding Dart regressions execute, then their observable assertions match the mapped lifecycle criteria. Covers: R-US-VR-FORM-001, R-UC-VR-FORM-002.
- <a id="v-t-vr-form-004"></a>**V-T-VR-FORM-004** `[test]` Given a verification report, when the evidence harness checks it, then required metadata is present and absent/partial runs cannot be classified as passed. Covers: R-UC-VR-FORM-003.
