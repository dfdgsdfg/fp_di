# Project Ontology

## Scope

Declared map of stable identifiers and typed, evidence-cited relations between
repositories, workspace packages, platforms, and domain concepts, with the words that public
identifiers use. One script reads these files: the vocabulary check. No CI reads them.

## Entry Points

| File | Owns |
|------|------|
| [domains.yml](domains.yml) | Domain IDs used by nodes; a registry, not a hierarchy |
| [workspace.yml](workspace.yml) | Workspace packages, their platforms, and their edges |
| [lifecycle.yml](lifecycle.yml) | Lifecycle domain concepts: preferred terms, short definitions, code symbols, identifier words, and edges |
| [vocabulary.yml](vocabulary.yml) | Words of public identifiers with an ordinary meaning from Dart, Flutter, fpdart, diagnostics, or package prefixes |
| [log.md](log.md) | Durable decisions that explain ontology changes |

## Local Checks

Run the vocabulary check after a change to a public identifier or to the ontology:
`dart run agents/scripts/check_vocabulary.dart --prose`. It needs `flutter pub get`.
`--list` prints the public API members. No validator checks the graph, so apply the
[manual review checklist](../agents/rules/documentation_ontology.rules.md#manual-review-checklist)
to every change. Validate the spec topic with
`dart run agents/scripts/validate_specs.dart specs/ontology --final`.

## References

- [Ontology authoring rule](../agents/rules/documentation_ontology.rules.md): ownership, routing, authoring, decisions
- [Ontology spec](../specs/ontology/spec.md): format, vocabulary, bindings, ID alignment
