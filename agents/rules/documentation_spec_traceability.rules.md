---
description: Stable requirement, verification, gap, and open question IDs with immutable traceability mappings, ID anchors and links, plus the TBD marker
paths:
  - "specs/**/requirements.md"
  - "specs/**/spec.md"
  - "specs/**/gap.md"
  - "specs/**/log.md"
  - "specs/**/plan.md"
globs:
  - "specs/**/requirements.md"
  - "specs/**/spec.md"
  - "specs/**/gap.md"
  - "specs/**/log.md"
  - "specs/**/plan.md"
alwaysApply: false
---

# Traceable requirement IDs

Read the [shared contract](documentation_spec_common.rules.md) and the [authoring router](documentation_spec.rules.md) with this reference.

Every `requirements.md` **MUST** declare one stable `id_prefix`. The prefix is the
topic's compact identity. The topic's stories, use
cases, verification criteria, known gaps, `spec.md` mappings, and local
`plan.md` share the prefix.

```yaml
---
type: requirement
title: "WebView JS Bridge Contract — Requirements"
description: "Requirements for the app-injected web bridge contract."
tags: [webview, bridge, contract]
id_prefix: "WV-BRG"
---
```

When consolidating existing topics, preserve their IDs. The destination retains
one primary `id_prefix` and MAY declare an inline YAML list such as
`legacy_id_prefixes: [AR-UI]` for inherited namespaces. New IDs use the primary
prefix. All primary and legacy prefixes MUST be valid and globally unique.
Legacy entries MUST NOT duplicate each other or the primary prefix. The legacy
list is a migration mechanism, not a reason to add namespaces for new topics.

| Artifact | Grammar | Example |
|----------|---------|---------|
| User Story | `R-US-{ID_PREFIX}-{NNN}` | `R-US-WV-BRG-001` |
| Use Case | `R-UC-{ID_PREFIX}-{NNN}` | `R-UC-WV-BRG-001` |
| Automated test | `V-T-{ID_PREFIX}-{NNN}` | `V-T-WV-BRG-001` |
| Lint / static analysis | `V-L-{ID_PREFIX}-{NNN}` | `V-L-WV-BRG-001` |
| Manual QA | `V-Q-{ID_PREFIX}-{NNN}` | `V-Q-WV-BRG-001` |
| Telemetry | `V-TEL-{ID_PREFIX}-{NNN}` | `V-TEL-WV-BRG-001` |
| Stakeholder approval | `V-A-{ID_PREFIX}-{NNN}` | `V-A-WV-BRG-001` |
| Known spec/implementation gap | `G-{ID_PREFIX}-{NNN}` | `G-WV-BRG-001` |
| Open question | `Q-{ID_PREFIX}-{NNN}` | `Q-WV-BRG-001` |

**Prefix rules:**

- `ID_PREFIX` **MUST** be exactly `{DOMAIN}-{SUBDOMAIN}`. Each segment uses
  2–4 uppercase ASCII letters or digits. Examples: `WV-BRG`, `WV-CKI`,
  `SES-LC`, `AN-GA4`. The parseable pattern is
  `^[A-Z0-9]{2,4}-[A-Z0-9]{2,4}$`.
- Search existing `id_prefix:` declarations before choosing one. Reuse each
  abbreviation segment for the same meaning. Never reuse a segment for a
  different meaning. The full prefix **MUST** be unique among active
  `requirements.md` topics. A relocated topic keeps its existing prefix.
  These frontmatter declarations form the repository abbreviation registry.
- Prefer established, recognizable abbreviations. If a 2–4 character form is
  ambiguous, choose another recognizable abbreviation instead of inventing an
  opaque one.

**Lifecycle and usage rules:**

- `NNN` is a zero-padded, three-digit sequence starting at `001`, scoped to
  the artifact grammar and `ID_PREFIX`.
- Full IDs **MUST** be repository-unique and match
  `^R-(US|UC)-{ID_PREFIX}-[0-9]{3}$` or
  `^V-(T|L|Q|TEL|A)-{ID_PREFIX}-[0-9]{3}$` or
  `^G-{ID_PREFIX}-[0-9]{3}$` or `^Q-{ID_PREFIX}-[0-9]{3}$`.
- An ID is immutable after review. Moving or renaming a document does not
  change the ID. Reordering entries does not trigger renumbering.
- Changing a verification artifact kind is criterion replacement, not a
  retag. After review, do not pair `V-T-*` with `[qa]` or rename it to
  `V-Q-*`. Add the next unused ID for the new kind through
  the requirements workflow. Remove the superseded criterion from current truth.
  Never reuse its old ID. Update every projection/mapping. Record the
  replacement in `log.md` only when it meets the decision threshold.
