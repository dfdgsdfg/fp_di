---
description: Spec research notes with source evidence, consumers, and durable findings
paths:
  - "specs/**/researches/*.researches.md"
globs:
  - "specs/**/researches/*.researches.md"
alwaysApply: false
---

# Research notes (`researches/{target}.researches.md`)

Read the [shared contract](documentation_spec_common.rules.md) and the [authoring router](documentation_spec.rules.md) with this reference.

**Purpose:** capture internal/external case studies, comparative analysis, and exploratory findings that inform — but are not themselves — requirements or design decisions.

Use research notes when the work is too long to inline as a `References` bullet. Use them also when the analysis itself is the deliverable (e.g., "evaluated 4 charting libraries before picking fl_chart"). Without a research note, the *why* behind a requirement or design choice gets lost.

## Location & Naming

All research notes live under a `researches/` subfolder of the topic. Files are named `{target}.researches.md` where `{target}` names the subject in kebab-case. Be specific:

| Good | Bad |
|------|-----|
| `researches/internal-feed-onboarding.researches.md` | `researches/onboarding.researches.md` |
| `researches/external-duolingo-streaks.researches.md` | `researches/competitors.researches.md` |
| `researches/flutter-overlay-libraries.researches.md` | `researches/libraries.researches.md` |
| `researches/ios-26-background-lifecycle.researches.md` | `researches/ios.researches.md` |

Multiple research notes per topic are fine. One per distinct line of inquiry is preferred over one mega-doc. The subfolder keeps the topic root scannable when more than one or two notes accumulate.

## Required sections

1. **Subject** — one-sentence statement of what is being researched.
2. **Why** — link back to the spec section (`requirements.md#scope` or `spec.md#overview`) that needed this. If a research note has no consumer, delete it.
3. **Findings** — the substantive content. Internal: code paths, prior incidents, prior tickets. External: vendor docs, competitor analysis, library comparison, blog posts, papers. Cite versions/commits/dates.
4. **Implications** — bullet list of how the findings should affect the spec. This list is what `requirements.md` / `spec.md` consumes.

## Optional sections

- **Methodology** — how the research was conducted (only when it matters: "tested on iPad mini 5 / iOS 26.3.1", "manually instrumented X for 24h").
- **Open Questions** — what's still unknown and should be revisited.

## Anti-patterns

- A research note without a `Why` link — orphaned research rots fastest.
- Pasting full vendor docs — link to them, summarize the relevant 1–2 paragraphs.
- Restating findings as requirements — once a finding becomes a constraint, move it into `requirements.md` and reference the research note.

When a source becomes stale, refresh the note or mark it superseded.
