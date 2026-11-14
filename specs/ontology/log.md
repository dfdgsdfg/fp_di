---
type: log
title: "Ontology Format Decision Log"
description: "Accepted decisions that change the ontology's format, vocabulary, or ownership boundaries."
tags: [ontology, log]
---

# Ontology Format Decision Log

Append accepted decisions only. Newest at the bottom.

## [2026-11-03] decision | Add a concept kind for domain terms

- Context: The lifecycle spec kept the only glossary. The glossary covered one topic, named no Dart symbols, and mixed definitions with ordering and failure policy. The format had no kind for a term.
- Decision: Add the `concept` node kind, an optional node `term`, the relation types `specializes`, `part_of`, `belongs_to`, and `acts_on` between concepts, and an optional `symbol` on `file` bindings. A concept definition states identity only. The kind is local; no alignment with the sibling `entity` or `activity` kinds is claimed.
- Consequences: Shared terms have one owner outside any single topic, and a symbol links each term to code. The format gains four relation types and two optional fields that only manual review checks. A single kind keeps the vocabulary small; an entity/activity split was not adopted because no relation needs that source-kind constraint.
- References: [format spec](spec.md#node-kinds), V-A-ONT-FMT-004.

## [2026-11-10] decision | Check the words of the public API against the ontology

- Context: A rename left old words in other packages, and the public API came to use two words for one concept. The ontology defined terms but named only a few symbols, and its manual review could not read about 440 public names.
- Decision: Nodes gain optional `identifiers` and `avoid` word lists, and a `vocabulary` kind holds words with an ordinary meaning from one source. `agents/scripts/check_vocabulary.dart` derives the public API from the code and fails on a word that no node lists, an avoided word, a conflict, or a stale symbol or path. The ontology still keeps no list of members.
- Consequences: A new public word needs an ontology edit in the same change, and a reviewer sees the vocabulary in one place. The script adds `analyzer` and `yaml` as root dev dependencies. It cannot tell whether a word sits under the right node, so review still owns meaning. Ordinary English words make poor `avoid` entries, because the prose scan cannot tell their senses apart.
- Supersedes: [Add a concept kind for domain terms](#2026-11-03-decision--add-a-concept-kind-for-domain-terms), only by adding fields and a kind.
- References: [format spec](spec.md#vocabulary), V-L-ONT-FMT-002.
