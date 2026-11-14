---
description: Known gap authoring with current divergence evidence and resolution conditions
paths:
  - "specs/**/gap.md"
globs:
  - "specs/**/gap.md"
alwaysApply: false
---

# Known gaps (`gap.md`)

Read the [shared contract](documentation_spec_common.rules.md) and the [authoring router](documentation_spec.rules.md) with this reference. Read [traceability](documentation_spec_traceability.rules.md) when defining or mapping `R-*`, `V-*`, or `G-*` IDs.

**Purpose:** record verified, currently open differences between the accepted
`requirements.md` / `spec.md` and the current implementation. `gap.md` is a
committed snapshot of known divergence, not a delivery plan or a history of
completed work.

Create `gap.md` only inside an existing spec topic. A gap is valid only when
both sides can be cited: the accepted expectation in the spec and evidence of
different current behavior or structure in the implementation. Desired future
features, unresolved product choices, and unverified suspicions are not gaps.

The file uses the standard committed-document frontmatter:

```markdown
---
type: gap
title: "Session Lifecycle — Known Gaps"
description: "Verified open differences between the accepted session lifecycle spec and implementation."
tags: [session, lifecycle, gap]
---

# Session Lifecycle — Known Gaps
```

## Entry grammar

Every open gap **MUST** use a stable `G-{ID_PREFIX}-{NNN}` heading with an
[ID anchor](documentation_spec_traceability.rules.md#id-anchors-and-links)
and contain the following fields:

```markdown
## <a id="g-ses-lc-001"></a>G-SES-LC-001 — Refresh failure preserves a stale credential

- Spec: [`spec.md#session-teardown`](spec.md#session-teardown) requires both credentials to be cleared.
- Implementation: `packages/{package}/lib/.../session_repository.dart:84` clears only the access token.
- Impact: A later refresh can reuse a credential that the accepted lifecycle considers invalid.
- Resolution condition: Implementation satisfies the linked spec, or the accepted spec is revised to describe the intended behavior.
- Evidence: Reproducing test, production evidence, issue, or inspected code path.
```

**Rules:**

- `Spec`, `Implementation`, `Impact`, `Resolution condition`, and `Evidence`
  are required. Link exact headings, code paths, tests, logs, or issues rather
  than paraphrasing an entire document.
- Describe the observable or structural delta. Do not prescribe the patch,
  work order, assignee, priority, target date, or release vehicle here.
- Keep only open gaps. Once the resolution condition is met, remove the entry.
  Git history records that the entry existed. Remove `gap.md` when the final entry is
  resolved.
- If implementation is intentionally accepted as the new truth, update
  `requirements.md` / `spec.md` first. Append a `log.md` entry when the change
  meets the decision threshold. Then remove the gap.
- A gap ID is immutable and **MUST NOT** be reused after removal. A local
  `plan.md`, Jira issue, or PR **MAY** reference the ID while closing it.

## `gap.md` vs. `plan.md`

`gap.md` answers **what is known not to match now**. `plan.md` answers **how
and in what order the implementation will be changed**. A gap may be an input
to a plan, but it remains valid independently of any particular implementation
sequence. Do not copy plan checklists into `gap.md`. Do not require every
plan task to have a gap. New implementation work can directly realize an
accepted spec without correcting an existing divergence.

## Anti-patterns

- Backlog items such as “support provider X later” when the accepted spec does
  not require provider X.
- Checkboxes, owners, ETAs, release status, or “next steps.”
- Closed-gap history. Use Git/PR history. Use `log.md` only for a qualifying
  accepted decision change.
- A mismatch stated without both a spec reference and implementation evidence.
