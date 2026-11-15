// Internal types. The library file does not export this file.
import 'package:fpdart/fpdart.dart';

import '../cause.dart';
import '../failure.dart';
import '../key.dart';
import 'ids.dart';
import 'phases.dart';
import 'queries.dart';
import 'runtime_state.dart';

/// The label of the node [n]: the debug label of its component, or the key of
/// the component. An effect without a debug label has the id in its label.
String labelOf(RuntimeState s, NodeId n) {
  final component = componentOf(s, nodeRecord(s, n));
  if (!component.hasKey && component.debugLabel == null) {
    return '${component.label}#${n.value}';
  }
  return component.label;
}

/// What an observer sees of one node, at one revision.
final class NodeState {
  /// Creates the state of a node.
  NodeState({
    required this.id,
    required this.label,
    required this.key,
    required this.phase,
    required List<DiKeyBase> missing,
    required this.activationFailure,
    required this.commits,
  }) : missing = List.unmodifiable(missing);

  /// The id of the node. It grows with the creation of the nodes.
  final NodeId id;

  /// The name of the node in a message.
  final String label;

  /// The key that the node publishes, or `None` for an effect.
  final Option<DiKey<Object?>> key;

  /// The phase of the node.
  final NodePhase phase;

  /// The keys that the node waits for: the required keys that do not resolve,
  /// in the order of the declaration, and then each strict collection key that
  /// has a contribution that does not resolve.
  ///
  /// The list is empty for an active node and for a disposed node.
  final List<DiKeyBase> missing;

  /// The failure of the last activation. The value is `Some` only in the
  /// phase [NodePhase.activationFailed].
  final Option<Cause<DiFailure>> activationFailure;

