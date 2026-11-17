---
type: index
title: "fp_di Specifications"
description: "Entry point to core, Flutter, lifecycle, and verification contracts."
tags: [runtime, lifecycle]
---

# fp_di Specifications

Canonical topics separate architecture, runtime behavior, and verification.
This navigation document owns no independent requirements or implementation contract.

| Topic | Responsibility |
|---|---|
| [Project architecture](architecture/spec.md) | Package split, core/Flutter responsibilities, and paper adoption |
| [Runtime lifecycle](runtime/lifecycle/spec.md) | Activation, rollback, dependency targets, and withdrawal |
| [Automated tests](verification/test/spec.md) | Test layers, deterministic fixtures, and [fuzz provenance and manifests](verification/test/spec.md#fuzz-evidence-artifacts) |
| [Benchmark evidence](verification/test/spec.md#benchmark-evidence-artifacts) | Timing protocol, samples, statistics, manifests, and source provenance |
| [Formal verification](verification/formal/spec.md) | TLA+ model design, properties, bounds, and optional Lean proof boundary |
| [DevTools extension](tooling/devtools/spec.md) | Inspector protocol that a debug build serves, and the DevTools extension app that shows it |
| [Ontology format](ontology/spec.md) | Format and vocabulary of the documentation-only [ontology](../ontology/AGENTS.md) |

Each topic has `requirements.md`, `spec.md`, and `log.md`; verified open
differences are recorded in `gap.md` where applicable. The
[paper mapping](runtime/lifecycle/researches/spatiotemporal-composability.researches.md)
identifies the source and assumptions behind the design.

Authoring follows [the documentation rules](../agents/rules/documentation_spec.rules.md).
