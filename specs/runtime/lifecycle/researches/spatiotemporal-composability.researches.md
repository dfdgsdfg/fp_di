---
type: research
title: "Spatiotemporal Composability Paper Mapping"
description: "Source-grounded mapping from the supplied paper to the fp_di runtime contract."
tags: [runtime, lifecycle, research]
---

# Spatiotemporal Composability Paper Mapping

## Subject

The correspondence and boundaries between the supplied paper's effect/coeffect
calculus and the Dart runtime described in [the spec](../spec.md).

## Why

[The requirements](../requirements.md#scope) need an explicit distinction between
source results, selected behavior, and evidence about the current implementation
before a formal model can be meaningful.

## Source

- Yifan Shi, Wei Zhang, Tianyi Cui, *A Programming Paradigm for Spatiotemporal Composability*, arXiv:2608.25512 [cs.PL], version 1, submitted 2026-08-26. DOI: [10.48550/arXiv.2608.25512](https://doi.org/10.48550/arXiv.2608.25512).
- Source: [arXiv:2608.25512v1](https://arxiv.org/abs/2608.25512v1) ([PDF](https://arxiv.org/pdf/2608.25512v1)), 92 pages. Page numbers below are PDF page numbers of v1.
- SHA-256 of the v1 PDF: `390775dbc9debdcf2ed1b076eed013387ca057630be3cb594617b2b742e48cf0`.
- Revision 2026-11-14: the citations of this note now name the items, sections, and pages of v1. The reviews below, before that date, read a local copy of 88 pages with SHA-256 `4d48478dc0b6222d9f74d7db10ee776449b1209eb112632336544d32a49db97f`. That copy is not v1. Its numbering matches v1 up to Definition 16 and Theorem 16, and Chapter 4 has other sections. The decision logs keep the numbering of that copy.
- Method: extract the local PDF, inspect the title page and selected mathematical/lifecycle pages, and compare definitions with the Dart source. This note is a mapping, not independent verification of the paper's proofs.
- Revision 2026-11-08: the rows were brought to the current API (`requires`, `optional`, one `key`, `dispose`, fixed scope contents). Definitions 43, 46, and 69 and Theorem 73 were re-read in the extracted text of the same PDF for the §4.2 and §4.4.5 rows.
- Review 2026-11-09: Definition 24 and §3.3.2 were re-read, including Theorems 40 and 42 and the publisher obligation on p. 27.
- Review 2026-11-10: Definitions 8, 25, 43, 44, and 45, §5.1 Table 2, Algorithm 4, and the text of §5.1.3 were re-read in the extracted text of the same PDF for the term table.

## Findings

| Paper location | Source meaning | Dart correspondence and boundary |
|---|---|---|
| §3.1.1, Definition 1, p. 9 | Forward composition pairs with inverse composition in the opposite order. | The owned steps of a `Dependency` chain and the reverse-order `dispose` of a node implement the ordering mechanism. A `dispose` function does not carry a proof witness. |
| §3.1.2, Definition 8, p. 12; §3.1.3, Theorem 16, p. 15 | A witnessed effect yields a state-specific inverse; reverse application order recovers prior states under that witness. | A `dispose` argument establishes ownership, and the runtime records it for teardown. An arbitrary `dispose` may throw or fail to restore state. The runtime attempts each one in reverse order and aggregates the failures, which is a weaker guarantee. |
| §3.4.1, Definition 42, p. 27; Theorem 43, p. 28 | Independence requires transformations, including inverses, to commute and foreign transformations not to alter the inverse selected. For witnessed effects, pairwise independence permits any inverse order; LIFO needs no additional independence hypothesis. | `initialize` and `Scope.dispose` permit concurrency between nodes without a read path between them. The current runtime leaves their independence to authors. The steps inside one `Dependency`, including a `zip`, run in sequence. Section 3.4 supplies a proved key-mediated discipline, but the runtime does not yet implement its contracts. |
| §3.2.1, Definitions 19–20, p. 17 | A typed partial dependency table rejects duplicate provision. Provision is itself reversible. | `DiKey<T>` plus scoped binding records and staged publication. Hierarchical shadowing is an additional resolution policy. |
| §3.3.1, Definition 29, pp. 21–22 | Each key defines values and operations with inverse witnesses and outcomes, and the operations induce its observational equivalence (Definition 31). A lifted operation reads and writes only its keyed value. | Arbitrary Dart methods can reach shared state through aliases or captured references. Different `DiKey` identities alone do not establish this confinement. |
| §3.2.2, Definitions 21–22, p. 18 | Declared requirements determine satisfaction; changes drive activation and deactivation. | `requires` is the declared key set of Definition 53, and `initialize` rejects a required key that no member of the scope or its ancestors declares (`UndeclaredKeyError`). `optional`, the reads of `Dependency.maybe`, is a Dart extension: the keys are tracked for changes but must not become requirements. |
| §3.2.3, pp. 19–21 | Isolation changes resolution through realms; interception composes metadata. | Parent fallback and local shadowing implement a restricted visibility mechanism; no general realm or interception API is present. |
| §3.3.1–2, pp. 21–26 | Unified context connects tracked effects and coeffects; equivalence has operation-respecting conditions. | Scope bindings and cleanup ownership share the interpreter. Binding-record identity is used instead of custom observational equivalence. |
| §3.4.2, Definition 44 and Theorem 45, pp. 28–29 | Operation independence also preserves outcomes. A commutative key has pairwise independent operations, including each operation with itself. Operations at distinct keys are independent. | A key currently carries no commutativity contract. A provider's contract would cover its interface, including inverses and outcomes, rather than only forward writes. |
| §3.3.1, Definition 30, p. 22; §3.4.2, Theorem 47, p. 30 | Key-mediated effects are independent when every key on which both operate is commutative and neither provides a key at which the other operates. Continuations can depend on prior operation outcomes. | The theorem already supplies compositional independence. Applying it requires sound operation footprints and matching provider contracts; declared DI lookups alone do not establish either. |
| §3.3.1, p. 21; §3.4.2, pp. 29–31 | All shared state passes through keys. Commutativity is the publishing component's interface obligation. Noncommutative operations need order, locally through LIFO or across components through coeffects. | The [key-commutativity research](effect-independence.researches.md) evaluates this discipline. Its runtime checker and the mapping from Dart callbacks remain candidate work. |
| §4.1, Definitions 48–50, pp. 31–32 | A component has requirements, possible provisions, and a witnessed effect; fibers hold lifecycle state and committed provider views. | `Component` is a descriptor with `requires`, `optional`, and at most one `key`. `ComponentNode` is the public view of an installed instance (`_RuntimeNode`). A scope is a visibility and ownership tree and must not be equated with the paper's fiber-parent relation. |
| §4.2.1, O-Insert, p. 34; §4.2.2, Definition 53, pp. 35–36 | A lifecycle responds to a target view; insertion enforces disjoint declared provisions in one shared realm. | Committed identities drive reactivity. The contents of a scope are fixed when it is created, so the declared keys are known before activation. `initialize` rejects two members of one scope with the same key before it creates a node (`DuplicateKeyError`), so the provisions of one scope are disjoint as in O-Insert. A nearer scope may still shadow a key, which the paper's single realm does not allow. |
| §4.2.2, Definition 54, p. 36; §4.3.3, Theorem 70, pp. 47–48 | Unloading separates loss of availability from inverse execution; dependent committed reads remain available while the provider waits. | Deactivation withdraws availability, deactivates the dependents, then disposes the publisher. Teardown uses committed identities. |
| §4.4, Asynchrony, pp. 55–56; §4.2.2, p. 37 | In-flight asynchronous work must land; changed targets route the landed inverse into unloading without exposing a departing provider. | The global mutation queue serializes separate node transitions. Concurrent module member activation, which settles every member in flight before a rollback, is not implementation of the full per-node inertial calculus. |
| §4.4, Failure, p. 56 | Failed activation routes through cleanup to an inactive error outcome; ordinary begin does not re-enter it. | A failed `initialize` rolls back the whole scope in reverse declaration order and leaves it uninitialized, so a later call may retry. A failed automatic activation may be retried on a later mutation. A failed own `dispose` stops reactivation (`dispose failed`). These are profile-specific policies. |
| §4.3.4, Theorem 73, pp. 49–50 | Progress/termination uses an acyclic precedence relation, bounded iterator length, and a finite set of names under lifecycle steps. | No universal termination claim applies to arbitrary futures, optional feedback, or changing host inputs. Whole-graph validation is absent. |
| §4.3.5, Definition 76 and Theorem 80, pp. 52–54; §4.4, p. 56 | Confluence holds at a quiescent state when every component is total on its provision. Pairwise independence is not a hypothesis: Lemma 66 derives it from the witnessed coeffects of the components (p. 47). Confluence excludes failed fibers (p. 56). | A component publishes at most one key, and every activation that finishes publishes it, because `Component` has no conditional publication. Definition 76, totality on the provision, therefore holds by construction. The premise of Lemma 66, a witnessed commutative coeffect at every key, is an author obligation that fp_di does not check, and `dispose` functions are unrestricted. Theorem 80 is therefore not established for this runtime. |
| §6.1, pp. 70–71 | Recovery applies inside an exclusively controlled, reversible boundary; external emissions and compensation require separate reasoning. | Disposing subscriptions and connections is within adapter ownership; sent events, network requests, and arbitrary shared mutations are not automatically undone. |

## Paper terms and fp_di terms

The public API words are the reference for the spec. The paper terms appear only in this note. The page numbers are PDF page numbers.

| Paper term | Paper location | fp_di term |
|---|---|---|
| Component (𝑑, 𝑝, 𝑒) | Definition 48, §4.1, p. 31 | `Component`: a `Dependency` plus the key it publishes |
| Fiber | Definition 49, §4.1, p. 32 | Node (`ComponentNode`) |
| Registry | Definition 50, §4.1, p. 32 | The nodes of a scope; no public registry type |
| Coeffect specification 𝑑, `component.inject` | Definition 21, §3.2.2, p. 18; Algorithm 4, §5.1.3, pp. 61–62 | `requires`. The paper has no optional read, so `optional` is an fp_di extension |
| Provision 𝑝, provider, `provided(fiber)` | Definition 48, p. 31; provider, §4.1, p. 33; `provided(fiber)`, §5.1.3, p. 62 | `publishes`, publisher |
| 𝑑 and 𝑝 together | Not a paper term | Shape (an fp_di term) |
| Witnessed effect 𝑒 with its inverse | Definition 8, §3.1.2, p. 12; Definition 48, p. 31 | The `create` of a step with its `dispose` |

## Implications

- Specify ownership and `dispose` attempts separately from successful restoration.
- Keep intended invariants in [spec.md](../spec.md), actual violations in a `gap.md` of the topic while one is open, and excluded paper features in [requirements.md](../requirements.md#out-of-scope).
- Reuse Theorems 45 and 47 when adopting the paper's key-mediated discipline. The abstract independence result is already proved.
- Distinguish current DI scheduling from that discipline. Sound footprints, confined operations, and publisher commutativity contracts connect the implementation to the theorem.
- Model required and optional reads, committed absence, and publisher identity explicitly.
- Model the selected serialized Dart profile before adding per-node concurrency. A model of the paper alone does not validate this implementation. Concurrent scope teardown followed this rule: `Teardown.tla` checked it before the runtime changed.
- Preserve the distinction between bounded transition checking, algebraic proof, and implementation refinement. The TLA+ models under [verification/tla](../../../../verification/tla) check bounded histories of the serialized profile, and the [formal verification spec](../../../verification/formal/spec.md) states their scope. No Lean proof exists.

## Implementation References

- [Component algebra](../../../../packages/fp_di/lib/src/model/component.dart).
- [Lifecycle interpreter](../../../../packages/fp_di/lib/src/runtime/runtime.dart).
- [Values and `Lazy`](../../../../packages/fp_di/lib/src/model/lease.dart).
- [Current lifecycle guide](../../../../packages/fp_di/doc/lifecycle.md).
