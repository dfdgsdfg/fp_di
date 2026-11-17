# Agent bootstrap

[AGENTS.md](../AGENTS.md) is the shared project entry point.
[Documentation rules](rules/documentation_spec.rules.md) own authoring conventions;
[the lifecycle topic](../specs/runtime/lifecycle/spec.md) owns the runtime contract.

## Shared paths

| Consumer | Entry point | Target |
|---|---|---|
| Codex | `AGENTS.md` | Canonical project instructions, read natively |
| Claude Code | `CLAUDE.md` | `AGENTS.md` |
| Gemini | `GEMINI.md` | `AGENTS.md` |
| Zed | `.rules` | `AGENTS.md` (compatible project instructions) |
| Claude rules | `.claude/rules` | `../agents/rules` |
| Codex local skills | `.agents/skills` | `../agents/skills` |
| Reference-layout compatibility | `.codex/skills` | `../agents/skills` |
| Claude local skills | `.claude/skills` | `../agents/skills` |

Every alias is relative and resolves within this repository. `agents/skills/`
is a scaffold only: no executable skills are installed. The `.codex/skills`
alias retains the reference repository layout; modern Codex discovery uses
`.agents/skills`. Do not rely on the compatibility alias alone.

Codex discovers root/project `AGENTS.md` and local `.agents/skills` as documented
in [OpenAI's instruction guide](https://learn.chatgpt.com/docs/agent-configuration/agents-md)
and [skill guide](https://learn.chatgpt.com/docs/build-skills).
Zed recognizes the root `.rules` alias as described in its
[project instruction guide](https://zed.dev/docs/ai/instructions).
No `.zed/settings.json` is necessary for this instruction bootstrap. External
agents launched inside Zed use their own instruction discovery.

## Rules and validator

`documentation_spec.rules.md` routes spec authoring to the shared contract and
one rule per artifact (`documentation_spec_*.rules.md`).
`documentation_ontology.rules.md` owns the root `ontology/` map. Its format spec
lives at `specs/ontology/` because `specs/architecture/` is already a topic.
The rules use arc42, C4, requirement and verification IDs, known-gap fields,
and the ADR decision grammar.

The validator lives at `agents/scripts/validate_specs.dart`. It permits a
navigation-only `specs/spec.md` with `type: index`; canonical topics require
the full requirements/spec/log triad. Topics may live directly at
`specs/{domain}/`, with subdomains only when useful. Consolidation preserves IDs
through declared `legacy_id_prefixes`, which the validator checks for ownership.
The validator also enforces the ID anchor and ID link convention of
[the traceability rule](rules/documentation_spec_traceability.rules.md#id-anchors-and-links).

## Validate

```sh
dart run agents/scripts/validate_specs.dart --final
dart analyze agents/scripts/validate_specs.dart
dart run agents/scripts/check_vocabulary.dart --prose   # public API words against ontology/
```

Check links after moving shared directories. Local plans and agent memory are
ignored by Git; canonical rules, scripts, specs, and aliases are shareable.

## Fuzz evidence

`test_core.dart` retains lifecycle fuzz results automatically under
`output/fuzz/`, including runs selected through a package test directory.
Each invocation creates a distinct manifest, source provenance, event log,
coverage report, and failure report. CI uploads the directory after failures.
See the [artifact contract](../specs/verification/test/spec.md#fuzz-evidence-artifacts)
for the files and completion rules.

```sh
dart run agents/scripts/test_core.dart packages/fp_di/test/lifecycle_fuzz_test.dart
dart run agents/scripts/test_core.dart packages/fp_di_fpdart/test/lifecycle_fuzz_test.dart
```

## Benchmarks

Run the existing operation timing fixtures with a recorded sampling protocol:

```sh
dart run agents/scripts/benchmark.dart
dart run agents/scripts/benchmark.dart --samples 10
```

The default invocation runs five sequential samples in fresh VMs.
Each invocation retains its manifest, provenance, raw measurements, statistics,
and per-sample logs under `output/benchmarks/`.
See the [benchmark contract](../specs/verification/test/spec.md#benchmark-evidence-artifacts)
and [performance guide](../packages/fp_di/doc/perfomance.md).
