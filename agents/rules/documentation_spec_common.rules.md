---
description: Shared spec artifact locations, metadata, normative language, and ownership boundaries
paths:
  - "specs/**/*.md"
globs:
  - "specs/**/*.md"
alwaysApply: false
---

# Shared spec contract

Apply this contract to every spec artifact. Read only the artifact references selected by the [authoring router](documentation_spec.rules.md). For `R-*`, `V-*`, `G-*`, or `Q-*` entries and mappings, or a `TBD` marker, also read [traceability](documentation_spec_traceability.rules.md).

## Location

All committed specs live under the repository-root `specs/` directory. Code
ownership may move between apps, features, and packages. The spec's canonical
address remains stable because it follows the product/technical domain.

Use the smallest coherent topic: `specs/{domain}/` by default. Add an optional
`{sub-domain}/` only when contracts need independent requirements, design, and
decision lifecycles. Package names alone do not justify separate topics.
For example, `specs/architecture/` owns the whole project's architecture, while
`specs/verification/test/` and `specs/verification/formal/` own distinct methods.
In these rules, `{topic}` means either `{domain}` or `{domain}/{sub-domain}`.

```
specs/media/runtime/
├── requirements.md
├── spec.md
├── gap.md                                  # optional, committed current gaps
├── log.md
├── researches/                              # optional, committed
│   └── android-auto.researches.md
└── plan.md                                  # optional, GITIGNORED (local-only)
```

Implementation-local directories named `specs/` **MUST NOT** contain committed
spec artifacts. App, feature, package, and platform `AGENTS.md` files link to
the canonical root topic instead.

**Naming rules:**

- Use lowercase `snake_case` directory names.
- Classify by domain meaning, not by current package/app directory.
- A topic move preserves its `id_prefix` and all existing `R-*` / `V-*` /
  `G-*` / `Q-*` IDs.
- `depends_on` and `outputs` use repository-root paths beginning with `specs/`.
- A canonical topic **MUST NOT** contain another spec triad. To split a topic,
  migrate its contracts into sibling topics and make the parent navigation-only.
  Do not retain competing parent and child contracts. Only the root
  `specs/spec.md` is a supported standalone index named `spec.md`. Use a
  `README.md` for intermediate navigation.

### Required + optional artifacts

Each spec location **MUST** contain `requirements.md`, `spec.md`, and `log.md`. All three files are required. Partial specs are not allowed. `log.md` may contain only its header when no decision meets the recording threshold. Do not invent an entry to fill it.

