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
  if (component.isEffect && component.debugLabel == null) {
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
    required List<DiKey<Object?>> missing,
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

  /// The required keys that do not resolve, in the order of the declaration.
  ///
  /// The list is empty for an active node and for a disposed node.
  final List<DiKey<Object?>> missing;

  /// The failure of the last activation. The value is `Some` only in the
  /// phase [NodePhase.activationFailed].
  final Option<Cause<DiFailure>> activationFailure;

  /// The number of commits of the node.
  final int commits;

  @override
  bool operator ==(Object other) {
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

/// What an observer sees of one scope, at one revision.
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
      other is ScopeState &&
      other.phase == phase &&
      _same(other.nodeStates, nodeStates) &&
      _same(other.childStates, childStates);

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
    key: component.isEffect ? const None() : Some(component.key),
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
  for (var i = 0; i < record.nodes.length; i++) {
    final component = record.components[i];
    if (!component.isEffect && component.key == key) {
      final id = record.nodes[i];
      return nodeRecord(s, id).removed ? const None() : Some(id);
    }
  }
  return const None();
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
      (component) => !component.isEffect && component.key == key,
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