- Removed or superseded IDs **MUST NOT** be reused. Record the replacement in
  `log.md` only when the change meets the [decision threshold](documentation_spec_decisions.rules.md#decision-threshold).
- User Stories and Use Cases **MUST** place the ID at the start of the entry,
  after its [anchor](#id-anchors-and-links).
  Verification criteria **MUST** place their ID before the artifact tag and
  include `Covers:` with one or more `R-US-*` / `R-UC-*` IDs.
- Scope bullets, prose paragraphs, headings, diagrams, and routine decisions
  **MUST NOT** receive IDs. IDs exist for traceability, not line numbering.
- Defining entries bold their ID (`**R-UC-...**`). A plain reference cites the ID
  without backticks, so search and validation see one form. A
  [link](#id-anchors-and-links) uses the ID as its text.

```markdown
## User Stories

- <a id="r-us-wv-brg-001"></a>**R-US-WV-BRG-001** — As a web developer, I want a typed bridge surface, so that invalid calls fail at build time.

## Use Cases

- <a id="r-uc-wv-brg-001"></a>**R-UC-WV-BRG-001** — Capability gating
  - Actor: web page
  - Trigger: first page script
  - Main flow: read the injected capability and call only supported methods
  - Postcondition: unsupported app versions use the browser-safe fallback

## Verification

- <a id="v-t-wv-brg-001"></a>**V-T-WV-BRG-001** `[test]` Given no bridge capability, when the page initializes, then no native method is called. Covers: `R-US-WV-BRG-001`, `R-UC-WV-BRG-001`.
```

## ID anchors and links

Each ID entry carries an explicit HTML anchor, so that a Markdown link can
target the ID. A heading slug includes the title text and breaks when the title
changes. A list item or a table row has no anchor of its own.

**Anchor:** write `<a id="{id}"></a>` directly before the ID text. `{id}` is the
full ID in lowercase. GitHub lowercases `id` attributes, so an uppercase anchor
does not match on GitHub.

```markdown
- <a id="r-us-wv-brg-001"></a>**R-US-WV-BRG-001** — As a web developer, …
## <a id="g-wv-brg-001"></a>G-WV-BRG-001 — Web reports echo app rejects
### <a id="v-t-wv-brg-001"></a>V-T-WV-BRG-001 — Document-start injection
| <a id="v-t-wv-brg-002"></a>`V-T-WV-BRG-002` | `test/bridge_test.dart` |
```

| Entry | File | Anchor |
|-------|------|--------|
| `R-*`, `V-*` definition | `requirements.md` | **MUST** |
| `Q-*` definition | `requirements.md` or `spec.md` | **MUST** |
| `G-*` definition | `gap.md` | **MUST** |
| `V-*` mapping entry: a heading, a bullet, or a table row whose first cell is only the ID | `spec.md` | **MUST** |
| Any other mention | any | **MUST NOT** |

- One file holds at most one anchor for each ID.
- The anchor does not change a heading slug. Existing heading links stay valid.

**Link:** a reference link uses the ID as its text and the ID anchor as its
fragment: `` [`R-US-WV-BRG-001`](../bridge_contract/requirements.md#r-us-wv-brg-001) ``.

| Reference | Rule |
|-----------|------|
| Current ID of another topic, in `requirements.md`, `spec.md`, or `gap.md` | Link **MUST** |
| ID of another file in the same topic, or in `log.md` | Link **MAY** |
| `Covers:`, `Blocks:`, `TBD(Q-…)`, and mentions in the same file | Plain text |
| Retired ID, code comment, commit message, ontology evidence | Plain text |

- Link the ID anchor, not the heading slug (`#g-wv-brg-001`, not
  `#g-wv-brg-001--web-reports-echo-app-rejects`).
- A link to a `V-*` targets the definition in `requirements.md`. Link the
  mapping in `spec.md` only to point at the verification implementation.
- When an ID is retired, remove or unlink every link to its anchor. A `log.md`
  entry keeps the retired ID as plain text.
- Plain IDs stay searchable: the ID text remains next to every anchor and in
  every link text.

## Open questions and TBD markers

An open question records a product or design choice that nobody has decided.
It is a spec artifact with a `Q-*` ID. A research note keeps its free-form
`Open Questions` section. A research note is evidence, not a normative
artifact, and its questions do not receive `Q-*` IDs.

**Location:** an `## Open Questions` section in `requirements.md` for a product
question, or in `spec.md` for a design question. Both files share the `Q-*`
namespace of the topic.

**Lifecycle:** a `Q-*` ID follows the same rules as a `G-*` ID. The ID is
immutable and repository-unique. Never reuse the ID after the entry is removed.

**Entry shape:**

```markdown
## Open Questions

- <a id="q-wv-brg-001"></a>**Q-WV-BRG-001** — Capability negotiation: version number or feature flags
  - Options: (a) one integer protocol version, (b) a set of named feature flags
  - Blocks: `R-UC-WV-BRG-001`, `V-T-WV-BRG-001`
  - Resolve when: the app and web teams agree on the negotiation model
```

- Put the [anchor](#id-anchors-and-links) and the ID first. Follow them with ` — `
  and the question.
- `Options` is OPTIONAL. List the known alternatives.
- `Blocks` is OPTIONAL. List the `R-*`, `V-*`, or `G-*` IDs and the links that
  the question blocks. Each listed ID **MUST** exist in the topic.
- `Resolve when` is REQUIRED. State a condition or a trigger, not a date.
- Do not add an owner, an ETA, or a status field. Jira owns that data, as in
  [gap.md](documentation_spec_gap.rules.md).
- Omit the section when no question is open.

**Inline marker:** `TBD(Q-XXX-YYY-NNN)` marks an undecided contract in
`requirements.md` or `spec.md`.

- A bare `TBD` without `(Q-…)` is an error in these files.
- The referenced `Q-*` ID **MUST** be defined in the same topic.
- `TBD` is not an RFC 2119 keyword. It states that a contract is not decided.
  Do not write **MUST** or **SHOULD** for a `TBD` contract.
- The validator ignores `TBD` in fenced code blocks and inline code spans.

**Landing:** `spec.md` MAY land while questions are open. Design the parts that
no question blocks. Mark each blocked part with `TBD(Q-…)`.

**Resolution:**

1. Write the decision into `requirements.md` or `spec.md`.
2. Remove every `TBD(Q-…)` marker for the question.
3. Remove the `Q-*` entry. The ID is retired and never reused.
4. Add a `log.md` entry that cites `Resolves Q-…` when the decision meets the
   [decision threshold](documentation_spec_decisions.rules.md#decision-threshold).

**Legacy shape:** an `Open Questions` bullet without a leading `**Q-…**` ID is
legacy. The validator reports a warning. Migrate the bullet when you edit its topic.
