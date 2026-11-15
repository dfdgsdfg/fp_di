// Internal functions. The library file does not export this file.
//
// The queries of the inspector: what a tool shows of one node. Each function
// reads a state and gives plain values, so the shell only has to encode them.
import 'package:fpdart/fpdart.dart';

import '../cause.dart';
import '../failure.dart';
import '../key.dart';
import 'ids.dart';
import 'phases.dart';
import 'queries.dart';
import 'runtime_state.dart';
import 'snapshots.dart';

/// The longest text that an answer or an event holds, in UTF-16 code units.
const int inspectorTextBound = 4096;

/// The text that stands for a value whose `toString` threw.
const String inspectorToStringThrew = '<toString threw>';

/// [text] cut at the bound, and whether it was cut. A cut does not split a
/// surrogate pair.
(String, bool) cutText(String text) {
  if (text.length <= inspectorTextBound) return (text, false);
  var end = inspectorTextBound;
  final last = text.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return (text.substring(0, end), true);
}

/// The text of [value], cut at the bound. A `toString` that throws gives the
/// placeholder. The flag tells that the text was cut.
(String, bool) textOf(Object? value) {
  final String text;
  try {
    text = '$value';
  } on Object {
    return (inspectorToStringThrew, false);
  }
  return cutText(text);
}

/// The error of a failure cause that a tool shows: the error that a step threw
/// or the value that it returned, or the failure itself.
///
/// The cause gives `None` when it holds neither a typed failure nor a defect.
Option<Object> shownError(Cause<DiFailure> cause) {
  final failure = cause.failures.firstOrNull;
  if (failure != null) {
    return Some(
      failure is ActivationFailure ? (failure.error ?? failure) : failure,
    );
  }
  final defect = cause.defects.firstOrNull;
  return defect == null ? const None() : Some(defect);
}

/// The first stack trace of a cause, or `None` for an empty cause.
Option<StackTrace> firstStackTrace(Cause<DiFailure> cause) =>
    Option.fromNullable(
      cause.fold<StackTrace?>(
        empty: () => null,
        fail: (_, stackTrace) => stackTrace,
        die: (_, stackTrace) => stackTrace,
        interrupt: (stackTrace) => stackTrace,
        then: (first, second) => first ?? second,
        both: (left, right) => left ?? right,
      ),
    );

/// The type and the message of the failure of an activation, cut at the bound,
/// and whether the message was cut.
({String type, String message, bool cut}) failureSummary(
  Cause<DiFailure> cause,
) {
  final error = shownError(cause);
  final shown = error.toNullable();
  final (message, cut) = shown == null
      ? cutText(cause.prettyPrint())
      : textOf(shown);
  return (
    type: shown == null ? 'Cause' : '${shown.runtimeType}',
    message: message,
    cut: cut,
  );
}

/// The reads of the node [n]: each key, its kind, whether it resolves, and the
/// node that gives the value.
///
/// For a key without a value, the publisher is the nearest node that publishes
/// the key, which the search for the cause follows. A collection read has no
/// one publisher, so its entry has a `null` publisher and lists its members.
List<Map<String, Object?>> nodeReads(RuntimeState s, NodeId n) {
  final node = nodeRecord(s, n);
  final component = componentOf(s, node);

  Map<String, Object?> read(DiKeyBase key, String kind) {
    final publisher = key is DiKey<Object?>
        ? resolve(s, node.scope, key, exclude: Some(n))
        : const None();
    final behind = key is DiKey<Object?> ? nodeBehind(s, n, key) : null;
    return <String, Object?>{
      'key': '$key',
      'kind': kind,
      'resolves': publisher.isSome(),
      'publisher':
          publisher.map((p) => p.node.value).toNullable() ?? behind?.value,
    };
  }

  Map<String, Object?> collection(DiCollectionKey<Object?> key, String kind) {
    final members = [
      for (final member in contributionKeysOf(s, n, key))
        read(member, 'member'),
    ];
    return <String, Object?>{
      'key': '$key',
      'kind': kind,
      'resolves': members.every((member) => member['resolves'] == true),
      'publisher': null,
      'members': members,
    };
  }

  return [
    for (final key in component.requires) read(key, 'require'),
    for (final key in component.optional)
      if (!component.requires.contains(key)) read(key, 'optional'),
    for (final key in component.collectionKeys) collection(key, 'collection'),
    for (final key in component.optionalCollectionKeys)
      collection(key, 'optionalCollection'),
  ];
}

