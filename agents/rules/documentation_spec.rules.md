---
description: Spec authoring rules — arc42-based design, C4 structure views, traceable requirements, known gaps, and ADR decision logs
paths:
  - "specs/**/*.md"
globs: "specs/**/*.md"
alwaysApply: false
---

# Spec Authoring

Long-lived spec documents describe **what** a feature is (`requirements.md`), **how** it is built (`spec.md`), **where the accepted spec and current implementation are known to differ** (`gap.md`), and **why significant design choices changed** (`log.md`). Implementation sequencing, todos, activity history, and progress trackers do **not** belong in committed spec artifacts. They are session-scoped and live in `plan.md`, `agents/scratchpads/`, or task lists.

## Read by artifact

For any spec edit, read the [shared contract](documentation_spec_common.rules.md)
for location, required artifacts, metadata, normative language, and ownership
boundaries. Then read only the rules for artifacts being authored or changed:

| Task | Rule |
|------|-----------|
| Define or map `R-*`, `V-*`, or `G-*` IDs | [Traceability](documentation_spec_traceability.rules.md): prefix grammar, immutable IDs, legacy prefixes, criterion replacement |
| Author requirements and acceptance | [requirements.md](documentation_spec_requirements.rules.md): sections, stories/use cases, verification tags |
| Author implementation design | [spec.md](documentation_spec_design.rules.md): arc42, C4, dynamic diagrams, verification bindings |
| Record verified current divergence | [gap.md](documentation_spec_gap.rules.md): evidence and resolution grammar |
| Record an accepted decision | [log.md](documentation_spec_decisions.rules.md): threshold, append-only grammar, supersession |
| Capture substantial research | [Research](documentation_spec_research.rules.md): naming, consumers, evidence |
| Plan local execution | [plan.md](documentation_spec_planning.rules.md): verification phase and optional dependency graph |
| Work with Jira projections or view-root presentation maps | [Source ownership](documentation_spec_sources.rules.md): one-way publication, managed tail, Figma and PRESENTATION.md boundaries |

Creating a topic requires the complete `requirements.md` + `spec.md` + `log.md`
triad. Read those artifact rules. A focused edit does not require loading
unrelated templates. Detailed authoring rules stay in `agents/rules/` with
artifact-specific scopes and `alwaysApply: false`. Read them when relevant.

## Authoring and finalization

- Draft requirements first, with explicit Scope, Out of Scope, and Verification.
  `spec.md` MAY land while questions are open. Design the parts that no
  question blocks. Mark each blocked part `TBD(Q-…)`. See
  [open questions and TBD markers](documentation_spec_traceability.rules.md#open-questions-and-tbd-markers).
- When requirements change, update the current design together. Append a decision
  only when the accepted choice meets the [decision threshold](documentation_spec_decisions.rules.md#decision-threshold).
  Remove gaps once implementation satisfies their resolution conditions.
- Cross-link current truth: `spec.md` links to `requirements.md`, `log.md`, and
  `gap.md` when present at the top. Requirements link forward to the design.
  Gaps link exact spec assertions and implementation evidence. Link relevant
  research from each committed artifact that consumes it.
- Validate every changed topic with
  `dart run agents/scripts/validate_specs.dart <topic-path>`.
  Add `--final` when handing off a completed `spec.md`. The flag treats every
  warning as a failure, including a legacy open question without a `Q-*` ID.
  Review diagram semantics as well as the validator's syntax checks.
- When Jira is in scope, publish only after local files are current and reviewed.
  Republish affected projections after local changes. Follow the conditional
  [source ownership contract](documentation_spec_sources.rules.md).
- If execution needs a local plan, follow [planning](documentation_spec_planning.rules.md),
  including its required final Verification phase. At the end of a working
  session, capture reusable findings under the
  [memory criteria](documentation_memory.rules.md). Route each finding to its
  owning artifact rather than recording routine activity.

## Compatibility entry points

These anchors route existing links to their owning rules.

### Location

See [spec location rules](documentation_spec_common.rules.md#location).

### log.md

See [decision-log authoring](documentation_spec_decisions.rules.md).

### Decision threshold

See the [accepted-decision threshold](documentation_spec_decisions.rules.md#decision-threshold).

### Plan (`plan.md`)

See [local plan authoring](documentation_spec_planning.rules.md) and its
[Verification phase rules](documentation_spec_planning.rules.md#verification-phase-rules).

## Related

- [`documentation.rules.md`](documentation.rules.md) — token-efficient writing style for agents docs (also applies inside specs).
- [`documentation_memory.rules.md`](documentation_memory.rules.md) — what to capture as long-lived memory vs. ephemeral notes.
- [`verification.rules.md`](verification.rules.md) — lifecycle-boundary verification and evidence.
- `agents/scripts/validate_specs.dart` — validates a canonical spec topic and
  its cross-links.
