---
description: Canonical spec, Jira projection, Figma source, and view-local presentation ownership
paths:
  - "**/views/**/PRESENTATION.md"
globs:
  - "**/views/**/PRESENTATION.md"
alwaysApply: false
---

# Source ownership and Jira projections

Read the [shared contract](documentation_spec_common.rules.md) and the [authoring router](documentation_spec.rules.md) with this reference.

Repository specs and Jira issues serve different lifecycles. They **MUST NOT**
act as competing sources of truth.

| Surface | Ownership | Contents |
|---------|-----------|----------|
| `specs/{topic}/` | Canonical product/technical contract | Durable requirements, accepted design, verification mapping, decisions, and known gaps |
| `{view-root}/PRESENTATION.md` | Optional view-local presentation contract | Composition, visible states/interactions, design-system mapping, responsive/accessibility constraints, and links to canonical IDs, Figma nodes, previews, and goldens |
| Jira issue description | Issue-scoped delivery projection | The subset of canonical `R-*` / `V-*` IDs delivered by the issue, the `Q-*` open questions that block it, issue impact, dependencies, design links, and schedule/status |
| Figma / FigJam | Visual and UX source | Visual values, component states, interaction flows, and design approval evidence |
| `plan.md` / scratchpads | Execution state | Implementation ordering, checklists, and transient investigation notes |

**Rules:**

- Local spec files are the canonical source for requirement meaning and
  accepted implementation design. Jira **MUST NOT** own an independent copy of
  either contract.
- Jira content is a downstream **Issue Spec projection**. Publish only the
  requirements, verification criteria, open questions, and design summary
  relevant to that issue. Link every projection row to its local topic.
  Preserve exact `R-*` / `V-*` / `Q-*` IDs. Do not add an owner or a status to
  a projected question. Jira owns that data.
- Synchronization is one-way: local spec → Jira projection. Treat manual Jira
  edits as source material or a change request. Reconcile them into the local
  topic first. Then republish the projection.
- A cross-domain Jira issue **MAY** project from multiple local topics. Do not
  create an issue-shaped cross-domain topic only to mirror the ticket. Create a
  new topic only for a coherent, long-lived requirements/design lifecycle.
- A Jira projection **SHOULD** identify the source paths and the commit or PR
  revision used to generate it, when available. A stale projection never
  overrides newer local content.
- Jira publication **MUST** re-read the issue immediately before writing,
  preserve Jira-authored content before the managed `---` + `# Issue Spec`
  tail, and replace exactly one valid managed tail. Duplicate or malformed
  markers, concurrent edits, or manually changed projected content require
  reconciliation. Do not overwrite them blindly.
- Figma links in Jira identify the issue's design slice. Durable behavior,
  architecture, and verification design still belong in the relevant local
  `requirements.md` / `spec.md`. Figma still owns exact visual values.

## View-root PRESENTATION.md

`PRESENTATION.md` is a colocated presentation map, not another spec topic. It
MAY exist at a coherent Screen/Page root when the view has non-trivial
composition, state variants, responsive behavior, or golden coverage.

- Link canonical `R-*` / `V-*` IDs. Do not restate their meaning.
- Record Screen/Page/Section/Widget responsibilities and stable mappings to
  Figma nodes, design-system components, previews, and golden tests.
- Do not copy exact visual values from Figma or cross-layer design from
  `spec.md`.
- Do not record Jira status, TODOs, dates, SSIM runs, approvals, or change
  history. Use Jira/scratchpads for execution state, verification output for
  run results, and Git for history.
- Do not create one for every widget. Test-only metadata stays beside the
  golden test.