/// The ids of the nodes whose committed reads include a value of [n], in
/// ascending order.
List<int> nodeReaders(RuntimeState s, NodeId n) {
  final ids = <int>{
    for (final other in s.nodes.values)
      if (!other.removed && other.id != n && other.dependencies.contains(n))
        other.id.value,
  };
  return ids.toList()..sort();
}

/// The search for the cause of an unavailable key, as steps, or `null` when
/// the node [first] publishes no key or is active.
///
/// The steps visit the nodes in the order of the search that `get` runs. The
/// search changes nothing.
List<Map<String, Object?>>? causeSteps(RuntimeState s, NodeId first) {
  final firstRecord = nodeRecord(s, first);
  if (!componentOf(s, firstRecord).hasKey ||
      nodeState(s, first).phase == NodePhase.active) {
    return null;
  }
  final steps = <Map<String, Object?>>[];
  final seen = <NodeId>{};
  final pending = <NodeId>[first];
  while (pending.isNotEmpty) {
    final node = pending.removeLast();
    if (!seen.add(node)) continue;
    final state = nodeState(s, node);
    steps.add(<String, Object?>{
      'node': node.value,
      'phase': state.phase.name,
      'waitsFor': [for (final key in state.missing) '$key'],
    });
    if (state.phase != NodePhase.waiting) continue;
    final next = <NodeId>[];
    for (final missing in state.missing) {
      if (missing is DiCollectionKey<Object?>) {
        for (final contribution in contributionKeysOf(s, node, missing)) {
          final scope = nodeRecord(s, node).scope;
          if (resolve(s, scope, contribution, exclude: Some(node)).isNone()) {
            final found = nodeBehind(s, node, contribution);
            if (found != null) next.add(found);
          }
        }
      } else if (missing is DiKey<Object?>) {
        final found = nodeBehind(s, node, missing);
        if (found != null) next.add(found);
      }
    }
    pending.addAll(next.reversed);
  }
  return steps;
}

/// The state of the node [n] as the inspector shows it, without the value.
Map<String, Object?> nodeFields(NodeState state) => <String, Object?>{
  'id': state.id.value,
  'label': state.label,
  'key': state.key.map((key) => key.toString()).toNullable(),
  'phase': state.phase.name,
  'missing': [for (final key in state.missing) '$key'],
  'failure': state.activationFailure.map((cause) {
    final summary = failureSummary(cause);
    return <String, Object?>{
      'type': summary.type,
      'message': summary.message,
      if (summary.cut) 'truncated': true,
    };
  }).toNullable(),
  'commits': state.commits,
};

/// The value of the node [n] as text, and `truncated` when the text is cut. A
/// node that is not active has no value.
Map<String, Object?> valueFields(RuntimeState s, NodeId n) {
  final node = nodeRecord(s, n);
  if (node.removed || nodePhase(s, n) != NodePhase.active) {
    return const <String, Object?>{'value': null};
  }
  final (text, cut) = textOf(node.value.toNullable());
  return <String, Object?>{'value': text, if (cut) 'truncated': true};
}

/// The failure of the node [n] in a `node` answer: the cause text and the
/// stack trace, cut at the bound, or `null`.
Map<String, Object?>? failureDetails(RuntimeState s, NodeId n) {
  final failure = nodeRecord(s, n).activationFailure.toNullable();
  if (failure == null) return null;
  final shown = shownError(failure).toNullable();
  final (cause, causeCut) = shown == null
      ? cutText(failure.prettyPrint())
      : textOf(shown);
  final trace = firstStackTrace(failure).toNullable();
  final (stack, stackCut) = trace == null ? ('', false) : textOf(trace);
  return <String, Object?>{
    'cause': cause,
    'stackTrace': stack,
    if (causeCut || stackCut) 'truncated': true,
  };
}
