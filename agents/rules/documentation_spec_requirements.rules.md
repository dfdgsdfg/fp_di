---
description: Requirements authoring with scope, user stories, use cases, and observable verification criteria
paths:
  - "specs/**/requirements.md"
globs:
  - "specs/**/requirements.md"
alwaysApply: false
---

# requirements.md

Read the [shared contract](documentation_spec_common.rules.md) and the [authoring router](documentation_spec.rules.md) with this reference. Read [traceability](documentation_spec_traceability.rules.md) when defining or mapping `R-*`, `V-*`, `G-*`, or `Q-*` IDs, or when writing a `TBD` marker.

**Purpose:** describe the problem, who it serves, and what the system must do — **not** how to build it.

**Workflow:** Start from the canonical local topic and any supplied brief or
source material. Update local truth before creating any downstream projection.
This repository does not install a dedicated requirements-authoring skill.

## Required sections

1. **Problem Statement** — the user/business pain in plain language (1–3 paragraphs). Why this work exists.
2. **Scope** — bullet list of what is included.
3. **Out of Scope** — bullet list of what is explicitly excluded. Critical for preventing drift.
4. **User Stories** — for **user-perceived** experience. Prefix each entry with `R-US-*`. Format the body as `As a {persona}, I want {capability}, so that {benefit}.` Group by persona or flow when many.
5. **Use Cases** — for **system-level** behavior, constraints, and contracts that aren't directly observed by the user (auth refresh, retry policy, cache invalidation, error mapping). Prefix each entry with `R-UC-*`. Format the body as actor → trigger → preconditions → main flow → alternative flows → postconditions.
6. **Verification (통과 항목)** — the acceptance criteria that decide "done." Prefix each entry with `V-{kind}-*`. Each story or use case must have at least one covering criterion. Write them so anyone (QA, PM, another dev) can independently judge pass/fail.

   - `requirements.md` owns the canonical meaning and observable pass condition of every `V-*` criterion. It answers **what must be true**, not which test file or fixture proves it.
   - Format: `Given {context}, when {action}, then {observable outcome}.` Or a numbered checklist when state-based.
   - Tag each item by *the kind of artifact* that closes it. Each tag maps 1:1 to something `spec.md` must specify (see [Verification](documentation_spec_design.rules.md#verification)):

     | Tag | Closes when… | spec.md must specify | Skill that authors / runs it |
     |-----|--------------|------------------------|------------------------------|
     | `[test]` | An automated test passes | Test layer (unit / widget / golden / integration), target, file path, fixtures, pass condition | Author and run the relevant package test directly |
     | `[lint]` | Static analysis passes | Rule (`dart analyze`, custom lint, formatter, type check) and config | Run the repository's Dart/Flutter checks |
     | `[qa]` | A manual QA scenario is exercised and signed off | Link to the QA scenario in `qa_{version}.md` | Maintain the scenario beside the owning topic |
     | `[telemetry]` | A production metric stays within a threshold | Dashboard link (Datadog / Crashlytics / GA4) + threshold | (no skill — hand-link the dashboard) |
     | `[approval]` | A stakeholder explicitly signs off (legal, accessibility, design) | Stakeholder + approval document or thread | Record the approval source directly |

   - Reference the exact story / use-case IDs it covers (e.g., `Covers: R-US-SUB-PAY-001, R-UC-SUB-PAY-002`).
   - **Example:**
     ```markdown
     - <a id="v-t-sub-pay-001"></a>**V-T-SUB-PAY-001** `[test]` Given a logged-in member with no payment method, when they tap subscribe, then the payment form opens. Covers: `R-US-SUB-PAY-001`.
     - <a id="v-t-sub-pay-002"></a>**V-T-SUB-PAY-002** `[test]` Given an expired access token, when the subscription API fires, then the token is refreshed once before retry; second failure pops the session. Covers: `R-UC-SUB-PAY-003`.
     - <a id="v-l-sub-pay-001"></a>**V-L-SUB-PAY-001** `[lint]` No `// ignore: invalid_use_of_protected_member` survives in the new ViewModel. Covers: `R-UC-SUB-PAY-002`.
     - <a id="v-q-sub-pay-001"></a>**V-Q-SUB-PAY-001** `[qa]` Given iPad mini 5 / iPadOS 26 with <100MB free, when checkout opens and completes, then no crash and memory stays <600MB. Covers: `R-US-SUB-PAY-001`.
     - <a id="v-tel-sub-pay-001"></a>**V-TEL-SUB-PAY-001** `[telemetry]` Crash-free sessions for the subscription screen ≥ 99.95% over 7 days post-release. Covers: `R-US-SUB-PAY-001`.
     - <a id="v-a-sub-pay-001"></a>**V-A-SUB-PAY-001** `[approval]` Subscription failure copy approved by legal. Covers: `R-US-SUB-PAY-002`.
     ```
   - Anti-pattern: vague criteria like "feature works correctly" or "no regression" without an observable rule.

## Optional sections

- **Design Principles** — guiding tradeoffs (e.g., "favor offline-first over freshness", "fail closed on permission errors"). Useful when designers/engineers face recurring choices.
- **Glossary** — topic-local terms only. Link a shared term to its ontology `concept` node instead of redefining it.
- **References** — sources that **constrain** the requirements: legal/compliance docs, platform guidelines (Apple HIG, Material), partner contracts, regulatory rules, prior tickets, market research, customer interviews. Link out. Do not paraphrase. Each reference should answer "why is this requirement non-negotiable?" In-depth research goes in `researches/{target}.researches.md`.
- **Open Questions** — explicit unknowns. Each entry has a `Q-*` ID and a `Resolve when` condition. `spec.md` MAY land while questions are open. Mark a blocked contract `TBD(Q-…)`. See [open questions and TBD markers](documentation_spec_traceability.rules.md#open-questions-and-tbd-markers).

## When to use story vs. use case

| Aspect | User Story | Use Case |
|--------|------------|----------|
| Driven by | A persona's goal | A system contract |
| Visible | Yes (UI, copy, output) | Often invisible (background job, retry, mapping) |
| Trigger | User action | User OR system event |
| Output | Narrative | Step-by-step actor/system flow |
| Example | "As a member, I want to see only my paid content so that I don't waste time on locked items." | "When the access token expires, the auth service refreshes it once; on second failure, the session pops and the user is sent to login." |

A feature usually has **both**.

## Anti-patterns

- Implementation details (class names, file paths, library choices) — those belong in `spec.md`.
- Sprint-tracker noise (status, assignee, ETA).
- Open-ended "we should consider…" without a decision or an Open Questions entry with a `Q-*` ID.
