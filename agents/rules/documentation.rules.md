---
description: Token-efficient documentation guidelines for agents/ directory files
paths:
  - "agents/**/*.md"
  - "CLAUDE.md"
  - "**/AGENTS.md"
globs: "agents/**/*.md"
alwaysApply: false
---

# Documentation Guidelines

`{topic}` denotes a domain, optionally followed by a subdomain when its contract
needs an independent lifecycle. See [spec location rules](documentation_spec_common.rules.md#location).

All `@agents/` documentation should balance token efficiency with human readability.

## Language Policy

| Doc | Language |
|-----|----------|
| `agents/rules/*.rules.md` | **English only.** Loaded into every session — keep tokens predictable and grep-friendly. |
| `specs/{topic}/*.md` (`requirements.md`, `spec.md`, `log.md`, `researches/*.researches.md`, `plan.md`) | **English by default.** Long-lived, cross-team artifact — stay in English even when the team works in Korean. |
| `**/views/**/PRESENTATION.md` | **English by default.** Keep headings and mappings stable; use Korean only for exact UI copy or product nuance. |
| `**/AGENTS.md` (folder-level) | **English by default. Korean MAY be used as a supplementary aid** when a domain term, copy snippet, UI label, or product nuance is clearer in Korean. Keep the structural skeleton (headings, tables, code) in English so other agents and tools can parse it. |
| Commit messages, PR titles, code comments | Follow the repository's current Git and code-style conventions. |

**Rules of thumb:**

- If the same idea reads cleanly in English, write English. Mixing per-sentence is noise.
- Use Korean only when the English would be lossy: brand names, legal/policy language quoted verbatim, in-app copy under review, edge-case product nuance.
- When mixing, English first, Korean in parentheses or follow-up sentence: `Forbidden landing CTA copy ("멤버십 가입하기").`
- Headings, tables, code, and inline identifiers MUST stay English.

## Writing Principles

- **Concise Headers**: Short, descriptive titles without redundant words
- **Bullet Lists**: Prefer lists over paragraphs for structured information
- **Code Examples**: Include only essential parts, use comments for context
- **Abbreviations**: Use common abbreviations (impl, repo, DI, API) consistently
  in tables, lists, and identifiers. Spell out the full term in prose sentences.
- **Tables**: Use for comparisons and mappings instead of verbose descriptions
- **Remove Filler**: Eliminate "it should be noted that", "basically", etc.

## Writing Style (STE-based)

Follow the [Writing Standard (ASD-STE100-based)](../../AGENTS.md#writing-standard-asd-ste100-based)
in root `AGENTS.md`. This file adds language and token-efficiency guidance for agent docs.

## Code Example Guidelines

- **Generic Names**: Use domain-agnostic names (`UserModel`, `ContentModel`, `ConfigModel`)
  ```dart
  // Good: Generic
  class GetDataRepository extends CachedGetableRepository<DataModel, GetDataParam>

  // Avoid: Domain-specific
  class GetSupportTicketRepository extends CachedGetableRepository<SupportTicketModel, GetSupportTicketParam>
  ```
- **Concrete Code for Pitfalls**: Show full implementation for tricky cases, gotchas, workarounds
- **Pseudo-code for Common Patterns**: Use simplified syntax for standard patterns
- **Reference Real Examples**: Link to actual implementations when needed
  ```markdown
  See a concrete implementation under `packages/<package>/lib/` when a real
  example is needed.
  ```
- **Type Arguments**: In fp_di code examples, write the type argument of every `Component` and every
  `Dependency` or `DependencyN` constructor. Do not rely on inference. The only exception is a
  counterexample that shows a forgotten type argument.
- **Demo Logging**: In fp_di examples, keep demo logging out of `create` and `dispose`. Trace
  components with a `Scope.addListener` listener. Let a fake resource print in its own
  constructor and methods. Keep an effect that is the subject of the example.

## Structure Patterns

- **Problem/Solution**: State issue briefly, then solution directly
- **When/Then**: For conditional guidance without verbose explanations
- **Do/Don't**: Clear binary choices without justification paragraphs
- **Checklist Format**: For step-by-step processes

## Markdown Optimization

- Use `**Bold**` for key terms instead of explanatory sentences
- Link to other applicable rules instead of repeating content.
- Group related items with consistent formatting

## LLM Token Efficiency

- Write for LLM context window optimization
- Prefer pseudo-code over full implementation for examples
- Remove redundant explanations that LLM can infer
- Structure content for single-pass comprehension

## Document Cross-Reference

| Directory | Role | Required Meta |
|-----------|------|---------------|
| `agents/rules/` | Reusable project-wide implementation patterns, constraints, and pitfalls (canonical convention source) | `description`, `paths` (Claude Code) or `globs`/`applyTo` (Cursor/github) |
| `agents/prompts/` | Task-oriented workflows (reference rules/ for details) | `description`, `globs`/`applyTo`, `mode: "agent"` |
| `agents/scripts/` | Small repository validators and executable helpers | — |
| `agents/products/` | Non-technical product context | `description`, `globs`/`applyTo`, `alwaysApply` |

## AGENTS.md vs. rules vs. specs

These documents have separate ownership boundaries. Classify content by its
purpose, not by the directory currently being edited.

| Doc | Owns | MUST NOT own |
|-----|------|--------------|
| **`{folder}/AGENTS.md`** | Folder scope, ownership boundary, 2–5 entry points, non-obvious local caveats, generated/do-not-edit notes, minimal local checks, links | Full architecture, requirement/acceptance criteria, decision history, roadmap, status, TODO list, exhaustive file/API inventory |
| **`agents/rules/*.rules.md`** | Reusable project-wide patterns, constraints, and pitfalls | Feature-specific implementation narrative |
| **`specs/{topic}/requirements.md`** | Problem, scope, user stories, use cases, observable acceptance | Class/file-level design |
| **`specs/{topic}/spec.md`** | Current design truth: architecture, flows, state machines, artifacts, verification implementation | Progress or chronological decision history |
| **`{view-root}/PRESENTATION.md`** | Optional view-local map: composition, visible states/interactions, design-system mapping, responsive/accessibility constraints, and links to Figma/goldens | Product requirements, cross-layer design, copied Figma values, verification results, status, or history |
| **`ontology/*.yml`** | Stable IDs and typed, evidence-cited relations among packages, platforms, repositories, and domain concepts, including the canonical definition of each shared term; see [ontology rule](documentation_ontology.rules.md) | Requirements, behavior, config values, versions, live state, inventories, or paths outside this repo |
| **`specs/{topic}/gap.md`** | Verified, currently open differences between the accepted spec and implementation | Implementation sequence, backlog, owner, ETA, or closed-gap history |
| **`specs/{topic}/log.md`** | Significant accepted decision changes only | Routine edits or activity log |
| **Jira `# Issue Spec`** | Issue-scoped projection of local `R-*` / `V-*`, design links, delivery impact, dependencies, and status | Independent requirement meaning, accepted architecture, decision history, or known gaps |
| **`plan.md` / `agents/scratchpads/`** | Temporary status, next steps, open implementation work | Long-lived design truth |
| **Code / generated API docs** | Derivable file roles, symbols, and signatures | Product rationale |

### Folder AGENTS.md shape

A folder-level `AGENTS.md` SHOULD be a concise operating index and normally
contain only:

```markdown
# Folder Name
## Scope
## Entry Points
## Local Caveats
## Local Checks
## References
```

- Keep only caveats that are local, durable, and not obvious from code.
- Link to `agents/rules/` and `specs/` instead of copying their content.
- If a local caveat needs a long runbook, move it to `docs/caveats/*.md` and
  link it. Do not turn `AGENTS.md` into the runbook.
- Do not create a spec merely because a folder exists. Create one for a
  coherent topic with its own long-lived requirements/design lifecycle.
- Remove stale status and derivable file inventories instead of relocating
  them.

**Decision flow:**

- Reusable across folders? → `agents/rules/`.
- Feature behavior or architecture? → complete `specs/{topic}/` triad.
- Non-trivial presentation composition? → optional `{view-root}/PRESENTATION.md` linked to the canonical spec and its visual source when one exists.
- Verified mismatch between accepted spec and current implementation? → optional committed `gap.md` in that spec topic.
- Significant accepted design change? → `specs/{topic}/log.md`.
- Stable identity of a package, platform, repository, or domain concept, a shared term definition, or a typed connection between them? → `ontology/`, per the [ontology rule](documentation_ontology.rules.md).
- Issue delivery slice, dependency, schedule, or status? → Jira `# Issue Spec` projection linked to canonical local IDs.
- Temporary work/status? → `plan.md` or `agents/scratchpads/`.
- Local operating caveat or entry point? → folder `AGENTS.md`.
- Directly derivable from code? → keep it in code; do not duplicate it.

**Cross-references:**

- `AGENTS.md` SHOULD link to relevant rules/specs instead of restating them.
- A view-root `AGENTS.md` SHOULD link to `PRESENTATION.md` when present. The view-root file MUST NOT absorb the presentation contract.
- `spec.md` SHOULD link to rules for conventions and to `log.md` for decision
  history.
- A rule that applies a canonical runtime/design contract SHOULD link the
  owning `specs/{topic}/spec.md` near its top.
- `agents/rules/` MUST NOT duplicate feature-specific or cross-cutting runtime
  flows, lifecycle sequences, state machines, current component inventories,
  or accepted trade-offs owned by a canonical spec.

See [`documentation_spec.rules.md`](documentation_spec.rules.md) for the full spec authoring rules (requirements / design / known gaps / decisions / research / plan).

## Related

- [documentation_memory.rules.md](documentation_memory.rules.md) — what to capture in rules: pitfalls, constraints, design decisions, edge cases
- [documentation_ontology.rules.md](documentation_ontology.rules.md) — ontology ownership, routing, authoring, and review checklist
- [documentation_spec.rules.md](documentation_spec.rules.md) — requirements.md / spec.md / gap.md / ADR-inspired log.md / researches/{target}.researches.md / plan.md authoring rules