  /// The number of commits of the node.
  final int commits;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! NodeState) return false;
    if (other.id != id ||
        other.label != label ||
        other.key != key ||
        other.phase != phase ||
        other.commits != commits ||
        !identical(
          other.activationFailure.toNullable(),
          activationFailure.toNullable(),
        ) ||
        other.missing.length != missing.length) {
      return false;
    }
    for (var i = 0; i < missing.length; i++) {
      if (other.missing[i] != missing[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(id.value, label, phase, commits, Object.hashAll(missing));

  @override
  String toString() =>
      'NodeState($label: ${phase.name}'
      '${missing.isEmpty ? '' : ', missing ${missing.join(', ')}'})';
}

/// What an observer sees of one scope and its descendants, at one revision.
///
/// The value is a tree: it holds the scope and each descendant that is not
/// disposed, and no ancestor. Two values with an equal phase, equal nodes, and
/// equal children are equal. The runtime keeps the object of a scope that a
/// transition does not change, so `identical` tells that nothing in the scope
/// and its descendants changed.
final class ScopeState {
  /// Creates the state of a scope.
  ScopeState({
    required this.phase,
    required List<NodeState> nodeStates,
    required List<ScopeState> childStates,
  }) : nodeStates = List.unmodifiable(nodeStates),
       childStates = List.unmodifiable(childStates);

  /// The phase of the scope.
  final ScopePhase phase;

  /// The states of the nodes in declaration order. The list is empty until
  /// an initialization creates the nodes.
  final List<NodeState> nodeStates;

  /// The states of the children that are not disposed, in creation order.
  final List<ScopeState> childStates;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScopeState &&
          other.phase == phase &&
          _same(other.nodeStates, nodeStates) &&
          _same(other.childStates, childStates);

  /// The nodes of this value and its descendants whose state differs from
  /// their state in [earlier], an earlier value of the same scope.
  ///
  /// Each pair holds the earlier and the later state of one node. A created
  /// node has no earlier state. A node that this value does not hold, after a
  /// failed run or the disposal of its scope, has no later state. The pairs of
  /// this value come first, in the order of the tree. Then come the pairs of
  /// the nodes that only [earlier] holds.
  ///
  /// A scope object that both trees hold did not change, so the walk does not
  /// enter it.
  List<(NodeState?, NodeState?)> changedSince(ScopeState earlier) {
    if (identical(this, earlier)) return const [];
    final earlierScopes = Set<ScopeState>.identity();
    void collect(ScopeState scope) {
      earlierScopes.add(scope);
      scope.childStates.forEach(collect);
    }

    collect(earlier);
    final kept = Set<ScopeState>.identity();
    final later = <NodeId, NodeState>{};
    void walkLater(ScopeState scope) {
      if (earlierScopes.contains(scope)) {
        kept.add(scope);
        return;
      }
      for (final node in scope.nodeStates) {
        later[node.id] = node;
      }
      scope.childStates.forEach(walkLater);
    }

    walkLater(this);
    final before = <NodeId, NodeState>{};
    void walkEarlier(ScopeState scope) {
      if (kept.contains(scope)) return;
      for (final node in scope.nodeStates) {
        before[node.id] = node;
      }
      scope.childStates.forEach(walkEarlier);
    }

    walkEarlier(earlier);
    return [
      for (final node in later.values)
        if (before[node.id] != node) (before[node.id], node),
      for (final node in before.values)
        if (!later.containsKey(node.id)) (node, null),
    ];
  }

  @override
  int get hashCode => Object.hash(
    phase,
    Object.hashAll(nodeStates),
    Object.hashAll(childStates),
  );

  @override
  String toString() =>
      'ScopeState(${phase.name}, '
      '${nodeStates.length} nodes, ${childStates.length} children)';
}

bool _same<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The state of the node [n] in [s].
NodeState nodeState(RuntimeState s, NodeId n) {
  final node = nodeRecord(s, n);
  final component = componentOf(s, node);
  final phase = nodePhase(s, n);
  final settled = phase == NodePhase.active || phase == NodePhase.disposed;
  return NodeState(
    id: n,
    label: labelOf(s, n),
    key: component.hasKey ? Some(component.key) : const None(),
    phase: phase,
    missing: settled ? const [] : unmet(s, n),
    activationFailure: phase == NodePhase.activationFailed
        ? node.activationFailure
        : const None(),
    commits: node.commits,
  );
}

/// The state of the scope [id] in [s], with the states of its nodes and of
/// its children.
ScopeState scopeState(RuntimeState s, ScopeId id) {
  final scope = scopeRecord(s, id);
  return ScopeState(
    phase: scopePhase(s, id),
    nodeStates: [for (final n in scope.nodes) nodeState(s, n)],
    childStates: [for (final child in scope.children) scopeState(s, child)],
  );
}

/// The node of the scope [scope] whose component publishes [key], or `None`
/// when the scope has no such node or the runtime removed the node.
///
/// A scope has nodes from the start of its initialization.
Option<NodeId> nodeForKey(RuntimeState s, ScopeId scope, DiKey<Object?> key) {
  final record = scopeRecord(s, scope);
  final index = record.keyIndex[key];
  if (index == null || record.nodes.isEmpty) return const None();
  final id = record.nodes[index];
  return nodeRecord(s, id).removed ? const None() : Some(id);
}

/// Whether a scope from [from] to the root can still publish [key].
///
/// A scope can publish when its disposal was not requested, when it declares
/// the key, and when it has no node yet, is initializing, or has a node for
/// the key that is not blocked.
bool canPublish(RuntimeState s, ScopeId from, DiKey<Object?> key) {
  ScopeId? at = from;
  while (at != null) {
    final scope = scopeRecord(s, at);
    final declared = scope.components.any(
      (component) => component.hasKey && component.key == key,
    );
    if (!disposalRequested(s, at) && declared) {
      if (scope.initializing || scope.nodes.isEmpty) return true;
      final node = nodeForKey(s, at, key);
      if (node.toNullable() case final id?
          when nodePhase(s, id) != NodePhase.disposeFailed) {
        return true;
      }
    }
    at = scope.parent.toNullable();
  }
  return false;
}

/// The nodes on a path of committed reads from [from] to [target], both
/// included, or `null` when no path exists.
List<NodeId>? readsPath(RuntimeState s, NodeId from, NodeId target) {
  final seen = <NodeId>{};
  List<NodeId>? visit(NodeId at) {
    if (!seen.add(at)) return null;
    if (at == target) return [at];
    for (final dependency in nodeRecord(s, at).dependencies) {
      final suffix = visit(dependency);
      if (suffix != null) return [at, ...suffix];
    }
    return null;
  }

  return visit(from);
}

// ---- Sharing.

/// The snapshots that the runtime built before, so that a new snapshot can keep
/// the object of what did not change.
///
/// The value is immutable. [scopeStateShared] takes one and gives the next
/// one. The shell keeps the current one in a cell. A read at the revision that
/// the memo knows gives the same object. A read at a later revision builds the
/// scopes again, and keeps the earlier object of each node state that is equal
/// and of each scope state whose parts are the same objects.
final class Snapshots {
  const Snapshots._(this._nodes, this._scopes);

  /// A memo without a snapshot.
  static const Snapshots empty = Snapshots._({}, {});

  final Map<NodeId, NodeState> _nodes;
  final Map<ScopeId, ({int revision, ScopeState state})> _scopes;
}

bool _sameObjects<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!identical(a[i], b[i])) return false;
  }
  return true;
}