**Migration boundary:** new topics follow this structure immediately. When an
existing topic is moved, move the whole triad, `gap.md` when present, research
notes, and local `plan.md` together. Update all repository links in the same
change. The same boundary applies to
[traceable requirement IDs](documentation_spec_traceability.rules.md#traceable-requirement-ids).

A spec location **MAY** also contain:
- A `gap.md` file containing verified, currently open differences between the accepted spec and the implementation (see [Known gaps](documentation_spec_gap.rules.md#known-gaps-gapmd)). It is committed and removed when no known gaps remain.
- A `researches/` subfolder with one or more `{target}.researches.md` files capturing internal/external research that informs the requirements or design (see [Research notes](documentation_spec_research.rules.md#research-notes-researchestargetresearchesmd)).
- A `plan.md` file holding the local, step-by-step implementation plan for the current `spec.md` (see [Plan](documentation_spec_planning.rules.md#plan-planmd)). **Gitignored** — local working scratch only.

## YAML frontmatter

Every committed Markdown document in a spec location **MUST** start with YAML frontmatter. Nothing precedes the opening `---`. `plan.md` is local and gitignored, so it MAY omit frontmatter.

```yaml
---
type: spec
title: "Session Lifecycle — Spec"
description: "Session teardown ordering, cancellation boundaries, and verification design."
tags: [session, lifecycle]
---
```

| Field | Rule |
|-------|------|
| `type` | `requirement`, `spec`, `gap`, `log`, or `research` |
| `title` | Quoted; MUST match the document H1 |
| `description` | Quoted one-line scope statement |
| `tags` | Lowercase domain keywords; keep the set small and stable |
| `id_prefix` | REQUIRED only in `requirements.md`; quoted `{DOMAIN}-{SUBDOMAIN}` abbreviation used by requirement, verification, and gap IDs |

Use `depends_on` and `outputs` only when a document defines a meaningful cross-spec dependency or produced contract. Do **not** add `updated`, `author`, changelog version, or other Git-derived metadata. Such metadata goes stale and duplicates repository history.

## Normative language (RFC 2119)

Canonical specs use the requirement levels defined by root
[`AGENTS.md`](../../AGENTS.md#requirement-levels-rfc-2119). A keyword is
normative only when uppercase.

| Keyword | Use in a canonical spec |
|---------|-------------------------|
| **MUST** / **REQUIRED** | A hard product, compatibility, ownership, data-integrity, security, lifecycle, or verification contract. Violation means the implementation does not conform. |
| **MUST NOT** | A prohibited behavior or dependency. |
| **SHOULD** / **RECOMMENDED** | The expected default. A concrete, documented reason may justify deviation without changing the accepted contract. |
| **SHOULD NOT** | A discouraged choice that requires a concrete, documented justification. |
| **MAY** / **OPTIONAL** | An allowed capability or variation that is not required for conformance. |

**ASK** / **DIRECTIONAL** is a project-specific agent workflow level, not an
RFC 2119 product or technical assertion. It **MUST NOT** appear as an accepted
contract in `requirements.md`, `spec.md`, `gap.md`, or `log.md`. Put an
unresolved choice in `Open Questions` with a `Q-*` ID. Mark the undecided
contract `TBD(Q-…)`. Once accepted, express its actual contract strength with
the RFC keyword above. See
[open questions and TBD markers](documentation_spec_traceability.rules.md#open-questions-and-tbd-markers).

### Where normative assertions belong

- `requirements.md` **SHOULD** use RFC keywords for durable behavior,
  constraints, exclusions, compatibility, and acceptance obligations. User
  Stories may remain natural-language goals. Use Case flows and postconditions
  carry the normative system contract.
- `spec.md` **SHOULD** use RFC keywords for accepted invariants such as
  ownership, dependency direction, ordering, lifecycle, failure policy, and
  verification bindings.
- `gap.md` reports a verified mismatch and **MUST NOT** invent a new contract.
  Its `Spec` field links the normative requirement or design assertion.
- `log.md` records why a decision changed. It **MAY** quote the resulting
  normative contract. Current conformance truth remains in
  `requirements.md` / `spec.md`.
- Research findings and trade-off descriptions are evidence, not normative,
  until accepted into `requirements.md` or `spec.md`.

### Writing rules

- Use the weakest keyword that accurately represents the accepted contract.
  Do not turn preferences into **MUST** merely to make prose sound decisive.
- Use descriptive present tense for facts, rationale, diagrams, examples, and
  implementation snapshots. Not every sentence needs an RFC keyword.
- Do not use `shall`, lowercase `must` / `should` / `may`, `always`, or `never`
  as substitutes for an RFC assertion. Use the uppercase project vocabulary
  when the sentence is normative.
- State the subject and observable obligation explicitly: `Session teardown
  MUST cancel active work before removing repositories.` Avoid detached labels
  such as `MUST: safe teardown`.
- Verification criteria remain observable Given/When/Then outcomes. Use an RFC
  keyword only when the criterion itself contains an independent conformance
  obligation. Do not mechanically prefix every `V-*` item with **MUST**.
- Existing accepted IDs and meaning remain stable during migration. Applying
  this style **MUST NOT** silently strengthen **SHOULD** behavior into **MUST**
  behavior. Semantic changes follow normal requirements and decision-log rules.

```markdown
# requirements.md
- <a id="r-uc-ses-lc-001"></a>**R-UC-SES-LC-001** — Session teardown
  - Main flow: The session scope **MUST** cancel active work before removing
    account-owned repositories.
  - Alternative flows: Optional cleanup **MAY** fail without retaining account
    identity, but the failure **MUST** be reported.

# spec.md
App-scoped services **MUST NOT** retain session-scoped instances. A service
that only consumes immutable session snapshots **MAY** remain app-scoped.
```

## Specs vs. gaps vs. plans

| Artifact | Lives in | Lifetime | Contents |
|----------|----------|----------|----------|
| **requirements.md** | `specs/{topic}/` | Long-lived; updated when requirements change | Problem, scope, stories, use cases, constraint references |
| **spec.md** | `specs/{topic}/` | Long-lived; updated when implementation design changes | Diagrams, structure, conventions, implementation references |
| **gap.md** | `specs/{topic}/` | Committed while known gaps are open; remove when empty | Verified differences between accepted spec and current implementation, impact, evidence, resolution condition |
| **log.md** | `specs/{topic}/` | Long-lived; append-only accepted decisions | Significant decision context, outcome, consequences, supersession links |
| **researches/{target}.researches.md** | `specs/{topic}/researches/` | Long-lived but quotable — refresh when the source moves | Findings, comparisons, prior-art summaries that inform requirements/specs |
| **plan.md** | `specs/{topic}/` (gitignored) | Session/work-scoped — delete when the spec lands | Local step-by-step execution checklist for the current spec |
| **Implementation plan (cross-topic)** | `agents/scratchpads/` or task tool | Session-scoped | Step-by-step "do X then Y" that doesn't belong to a single spec topic |
| **Issue Spec projection** | Jira issue description | Issue lifetime; regenerated from local truth | Issue-scoped `R-*` / `V-*`, local topic links, design links, impact, dependencies, and status |
| **Progress / status** | Jira / scratchpads | Session-scoped | Who's doing what, when |

If you find yourself writing "next, we will…" or "TODO:" in a committed spec artifact, it belongs in `plan.md`, a scratchpad, or a task list. `gap.md` states the present mismatch and its resolution condition, not the steps to close it.
