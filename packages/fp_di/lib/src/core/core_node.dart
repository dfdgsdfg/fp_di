// The rules that read one node: what it reads, what it waits for, and its
// phase. Each rule reads the views of `core_graph.dart` and changes nothing.
import '../model/key.dart';
import '../model/state.dart';
import 'core_graph.dart';

/// The contribution keys of [key] that [node] reads: the declared and
/// undisposed contributions to a set key, or the declared ids of a map key,
/// in the scope of [node] and its ancestors. Ancestors come first, then
/// declaration order; an id keeps the position of its first declaration.
///
/// The rule reads the declarations each time, so a contribution of a scope
/// that is not initialized counts, and a contribution that is disposed by
/// itself leaves. The own contribution of [node] does not count.
List<DiKeyBase> coreContributionKeysOf<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(CoreNode<S, P, N> node, DiCollectionKey<Object?> key) {
  final chain = <CoreScope<S, P, N>>[];
  for (
    CoreScope<S, P, N>? scope = node.scope;
    scope != null;
    scope = scope.parent
  ) {
    chain.add(scope);
  }
  final result = <DiKeyBase>[];
  final seen = <DiKeyBase>{};
  for (final scope in chain.reversed) {
    final components = scope.declared.components;
    for (var i = 0; i < components.length; i++) {
      final DiKeyBase? contribution = switch (key) {
        DiSetKey() =>
          components[i].contributesTo == key ? scope.contributionKeys[i] : null,
        DiMapKey() => switch (components[i].key) {
          final DiMapEntryKey<Object?> entry when entry.mapKey == key => entry,
          _ => null,
        },
      };
      if (contribution == null) continue;
      if (identical(scope, node.scope) && i == node.declarationIndex) continue;
      if (scope.initialized && scope.nodes[i].removed) continue;
      if (seen.add(contribution)) result.add(contribution);
    }
  }
  return result;
}

/// The contribution keys of the strict collection reads of [node].
Iterable<DiKeyBase> _strictContributionKeys<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(CoreNode<S, P, N> node) sync* {
  for (final key in node.collectionKeys) {
    yield* coreContributionKeysOf(node, key);
  }
}

/// Every key whose publisher identity [node] is bound to now: its plain
/// reads and the contribution keys of its collection reads.
Iterable<DiKeyBase> corePlainReads<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(CoreNode<S, P, N> node) sync* {
  yield* node.declaredPlainReads;
  for (final key in node.collectionKeys) {
    yield* coreContributionKeysOf(node, key);
  }
  for (final key in node.optionalCollectionKeys) {
    yield* coreContributionKeysOf(node, key);
  }
}

/// Whether every declared requirement of [node] resolves now, and every
/// contribution key of each of its strict collection reads.
bool coreSatisfied<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(CoreNode<S, P, N> node) =>
    node.declaredRequires.every((key) => node.resolve(key) != null) &&
    _strictContributionKeys(node).every((key) => node.resolve(key) != null);

/// For each strict collection read of [node] with a contribution key that
/// does not resolve now, the last such contribution key. Members activate in
/// declaration order when nothing else orders them, so the last key is the
/// one that resolves last.
Map<DiCollectionKey<Object?>, DiKeyBase> coreUnresolvedContributions<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(CoreNode<S, P, N> node) {
  if (node.collectionKeys.isEmpty) return const {};
  final result = <DiCollectionKey<Object?>, DiKeyBase>{};
  for (final key in node.collectionKeys) {
    final contributions = coreContributionKeysOf(node, key);
    for (var i = contributions.length - 1; i >= 0; i--) {
      if (node.resolve(contributions[i]) == null) {
        result[key] = contributions[i];
        break;
      }
    }
  }
  return result;
}

/// The keys that gate [node] and do not resolve now, in a stable order: its
/// required keys, then each strict collection key with a contribution key
/// that does not resolve.
List<DiKeyBase> coreUnmet<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(CoreNode<S, P, N> node) => [
  for (final key in node.declaredRequires)
    if (node.resolve(key) == null) key,
  ...coreUnresolvedContributions(node).keys,
];

