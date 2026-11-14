---
description: How to update agents/rules/ files as project memory — what to record, what to skip, and how to write it
paths:
  - "agents/rules/*.rules.md"
globs: "agents/rules/*.rules.md"
alwaysApply: false
---

# Rules as Memory

`{topic}` denotes a domain, optionally followed by a subdomain when its contract
needs an independent lifecycle. See [spec location rules](documentation_spec_common.rules.md#location).

`agents/rules/` is the project's institutional memory. Every session loads these files into context. A well-placed rule prevents the same mistake from recurring across developers and AI agents.

## What to Record

Rules capture the **non-obvious** — things code alone doesn't convey. Focus on:

| Category | Example |
|----------|---------|
| **Pitfall / Gotcha** | "A cleanup failure must not prevent unrelated dependents from being released" |
| **Constraint** | "A component's committed publisher view remains readable while its cleanup runs" |
| **Design Decision + Reason** | "Independent module members activate and release concurrently, but the steps of one component run in order to preserve LIFO ownership" |
| **Edge / Corner Case** | "A publisher appearing after a `Component.maybe` lookup must trigger reconciliation because the absent key is still watched" |
| **Trade-off** | "Separate installed components are serialized for predictable lifecycle ordering, even when their graphs are unrelated" |
| **Assumption** | "A supplied Flutter `Scope` remains caller-owned; `ScopeProvider` only owns its widget-local scope" |
| **Limitation** | "A module commits its members one by one, so several values become visible together only as one published record" |
| **Risk / Hazard** | "Calling `initialize` or `dispose` from an acquire or a release would deadlock; the runtime must report `ReentrantMutationError`" |
| **Exception to a Rule** | "The runtime rejects a publication outside `publishes`, but `publishes` is an allowed set: a conditional body may publish fewer keys than it declares" |

## What NOT to Record

| Skip | Why |
|------|-----|
| General patterns derivable from code | Read the code |
| What was done | `git log` is authoritative |
| Standard library/framework usage | Docs exist |
| One-off fix with obvious cause | No recurrence risk |
| Implementation detail of one feature | Too narrow to be useful |

**Litmus test:** "If I lost all memory and saw similar code next month, would I make the same mistake without this rule?" — if no, skip it.

## Rules vs. spec decision logs

`agents/rules/` stores the **currently applicable cross-topic rule**. A topic's `specs/{topic}/log.md` stores the **accepted decision and rationale at the time it changed**.

| Record in | When |
|-----------|------|
| `spec.md` | Current topic-specific design truth |
| `log.md` | Significant accepted topic decision; preserve and supersede rather than rewrite |
| `agents/rules/` | The decision establishes a reusable project-wide constraint or pitfall |
| Git / PR / CI | What changed, implementation activity, and routine verification |

When a decision becomes a project rule, write the concise current rule here. Link the qualifying `log.md` entry for rationale. Do not copy the full decision history into `agents/rules/`. See [`documentation_spec.rules.md#logmd`](documentation_spec.rules.md#logmd).

## How to Write

### Find the Right File

```bash
ls agents/rules/*.rules.md
```

Match the learning to an existing file. Prefer extending over creating new files. Create a new file only when no existing file covers the domain.

### Structure: Problem → Code → Rules

```markdown
### Section Title — Brief Description

Problem in 1-2 sentences. Version where discovered (e.g., "3.29.0에서 발견").

\`\`\`dart
// Before — the broken pattern:
Future<void> initialize() async {
  ...
  throw StateError('failed');  // ← crash
}

// After — the correct pattern:
Future<bool> initialize() async {
  ...
  return false;  // ← graceful
}
\`\`\`

**Rules:**
- Concrete rule 1
- Concrete rule 2
```

### Format choice — table vs decision tree

When a rule describes **multiple implementation modes / application paths** the reader has to **choose between** based on conditions, prefer a **Mermaid decision tree (`flowchart TD`)** over a table. Tables flatten the branching into a wall of rows. A tree makes the actual decision the reader has to make explicit.

| Shape of the rule | Use |
|-------------------|-----|
| One canonical pattern + Before/After example | Code block + bullet list |
| One axis of variants (≤ ~4 rows, no branching conditions) | Table |
| ≥2 axes, OR "if X then Y else Z" branching, OR cross-cutting categories the reader must triage | **Mermaid `flowchart TD`** |
| Lifecycle / sequence with explicit ordering | Mermaid `flowchart` or `sequenceDiagram` |

**Concrete cue**: if you find yourself writing a table where the first column is "When …" / "If …" / "Case" and the rows have nested sub-conditions in the second column, the tree form is cleaner.

**Examples in the codebase**:
- Lifecycle composition (derived vs declared, token key vs concurrent) — see the
  applicable lifecycle rule or canonical spec.
- Session workflow and commit scope — follow the root `AGENTS.md` and current
  repository conventions.

Use plain-text labels with `<br/>` for line breaks (works in GitHub-rendered Markdown). Cap ≤ ~12 nodes — bigger flows belong in `specs/<topic>/spec.md`.

### Writing Principles

- **Concrete code for pitfalls** — show the actual Before/After, not pseudo-code
- **State the "why"** — future readers need the reasoning, not just the rule
- **Keep it scannable** — tables and bullet lists over paragraphs
- **Decision trees for branching choices** — see "Format choice" above
- **Reference version** — note which version the issue was found in
- **Link files** — `See path/to/file.dart` for implementation context
- **English** — all `agents/rules/` content in English (per `documentation.rules.md`)
- **~30 lines max** per section — if longer, make it more concise

### Anti-patterns

| Don't | Do instead |
|-------|-----------|
| "MUST NOT do X" without reason | "Don't do X because Y happens" |
| Vague rule ("be careful with lifecycle") | Specific pitfall ("a reentrant mutation from cleanup raises `ReentrantMutationError` instead of waiting") |
| Duplicating existing rule | Link to the existing applicable rule instead |
| Domain-specific names in examples | Generic names unless the pitfall IS domain-specific |

## Related

- [documentation.rules.md](documentation.rules.md) — writing style, token efficiency, structure patterns
- Session retrospective — fold durable lifecycle learnings into the canonical
  spec or an applicable rule. Keep routine activity in Git history.