/// The state of the scope [id] in [s], and the memo for the next read.
///
/// The state shares objects with the states that [memo] holds: an unchanged
/// node keeps its `NodeState`, and a scope whose phase, nodes, and children
/// are unchanged keeps its `ScopeState`. Two reads at one revision give the
/// same object.
(ScopeState, Snapshots) scopeStateShared(
  RuntimeState s,
  ScopeId id,
  Snapshots memo,
) {
  final known = memo._scopes[id];
  if (known != null && known.revision == s.revision) return (known.state, memo);
  final nodes = {...memo._nodes};
  final scopes = {...memo._scopes};
  ScopeState build(ScopeId at) {
    final cached = scopes[at];
    if (cached != null && cached.revision == s.revision) return cached.state;
    final record = scopeRecord(s, at);
    final children = [for (final child in record.children) build(child)];
    final nodeStates = <NodeState>[];
    for (final n in record.nodes) {
      final fresh = nodeState(s, n);
      final previous = nodes[n];
      final kept = previous != null && previous == fresh ? previous : fresh;
      nodes[n] = kept;
      nodeStates.add(kept);
    }
    final phase = scopePhase(s, at);
    final previous = cached?.state;
    final state =
        previous != null &&
            previous.phase == phase &&
            _sameObjects(previous.nodeStates, nodeStates) &&
            _sameObjects(previous.childStates, children)
        ? previous
        : ScopeState(
            phase: phase,
            nodeStates: nodeStates,
            childStates: children,
          );
    scopes[at] = (revision: s.revision, state: state);
    return state;
  }

  final state = build(id);
  return (state, Snapshots._(nodes, scopes));
}

/// The state of the node [n] in [s], and the memo for the next read.
///
/// The object is the one that `scopeStateShared` gives for the scope of the
/// node, when the scope lists the node.
(NodeState, Snapshots) nodeStateShared(
  RuntimeState s,
  NodeId n,
  Snapshots memo,
) {
  final node = nodeRecord(s, n);
  final (_, next) = scopeStateShared(s, node.scope, memo);
  // A scope that rolled back its run lists no node. The state of such a node
  // is not part of a scope state, so it is not shared.
  final nodes = scopeRecord(s, node.scope).nodes;
  final listed = node.index < nodes.length && nodes[node.index] == n;
  return (listed ? next._nodes[n]! : nodeState(s, n), next);
}

// ---- The cause of an unavailable key.

