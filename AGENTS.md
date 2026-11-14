---
description: Core guidance for the fp_di Dart runtime and Flutter adapter
globs: "**/*"
alwaysApply: true
---

# AGENTS.md

`fp_di` is a small functional, lifecycle-aware dependency-injection workspace.
Keep the Dart runtime independent of Flutter; the Flutter package is an adapter
over the runtime's public lifecycle and lookup APIs.

## Requirement Levels (RFC 2119)

This document, related agent guidance (`@agents/**/*.md`), and canonical specs  
(`@specs/**/*.md`) use uppercase keywords per  
[RFC 2119](https://www.ietf.org/rfc/rfc2119.txt):


| Keyword                      | Meaning                                                            |
| ---------------------------- | ------------------------------------------------------------------ |
| **MUST** / **REQUIRED**      | Absolute requirement                                               |
| **MUST NOT**                 | Absolute prohibition                                               |
| **SHOULD** / **RECOMMENDED** | Strong recommendation; valid reasons may exist to deviate          |
| **SHOULD NOT**               | Strong discouragement; valid reasons may exist to do it            |
| **MAY** / **OPTIONAL**       | Truly optional                                                     |
| **ASK** / **DIRECTIONAL**    | Project workflow extension: obtain user confirmation before acting |


RFC keywords are normative only when uppercase. Canonical specs use  
**MUST** / **MUST NOT**, **SHOULD** / **SHOULD NOT**, and **MAY** /  
**OPTIONAL** for accepted product and technical contracts. **ASK** /  
**DIRECTIONAL** is reserved for agent workflow guidance; unresolved spec  
choices belong in `Open Questions` instead.

## Writing Standard (ASD-STE100-based)

English prose in this document, agent guidance (`@agents/**/*.md`), and  
canonical specs (`@specs/**/*.md`) **SHOULD** follow these rules, based on the  
writing rules of ASD-STE100 Simplified Technical English. Apply them to new or  
changed text. Do not rewrite existing documents only for style.

- Write one instruction or one fact in each sentence.
- Keep procedural sentences to 20 words or fewer. Keep descriptive sentences to  
25 words or fewer.
- Use the active voice. Write procedures in the imperative.
- Use one word for one meaning. Do not use synonyms for a defined term  
(for example, do not mix `scope` and `session`).
- Do not use phrasal verbs when a single verb is clear (`remove`, not `get rid of`).
- Do not start a sentence with `it` or `this` when the referent is unclear.  
Name the subject.
- Do not omit articles (`a`, `an`, `the`) in prose sentences.
- Keep one topic in each paragraph.

Exceptions:

- RFC 2119 keywords keep the meanings above. STE dictionary limits do not  
apply to them.
- Code identifiers, technical names, product names, and quoted UI copy are  
exempt from STE vocabulary limits.
- Headings, table cells, and bullet fragments **MAY** omit articles and full  
sentence structure.
- Do not require full STE dictionary compliance. Agents cannot verify it  
reliably.

Language choice and document-specific style: [documentation rules](agents/rules/documentation.rules.md).

## Scope and ownership

The [project architecture](specs/architecture/spec.md) explains the package
split, shared responsibilities, paper adoption, and fpdart interoperability.

- `packages/fp_di/` owns the Dart-only component algebra, keys, context,
  transactional activation, cleanup, dependency tracking, and runtime errors.
- `packages/fp_di_flutter/` owns `BuildContext` lookup, the publication of a
  caller-owned scope to the widget tree, and Flutter-facing integration. It MAY depend on
  `fp_di`; the core package MUST NOT depend on Flutter.
- `specs/runtime/lifecycle/` is the canonical lifecycle topic:
  [`requirements.md`](specs/runtime/lifecycle/requirements.md),
  [`spec.md`](specs/runtime/lifecycle/spec.md), and
  [`log.md`](specs/runtime/lifecycle/log.md), with a `gap.md` while a verified
  gap is open. Keep durable requirements, accepted design, verified gaps, and
  accepted decisions in those artifacts.
- [`specs/spec.md`](specs/spec.md) is a navigation/index document for the
  workspace; it does not duplicate the lifecycle contract.

## Entry points

- Runtime API: `packages/fp_di/lib/fp_di.dart`
- Runtime implementation: `packages/fp_di/lib/src/`, with the declarations in
  `model/` and the scope library in `runtime/`
- Flutter API: `packages/fp_di_flutter/lib/fp_di_flutter.dart`
- Flutter integration: `packages/fp_di_flutter/lib/src/`
- fpdart API: `packages/fp_di_fpdart/lib/fp_di_fpdart.dart`, with the
  example `packages/fp_di_fpdart/example/checkout.dart`. The core never
  depends on fpdart or on this package.
- DevTools inspector: `packages/fp_di/lib/src/runtime/runtime_inspector.dart`.
  The experimental extension app is `packages/fp_di_devtools/`. A local build
  goes in `packages/fp_di/extension/devtools/`, which Git ignores. Contract:
  [DevTools extension](specs/tooling/devtools/spec.md).
- Runtime examples: `packages/fp_di/example/`
- Tests: `packages/fp_di/test/`, `packages/fp_di_fpdart/test/`,
  `packages/fp_di_flutter/test/`, and `packages/fp_di_devtools/test/`
- Lifecycle notes: `packages/fp_di/doc/lifecycle.md`

## Durable invariants

- Component setup is transactional: staged publications become visible together;
  a failed activation rolls back completed effects in reverse order.
- Publisher withdrawal deactivates transitive dependents before their publishers,
  so a release runs while the values its component read are still alive.
- A component is a `Dependency` plus its published key, or plus the set key
  it contributes to. A collection read expands to plain reads of its member
  keys, so each key keeps one binding per scope. A release enters the
  graph only through a `dispose` argument of a `Dependency`; no lease or
  resource type is public.
- `initialize` may activate independent members concurrently, while each member
  commits on its own. Scope teardown releases dependents before their
  publishers, and nodes that do not read each other release concurrently.
- The Flutter package owns no scope. A supplied `Scope` remains
  caller-owned.

The lifecycle spec owns the full contract and diagrams. Link to it instead of
copying the contract into package or folder guidance.

## Verification

The [test specification](specs/verification/test/spec.md) owns test methodology;
[formal verification](specs/verification/formal/spec.md) owns model/proof scope
and evidence limits. Run checks relevant to the changed package:

```sh
dart analyze
dart run agents/scripts/test_core.dart
dart run agents/scripts/test_core.dart packages/fp_di_fpdart/test
flutter test packages/fp_di_flutter/test
flutter test packages/fp_di_devtools/test
```

Examples should remain runnable with `dart run`, as the example table of
each package README lists them. [CI](.github/workflows/ci.yml) runs these
checks, the format check, the examples, the spec and vocabulary checks, the
publication dry runs, the published packages on their minimum SDK, and every
formal scenario. Run `dart format .` before a commit; the CI pins the
Flutter version of `.mise.toml`. Use [`agents/rules/verification.rules.md`](agents/rules/verification.rules.md)
for lifecycle-boundary verification and evidence.

## Documentation boundaries

| Topic | Rule |
|---|---|
| Concise documentation | [documentation.rules.md](agents/rules/documentation.rules.md) |
| Durable memory | [documentation_memory.rules.md](agents/rules/documentation_memory.rules.md) |
| arc42, C4, requirements, gaps, ADRs | [documentation_spec.rules.md](agents/rules/documentation_spec.rules.md) |
| Package, platform, or repository topology; domain concepts and terms | [Ontology](ontology/AGENTS.md); authoring: [documentation_ontology.rules.md](agents/rules/documentation_ontology.rules.md) |
| Lifecycle verification | [verification.rules.md](agents/rules/verification.rules.md) |

Tool entry points and relative aliases are documented in [agents/README.md](agents/README.md).

- Read the applicable rule in [`agents/rules/`](agents/rules) before changing
  a cross-cutting convention.
- `AGENTS.md` files are concise operating indexes: scope, entry points, local
  caveats, checks, and references.
- `agents/rules/` stores reusable constraints and pitfalls.
- Canonical specs store requirements, current design, verified gaps, and
  accepted decision history; temporary execution notes belong in a local
  `plan.md` or `agents/scratchpads/`.
- Preserve source provenance when documenting the paper, prior art, or an
  external standard. Do not turn research into an unreferenced assertion.

## Session workflow

Make the smallest change that satisfies the request and verify it at the
appropriate package boundary. For substantial work:

- Use a **scout** for a specific, bounded read-only lookup; escalate incomplete,
  ambiguous, or cross-cutting results to an explorer.
- Use an **explorer** for broader codebase exploration.
- Use a **worker** for bounded implementation, focused tests, or failure
  analysis; prefer Luna workers for clearly scoped tasks.
- Use **powerhouse** only for a genuine ambiguity, repeated failure,
  architectural uncertainty, or conflicting evidence, as an independent
  clean-context re-review. It uses the same Sol/high tier as Main; its value is
  independent re-examination, not a stronger-model escalation.

Do not delegate simple work or create agents without a bounded purpose. The
main thread owns decomposition and decisions, reviews worker results, and
independently verifies the integrated outcome.
Avoid parallel write-heavy agents touching overlapping files. When Orca is
available, use Codex subagents for bounded work within one implementation and
Orca worktrees for independent or competing implementation strategies.
