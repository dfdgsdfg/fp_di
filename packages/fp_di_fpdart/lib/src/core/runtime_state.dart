// Internal types. The library file does not export this file.
import 'ids.dart';
import 'records.dart';

/// A pending withdrawal: the node that a caller disposes, and the nodes that
/// its release deactivates with it.
///
/// The runtime takes the [reach] when it accepts the request and keeps it
/// until the withdrawal finishes. A later recomputation can differ, because a
/// node stops being active when its release starts.
final class Withdrawal {
  /// Creates the withdrawal of [root] with the nodes of [reach].
  Withdrawal(this.root, Set<NodeId> reach) : reach = Set.unmodifiable(reach);

  /// The node whose disposal the withdrawal serves.
  final NodeId root;

  /// The root and the transitive active dependents of the root, as of the
  /// request.
  final Set<NodeId> reach;
}

/// The immutable state of one runtime: every scope, every node, the pending
/// withdrawals, and the counters.
///
/// Every query is a pure function of the state, and every transition returns
/// a new state.
final class RuntimeState {
  /// Creates a state.
  RuntimeState({
    Map<ScopeId, ScopeRecord> scopes = const {},
    Map<NodeId, NodeRecord> nodes = const {},
    List<Withdrawal> withdrawals = const [],
    this.revision = 0,
    this.nextNodeId = 0,
    this.nextScopeId = 0,
    this.nextTicket = 0,
  }) : scopes = Map.unmodifiable(scopes),
       nodes = Map.unmodifiable(nodes),
       withdrawals = List.unmodifiable(withdrawals);

  /// The state of a runtime that has no scope.
  static final RuntimeState empty = RuntimeState();

  /// Every scope that the runtime created. A disposed scope stays here, so
  /// its phase still answers.
  final Map<ScopeId, ScopeRecord> scopes;

  /// Every node that the runtime created. A removed node stays here until a
  /// rollback of its scope drops it.
  final Map<NodeId, NodeRecord> nodes;

  /// The pending withdrawals, oldest first.
  final List<Withdrawal> withdrawals;

  /// The number of observable changes. An observer that reads the same
  /// revision twice reads the same state.
  final int revision;

  /// The id of the next node.
  final int nextNodeId;

  /// The id of the next scope.
  final int nextScopeId;

  /// The number of the next activation ticket.
  final int nextTicket;

  /// A state with the given fields replaced.
  RuntimeState copyWith({
    Map<ScopeId, ScopeRecord>? scopes,
    Map<NodeId, NodeRecord>? nodes,
    List<Withdrawal>? withdrawals,
    int? revision,
    int? nextNodeId,
    int? nextScopeId,
    int? nextTicket,
  }) => RuntimeState(
    scopes: scopes ?? this.scopes,
    nodes: nodes ?? this.nodes,
    withdrawals: withdrawals ?? this.withdrawals,
    revision: revision ?? this.revision,
    nextNodeId: nextNodeId ?? this.nextNodeId,
    nextScopeId: nextScopeId ?? this.nextScopeId,
    nextTicket: nextTicket ?? this.nextTicket,
  );
}
