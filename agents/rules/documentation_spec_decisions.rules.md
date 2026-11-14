---
description: Accepted decision log thresholds, append-only entries, and supersession rules
paths:
  - "specs/**/log.md"
globs:
  - "specs/**/log.md"
alwaysApply: false
---

# log.md

Read the [shared contract](documentation_spec_common.rules.md) and the [authoring router](documentation_spec.rules.md) with this reference.

**Purpose:** preserve the rationale for significant, accepted decision changes without turning `requirements.md` or `spec.md` into a chronological diary. The file is an append-only, ADR-inspired decision log. Newest entries go at the bottom.

Write at the abstraction level of behavior contracts, responsibility boundaries,
architecture, and durable policy. Explain a decision that remains meaningful
when individual functions or classes are renamed or replaced. Code references
MAY support the rationale. Local implementation choices and caveats such as
branch handling, caller assumptions, and function-specific edge cases belong
in the commit body. When a code-level finding
motivates a durable contract, record the contract-level decision here.
Keep the implementation-specific reasoning in the commit.

Preserve accepted entries. When a decision changes, append a new entry that supersedes the earlier one instead of rewriting the old rationale. Small typo and broken-link fixes are allowed.

## Decision threshold

Append one entry only when **all** of these are true:

1. A choice was accepted, not merely proposed or investigated.
2. The choice durably affects behavior, contracts, architecture boundaries, dependency direction, lifecycle, compatibility, security, performance, data integrity, or a material operational trade-off.
3. A future maintainer could reasonably ask why this option was chosen over another.

Record exactly one decision per entry. Typical entries resolve an Open Question (cite its `Q-*` ID, for example `Resolves Q-WV-BRG-001`), choose among meaningful alternatives, establish a durable cross-cutting constraint, or replace an earlier decision.

Do **not** log:

- file creation, movement, code generation, dependency refreshes, or summaries of changed files;
- analyze/test/CI results, deployment status, visual-diff iterations, or routine verification;
- raw research, meeting chronology, assignees, ETAs, proposals, or unresolved alternatives;
- restatements of current behavior already clear from `requirements.md`, `spec.md`, or code.

Put current truth in `requirements.md` / `spec.md`, verified open divergence in `gap.md`, unresolved choices in `Open Questions` (`Q-*` entries), substantial evidence in `researches/`, execution sequencing in `plan.md`, transient work in `agents/scratchpads/`, and activity history in Git/PR/CI.

## Decision entry grammar

Each entry is a grep-parseable H2 followed by three required concise bullets:

```markdown
## [YYYY-MM-DD] decision | <Accepted decision title>

- Context: <requirement, constraint, or conflict that forced a choice>
- Decision: <accepted choice in active voice>
- Consequences: <important benefit, cost, risk, or follow-up>
- Supersedes: <optional link to the earlier decision>
- References: <optional research, issue, incident, PR, or external source>
```

- `Context`, `Decision`, and `Consequences` are required. Include both positive and negative consequences when the trade-off matters.
- `Supersedes` and `References` are optional. Link the prior entry when replacing a decision.
- Accepted entry bodies are immutable. A later choice appends a new entry whose `Supersedes` field links the earlier decision.
- `log.md` frontmatter uses `type: log`. The description identifies the decision scope.

Example file header:

```markdown
---
type: log
title: "Session Lifecycle — Decision Log"
description: "Accepted decisions that changed the session lifecycle design."
tags: [session, lifecycle, log]
---

# Session Lifecycle — Decision Log

Append accepted decisions only. Newest at the bottom.
```

This log follows the ADR principle that one record captures one significant decision and its rationale and consequences. See [Architectural Decision Records](https://adr.github.io/).
