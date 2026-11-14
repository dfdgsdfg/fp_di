import 'exception.dart';
import 'key.dart';

/// The place of a scope in its machine. `Scope.state` holds it.
///
/// The lookups of a scope answer until [disposeRequested] and throw
/// `DisposedScopeError` in [disposing] and [disposed]. `Scope.isDisposed` is
/// true in the last three phases.
///
/// {@category Observation}
enum ScopePhase {
  /// The scope has a module and no node. An `initialize` call can run.
  declared,

  /// The `initialize` mutation runs. The scope has one node for each declared
  /// component.
  initializing,

  /// `initialize` completed.
  initialized,

  /// The runtime accepted a `dispose` call for the scope or an ancestor. An
  /// `initialize` in flight ends in this phase, with its rollback or with
  /// success.
  disposeRequested,

  /// The disposal mutation releases the nodes.
  disposing,

  /// The disposal ended.
  disposed,
}

/// The place of a node in its machine. `Scope.describe` names the same
/// phases.
///
/// {@category Observation}
enum NodePhase {
  /// A required key does not resolve. [NodeState.missing] lists the keys.
  waiting,

  /// The node is not active for another reason, such as a canceled
  /// activation.
  inactive,

  /// An activation of the node runs, or its rollback. A member of a running
  /// `initialize` whose activation failed, or whose activation a disposal
  /// request canceled, keeps the phase until the rollback of that call
  /// disposes it.
  activating,

  /// The node has a value, and its keys resolve to it.
  active,

  /// The release of a committed activation runs. The keys of the node do
  /// not resolve to it, and the node gives no value.
  deactivating,

  /// The last automatic activation failed. `Scope.errors` reported the
  /// failure, [NodeState.activationException] holds it, and a later change
  /// can activate the node.
  activationFailed,

  /// A `dispose` of the last activation failed, so the node does not activate
  /// again.
  disposeFailed,

  /// The node is disposed.
  disposed,
}

/// The state of one node, as an immutable value.
///
/// Two values with equal members are equal. Two values with the same [id]
/// and the same [commits] state the same published value.
///
/// {@category Observation}
final class NodeState {
  NodeState._({
    required this.id,
    required this.label,
    required this.key,
    required this.phase,
    required this.missing,
    required this.activationException,
    required this.commits,
  });

  /// The number of the node. No other node of the root has it.
  final int id;

  /// The label of the node, which `Scope.describe` and the errors use.
  final String label;

  /// The published key, or null for a node without one.
  final DiKeyBase? key;

  /// The [NodePhase] of the node in this state.
  final NodePhase phase;

  /// The required keys that do not resolve in this state. Empty in the phases
  /// [NodePhase.active] and [NodePhase.disposed].
  final List<DiKeyBase> missing;

  /// The failure of the last activation in the phase
  /// [NodePhase.activationFailed], otherwise null.
  final ActivationException? activationException;

  /// The number of activations that the node committed.
  final int commits;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NodeState &&
          other.id == id &&
          other.label == label &&
          other.key == key &&
          other.phase == phase &&
          other.commits == commits &&
          identical(other.activationException, activationException) &&
          _equalLists(other.missing, missing);

  @override
  int get hashCode => Object.hash(
    id,
    label,
    key,
    phase,
    commits,
    identityHashCode(activationException),
    Object.hashAll(missing),
  );

  @override
  String toString() =>
      'NodeState($label#$id, ${phase.name}, commits: $commits'
      '${missing.isEmpty ? '' : ', missing: ${missing.join(', ')}'})';
}

/// The state of one scope and its descendants, as an immutable value.
///
/// The value is a tree: it holds the scope and each descendant that is not
/// disposed, and no ancestor. Two values with an equal phase, equal nodes,
/// and equal children are equal. The runtime keeps the object of a scope
/// that a transition does not change, so `identical` tells that nothing in
/// the scope and its descendants changed.
///
/// {@category Observation}
final class ScopeState {
  ScopeState._({
    required this.phase,
    required this.nodeStates,
    required this.childStates,
  });

  /// The [ScopePhase] of the scope in this state.
  final ScopePhase phase;

  /// One [NodeState] for each node of the scope, in declaration order. The
  /// state at a position belongs to the component at that position of the
  /// module. Empty in the phase [ScopePhase.declared].
  final List<NodeState> nodeStates;

  /// The state of each child scope that is not disposed, in creation order.
  final List<ScopeState> childStates;

  /// The nodes of this value and its descendants whose state differs from
  /// their state in [earlier], an earlier value of the same scope.
  ///
  /// Each pair holds the earlier and the later state of one node. A created
  /// node has no earlier state. A node that this value does not hold, after
  /// a failed `initialize` or the disposal of its scope, has no later state.
  /// The pairs of this value come first, in the order of the tree.
  List<(NodeState?, NodeState?)> changedSince(ScopeState earlier) {
    if (identical(this, earlier)) return const [];
    // A scope object that both trees hold did not change, so neither walk
    // enters it.
    final earlierScopes = Set<ScopeState>.identity();
    void collect(ScopeState scope) {
      earlierScopes.add(scope);
      scope.childStates.forEach(collect);
    }

    collect(earlier);
    final kept = Set<ScopeState>.identity();
    final later = <int, NodeState>{};
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
    final before = <int, NodeState>{};
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
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScopeState &&
          other.phase == phase &&
          _equalLists(other.nodeStates, nodeStates) &&
          _equalLists(other.childStates, childStates);

  @override
  int get hashCode => Object.hash(
    phase,
    Object.hashAll(nodeStates),
    Object.hashAll(childStates),
  );

  @override
  String toString() =>
      'ScopeState(${phase.name}, nodeStates: ${nodeStates.length}, '
      'childStates: ${childStates.length})';
}

bool _equalLists<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Creates a [NodeState]. Only the runtime calls it.
NodeState createNodeState({
  required int id,
  required String label,
  required DiKeyBase? key,
  required NodePhase phase,
  required List<DiKeyBase> missing,
  required ActivationException? activationException,
  required int commits,
}) => NodeState._(
  id: id,
  label: label,
  key: key,
  phase: phase,
  missing: missing.isEmpty ? const [] : List<DiKeyBase>.unmodifiable(missing),
  activationException: activationException,
  commits: commits,
);

/// Creates a [ScopeState]. Only the runtime calls it.
ScopeState createScopeState({
  required ScopePhase phase,
  required List<NodeState> nodeStates,
  required List<ScopeState> childStates,
}) => ScopeState._(
  phase: phase,
  nodeStates: nodeStates.isEmpty
      ? const []
      : List<NodeState>.unmodifiable(nodeStates),
  childStates: childStates.isEmpty
      ? const []
      : List<ScopeState>.unmodifiable(childStates),
);