/// The word that `describe` uses for [phase].
String stateWord(NodePhase phase) => switch (phase) {
  NodePhase.active => 'active',
  NodePhase.activating => 'activating',
  NodePhase.deactivating => 'deactivating',
  NodePhase.waiting => 'waiting',
  NodePhase.activationFailed => 'activation failed',
  NodePhase.disposeFailed => 'dispose failed',
  NodePhase.inactive => 'inactive',
  NodePhase.disposed => 'disposed',
};

String _causeText(Cause<DiFailure> cause) {
  final first = cause.failures.firstOrNull;
  return switch (first) {
    ActivationFailure(:final error) => '$error',
    final DiFailure failure => failure.message,
    null => cause.prettyPrint().replaceAll('\n', ' '),
  };
}

/// The nearest node of [key], from the scope of [reader] to the root, other
/// than [reader] itself, or `null` when no scope has a node for the key.
///
/// The node can wait, fail, or be disposed: it is the node that the search for
/// the cause of an unavailable key follows.
NodeId? nodeBehind(RuntimeState s, NodeId reader, DiKey<Object?> key) {
  for (
    ScopeId? at = nodeRecord(s, reader).scope;
    at != null;
    at = scopeRecord(s, at).parent.toNullable()
  ) {
    final node = nodeForKey(s, at, key).toNullable();
    if (node != null && node != reader) return node;
  }
  return null;
}

/// The failure of a `get` of [key] from the scope [scope], when the key has no
/// value.
///
/// The search starts at the node that `findNode` returns. A failed node ends
/// its path. A waiting node continues at the nodes of its missing keys: the
/// nearest node of a required key, other than the waiting node itself. The
/// search is depth-first, visits each node one time, and changes nothing.
UnavailableKeyFailure unavailableKey(
  RuntimeState s,
  ScopeId scope,
  DiKey<Object?> key,
) {
  NodeId? first;
  var declaredOnly = false;
  for (
    ScopeId? at = scope;
    at != null;
    at = scopeRecord(s, at).parent.toNullable()
  ) {
    first = nodeForKey(s, at, key).toNullable();
    if (first != null) break;
    declaredOnly |=
        scopePhase(s, at) == ScopePhase.declared &&
        scopeRecord(s, at).keyIndex.containsKey(key);
  }
  if (first == null) {
    return UnavailableKeyFailure(
      key,
      message: declaredOnly
          ? 'No node publishes $key: a scope declares the key and is not '
                'initialized.'
          : 'No node publishes $key.',
    );
  }

  final failed = <NodeState>[];
  final seen = <NodeId>{};
  final pending = <NodeId>[first];
  while (pending.isNotEmpty) {
    final node = pending.removeLast();
    if (!seen.add(node)) continue;
    final state = nodeState(s, node);
    if (state.phase == NodePhase.activationFailed) {
      failed.add(state);
      continue;
    }
    if (state.phase != NodePhase.waiting) continue;
    final next = <NodeId>[];
    for (final missing in state.missing) {
      if (missing is DiCollectionKey<Object?>) {
        // Each contribution of the collection that does not resolve.
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
    // The last node of the stack is the next one, so the first node behind
    // this node goes on last.
    pending.addAll(next.reversed);
  }

  final state = nodeState(s, first);
  final buffer = StringBuffer('No value is available for $key');
  switch (state.phase) {
    case NodePhase.waiting:
      buffer.write(
        ': the node ${state.label} waits for ${state.missing.join(', ')}.',
      );
    case NodePhase.activationFailed:
      buffer.write('.');
    case final phase:
      buffer.write(': the node ${state.label} is ${stateWord(phase)}.');
  }
  if (failed.isNotEmpty) {
    final cause = failed.first;
    buffer.write(' The activation of ${cause.label} failed');
    if (failed.length > 1) {
      buffer.write(', and ${failed.length - 1} more failed');
    }
    final text = cause.activationFailure.map(_causeText).getOrElse(() => '');
    buffer.write(': $text');
  }
  return UnavailableKeyFailure(
    key,
    message: buffer.toString(),
    failedNodeStates: failed,
  );
}