/// Whether the target of [node] changed: a key that [node] is bound to
/// resolves to another publisher than at its committed activation, or a
/// collection has another membership.
bool coreTargetChanged<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(CoreNode<S, P, N> node) {
  for (final key in node.declaredPlainReads) {
    final next = node.resolve(key);
    if (!identical(next, node.committed[key])) return true;
  }
  for (final collection in node.collectionKeys.followedBy(
    node.optionalCollectionKeys,
  )) {
    final keys = coreContributionKeysOf(node, collection);
    final previous = node.committedMembership[collection];
    if (previous == null || !coreSameKeys(previous, keys)) return true;
    for (final key in keys) {
      final next = node.resolve(key);
      if (!identical(next, node.committed[key])) return true;
    }
  }
  return false;
}

/// Whether [a] and [b] hold equal keys in the same order.
bool coreSameKeys(List<DiKeyBase> a, List<DiKeyBase> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The phase of [node], computed from its fields.
///
/// `active` is before `activating`, because a listener runs at the commit,
/// before the activation leaves its flight. `inactive` is the word for a node
/// that is not active when no narrower word applies, such as a node whose
/// activation was canceled and that waits for a withdrawal or its removal.
NodePhase coreNodePhase<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(CoreNode<S, P, N> node) {
  if (node.removed) return NodePhase.disposed;
  if (node.active && !node.deactivating) return NodePhase.active;
  return coreIdlePhase(node, waits: coreUnmet(node).isNotEmpty);
}

/// The phase of a node that is neither disposed nor active. [waits] states
/// that a required key of the node does not resolve.
NodePhase coreIdlePhase<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(CoreNode<S, P, N> node, {required bool waits}) {
  if (node.deactivating) return NodePhase.deactivating;
  if (node.activationInFlight || node.doomed) return NodePhase.activating;
  if (node.reactivationBlocked) return NodePhase.disposeFailed;
  if (waits) return NodePhase.waiting;
  if (node.activationException != null) return NodePhase.activationFailed;
  return NodePhase.inactive;
}

/// The word of `Scope.describe` for [phase].
String coreStateWord(NodePhase phase) => switch (phase) {
  NodePhase.active => 'active',
  NodePhase.activating => 'activating',
  NodePhase.deactivating => 'deactivating',
  NodePhase.waiting => 'waiting',
  NodePhase.activationFailed => 'activation failed',
  NodePhase.disposeFailed => 'dispose failed',
  NodePhase.inactive => 'inactive',
  NodePhase.disposed => 'disposed',
};

/// The `NodeState` of [node], computed from its fields.
///
/// With [tracked], the missing collection keys are those of
/// `CoreNode.witnesses`, which the runtime has just written. Without it, the
/// rule reads every contribution key again, as the `StateCurrent` self-check
/// needs.
NodeState coreNodeState<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(CoreNode<S, P, N> node, {bool tracked = false}) {
  var missing = const <DiKeyBase>[];
  final NodePhase phase;
  if (node.removed) {
    phase = NodePhase.disposed;
  } else if (node.active && !node.deactivating) {
    phase = NodePhase.active;
  } else {
    missing = tracked
        ? [
            for (final key in node.declaredRequires)
              if (node.resolve(key) == null) key,
            for (final key in node.collectionKeys)
              if (node.witnesses.containsKey(key)) key,
          ]
        : coreUnmet(node);
    phase = coreIdlePhase(node, waits: missing.isNotEmpty);
  }
  return createNodeState(
    id: node.id,
    label: node.label,
    key: node.publicKey,
    phase: phase,
    missing: missing,
    activationException: phase == NodePhase.activationFailed
        ? node.activationException
        : null,
    commits: node.commits,
  );
}

/// The keys that `describe` lists as missing for [node], computed from its
/// fields. `describe` does not read the held state, so the two can be
/// compared.
List<DiKeyBase> coreMissingOf<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(CoreNode<S, P, N> node) =>
    !node.removed && (!node.active || node.deactivating)
    ? List<DiKeyBase>.unmodifiable(coreUnmet(node))
    : const <DiKeyBase>[];
