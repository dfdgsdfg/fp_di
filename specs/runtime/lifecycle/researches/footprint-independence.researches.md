---
type: research
title: "Footprint Independence"
description: "Candidate read/write footprint algebra and its soundness and lifecycle boundaries."
tags: [runtime, lifecycle, concurrency, research]
---

# Footprint Independence

## Subject

A candidate footprint algebra for rejecting conflicting lifecycle effects without an established execution order.

## Why

The [composition contract](../spec.md#composition-and-concurrency) currently leaves cross-effect independence to authors.
The [parallel-effects research](parallel-dependency-effects.researches.md#algebraic-guarantee-boundary) distinguishes valid inverses, execution order, and independence.
The proposed footprint discipline would make conflict checking compositional, while retaining a local contract for each primitive.
This note evaluates the user's proposal; it does not accept an API or change runtime behavior.

## Findings

### Existing result in the paper

Section 3.4 already supplies a compositional independence discipline; the underlying result does not need a new proof.
The [paper mapping](spatiotemporal-composability.researches.md#findings) records the source version and the review of pages 25–27.
Theorem 45 proves independence of operations confined to distinct keys.
Theorem 47 extends independence to key-mediated effects whose shared keys are all commutative, when neither provides a key at which the other operates.
Definition 44 includes forward and inverse transformations, inverse selection, and operation outcomes.
The publisher owns the interface's commutativity obligation (p. 29).

Let `K(e)` cover every key on which an effect operates, including every possible continuation.
Let `C` contain the keys whose interfaces satisfy Definition 44.
The theorem gives this sufficient condition:

```text
K(a) intersection K(b) subset C  =>  independent(a, b)
```

For unordered effects, rejecting shared keys outside `C` supplies a conservative checker under the paper's mediation contracts.
The [key-commutativity research](effect-independence.researches.md) examines its application to fp_di.
Deriving sound operation footprints from current DI shapes remains an implementation obligation.

The proposed read/write test is related, but differs from this key-interface discipline.
It accepts noninterfering reads and disjoint writes, while rejecting shared writes even when their operations commute.
A key-level commutativity contract can accept those shared writes.
Conversely, two reads of a noncommutative interface can pass the read/write test while failing the coarse key-level check.
Neither metadata scheme by itself proves that arbitrary Dart callbacks obey its contracts.
Existing keys can represent regions when their identities faithfully capture the state boundaries; a separate `DiRegion` namespace is not inherently required.

### Candidate algebra

Let `Rd(e)` and `Wr(e)` conservatively cover every shared-state access of an effect's acquisition and release.
Reads that determine the inverse or its captured values also belong to `Rd(e)`.
Partial-acquisition cleanup belongs to the same footprint.
An effect's returned value and observable behavior depend only on its declared reads and explicit inputs.
Its transformations preserve state outside its declared writes.
These are primitive contracts, not conclusions from the presence of metadata.

For disjoint atomic regions, footprint combination is an idempotent commutative monoid:

```text
F(e) = (Rd(e), Wr(e))
identity = (empty, empty)
(R1, W1) + (R2, W2) = (R1 union R2, W1 union W2)

F(zip(d1, ..., dn)) = sum F(di)
F(zipPar(d1, ..., dn)) = sum F(di)
F(map(d, create, dispose)) = F(d) + F(create, dispose)

conflict(a, b) =
  Wr(a) intersects (Rd(b) union Wr(b))
  or Wr(b) intersects (Rd(a) union Wr(a))
```

The `map` rule includes the newly introduced callback pair.
Inheriting only the source footprint would hide every effect introduced through `map` or `mapN`.
Omitting `dispose` does not imply an empty footprint.

The union summarizes accesses but loses execution order and multiplicity.
The execution structure therefore retains sequential edges, parallel branches, and distinct acquisition instances separately.
Equal footprints do not make `zip` and `zipPar` interchangeable.
Repeated use of one descriptor also does not merge its acquisitions.

For distinct effect occurrences, define the footprint independence relation by absence of conflict.
The inequality excludes self-pairs when using an irreflexive trace independence relation.
The relation is conservative: commuting writes to one region can still conflict according to their footprints.

### Conditional safety argument

Assume a state partition into nonaliasing regions, sound footprints, and valid inverse witnesses for each primitive.
Every forward or inverse transformation respects its footprint, including the state that selects an inverse.
Under these assumptions, the conflict test excludes every cross-effect read/write and write/write interaction.
Each transformation preserves the other's inputs and writes, so their transformations commute and inverse selection remains stable.
The conditions supply the independence needed by the [paper's Definition 42 and Theorem 43](spatiotemporal-composability.researches.md#findings).

This is a conditional argument for the abstract model, not a machine-checked implementation proof.
Asynchronous implementations still need to preserve the modeled boundaries.
In particular, a callback that continues changing shared state after returning is not one completed atomic effect.
Its background work needs an explicit lifetime model or remains outside the guarantee.

The runtime can verify declared conflicts and precedence automatically.
It cannot infer that arbitrary Dart callbacks obey their declarations or that their disposals restore state.
Footprints move the author obligation from every composition to each primitive's local contract.

### Deferred effects invalidate descriptor-order reasoning

The proposed ordering relation cannot equate descriptor order with actual effect order.
The existing [`lazy()`](../../../../packages/fp_di/lib/src/model/dependency.dart) provides a concrete counterexample.
The following trace was reproduced against the current Dart runtime:

```text
Both A and B read and write region R, whose initial value is 0.
Each create saves the previous value; its dispose restores that value.

declaration: (A.lazy(), B).zip
activation: B creates, R changes 0 -> 2
later force: A creates, R changes 2 -> 1
teardown: B disposes, R changes 1 -> 0
          A disposes, R changes 0 -> 2
```

Both footprints can be truthful, and both individual inverses can be correct.
Treating the descriptor's `zip` order as sufficient would nevertheless permit the unrestored final state.
The ordering edge is from creation of the lazy holder to B, not from the deferred A effect to B.
This example does not contradict Theorem 47: both effects operate on the same noncommutative state.

A conservative design keeps the deferred footprint visible while its holder can be forced.
It grants no precedence edge from deferred work merely because the holder was constructed first.
Potentially overlapping conflicting deferred work is then rejected unless an explicit execution boundary establishes the required order.
The same distinction applies to background work owned by a resource.

### Lifecycle validation domain

The candidate rejection rule can stay simple:

```text
For distinct potentially interacting effect instances a and b:
  if conflict(a, b) and neither a precedes b nor b precedes a:
    reject
```

Precedence denotes enforceable effect order and the matching reverse cleanup obligation.
It is not wall-clock initialization order or descriptor list order.
Cycles do not establish a strict precedence relation.

Validation covers the effects that a new activation can encounter, including live acquisitions and pending cleanup.
Checking only the members of the latest `initialize` misses conflicts with ancestors and existing scopes.
Reactivation and shadowing use the actual publisher and activation identities; an old episode can still own conflicting state.
A declaration referring to a key is not evidence that an old episode read the newly selected publisher.

Separate root runtimes need a shared conflict authority for shared regions, or an explicit guarantee boundary excluding their interactions.
Application writes outside the lifecycle runtime also need enforcement or a stated host obligation.

### Declaration and region identity

An omitted footprint cannot mean known-empty in a sound checking mode.
It means unknown until the author supplies a footprint or uses a primitive with a known contract.
The policy for unknown effects can reject overlap or require an explicitly weaker compatibility mode.

Region identity denotes state aliasing, not merely a diagnostic label.
Two names for the same state cannot silently become disjoint regions.
If regions are hierarchical, a write to `db` overlaps accesses to `db.tableA` and `db.tableB`.
Literal set intersection is sufficient only when the region universe already represents disjoint atoms.
Different tables are independent only if their effects do not share additional mutable state, such as a common transaction setting.

## Implications

- Reuse the paper's independence theorem and publisher obligations when selecting the checking discipline.
- Distinguish operation footprints, DI lookup shapes, and execution precedence; prove any derivation between them.
- Include the new callback's footprint in `map`, `mapN`, and `DependencyN` derivation.
- Define sound declaration, region aliasing, and unknown-footprint policies before making automatic safety claims.
- Validate `zipPar` branches and module members using the same conflict predicate.
- Include existing lifetimes and activation identities in the validation domain.
- Give deferred and ongoing effects their own execution boundaries; holder creation does not order their later mutations.
- Keep valid inverse witnesses as a primitive obligation. Footprints establish noninterference, not invertibility.
- Verify the conditional algebra separately from runtime scheduling and Dart callback conformance.

Suggested verification includes footprint union laws, conflicting unordered siblings, ordered conflicting eager effects, and independent parallel effects.
It also includes effects added by `map`, writes performed only by `dispose`, unknown footprints, aliases, and conflicts across existing scopes.
The deferred-effect trace above is a negative case for any checker that treats every descriptor `zip` as an ordering proof.

## Open Questions

- Are footprints required for all primitives, or introduced through a separately identified checking mode?
- Are regions disjoint atoms, hierarchical regions, or canonical tokens supplied by a resource owner?
- Which effects are inside the guarantee: lifecycle callbacks alone, or their owned asynchronous activities too?
- How does the first version represent deferred footprints and explicit force boundaries?
- Does validation reject a conflicting reconfiguration, or also plan dependent teardown before starting new effects?
- Does conflict authority cover one runtime or multiple roots that share external state?
