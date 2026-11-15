// Internal types. The library file does not export this file.
import '../key.dart';
import 'ids.dart';
import 'persistent_map.dart';
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
///
/// The scopes and the nodes are persistent maps, so a transition that changes
/// one record shares the rest of the maps with the earlier state and costs a
/// time that is logarithmic in their size. The state keeps an index from each
/// node to the nodes that read it, so the readers of a node are a lookup and
/// not a scan. [withNode] keeps the index in step with the records.
final class RuntimeState {
  /// Creates a state.
  ///
  /// The constructor builds the index of the readers from the dependencies of
  /// [nodes]. Its time is linear, so a transition uses [withNode] instead.
  RuntimeState({
    Map<ScopeId, ScopeRecord> scopes = const {},
    Map<NodeId, NodeRecord> nodes = const {},
    List<Withdrawal> withdrawals = const [],
    this.revision = 0,
    this.nextNodeId = 0,
    this.nextScopeId = 0,
    this.nextTicket = 0,
  }) : scopes = PMap.from(scopes),
       nodes = PMap.from(nodes),
       readers = _readersOf(PMap.from(nodes)),
       keyReaders = _keyReadersOf(PMap.from(scopes), PMap.from(nodes)),
       withdrawals = List.unmodifiable(withdrawals);

  RuntimeState._({
    required this.scopes,
    required this.nodes,
    required this.readers,
    required this.keyReaders,
    required this.withdrawals,
    required this.revision,
    required this.nextNodeId,
    required this.nextScopeId,
    required this.nextTicket,
  });

  /// The state of a runtime that has no scope.
  static final RuntimeState empty = RuntimeState();

  /// Every scope that the runtime created. A disposed scope stays here, so
  /// its phase still answers.
  final PMap<ScopeId, ScopeRecord> scopes;

  /// Every node that the runtime created. A removed node stays here until a
  /// rollback of its scope drops it.
  final PMap<NodeId, NodeRecord> nodes;

  /// For each node, the nodes whose committed reads include a value of it.
  ///
  /// The index is a function of the dependencies of [nodes]. A node without a
  /// reader has no entry.
  final PMap<NodeId, PMap<NodeId, bool>> readers;

  /// For each key that a node needs to resolve, the nodes that need it: the
  /// required keys, and the strict collection keys. The key [collectionReaders]
  /// holds every node that reads a strict collection.
  ///
  /// The index is a function of the components of the nodes. An observer uses
  /// it to find the nodes that a change of a binding can affect.
  final PMap<DiKeyBase, PMap<NodeId, bool>> keyReaders;

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

  /// The ids of the nodes that read a value of [node], in no order.
  Iterable<NodeId> readersOf(NodeId node) =>
      readers[node]?.keys ?? const <NodeId>[];

  /// A state with the record [node] in place of the record of the same id. The
  /// index of the readers follows the dependencies of the record.
  RuntimeState withNode(NodeRecord node) {
    final before = nodes[node.id];
    var next = readers;
    if (before != null && before.dependencies.isNotEmpty) {
      for (final dependency in before.dependencies) {
        if (node.dependencies.contains(dependency)) continue;
        next = _without(next, dependency, node.id);
      }
    }
    for (final dependency in node.dependencies) {
      if (before != null && before.dependencies.contains(dependency)) continue;
      next = _with(next, dependency, node.id);
    }
    return RuntimeState._(
      scopes: scopes,
      nodes: nodes.put(node.id, node),
      readers: next,
      keyReaders: before == null
          ? _addKeyReader(keyReaders, scopes, node)
          : keyReaders,
      withdrawals: withdrawals,
      revision: revision,
      nextNodeId: nextNodeId,
      nextScopeId: nextScopeId,
      nextTicket: nextTicket,
    );
  }

  /// A state with the record [scope] in place of the record of the same id.
  RuntimeState withScope(ScopeRecord scope) => RuntimeState._(
    scopes: scopes.put(scope.id, scope),
    nodes: nodes,
    readers: readers,
    keyReaders: keyReaders,
    withdrawals: withdrawals,
    revision: revision,
    nextNodeId: nextNodeId,
    nextScopeId: nextScopeId,
    nextTicket: nextTicket,
  );

  /// A state with the given fields replaced.
  ///
  /// A new map of [nodes] builds the index of the readers again.
  RuntimeState copyWith({
    Map<ScopeId, ScopeRecord>? scopes,
    Map<NodeId, NodeRecord>? nodes,
    List<Withdrawal>? withdrawals,
    int? revision,
    int? nextNodeId,
    int? nextScopeId,
    int? nextTicket,
  }) {
    final newNodes = nodes == null ? this.nodes : PMap.from(nodes);
    final newScopes = scopes == null ? this.scopes : PMap.from(scopes);
    return RuntimeState._(
      scopes: newScopes,
      nodes: newNodes,
      readers: nodes == null ? readers : _readersOf(newNodes),
      keyReaders: nodes == null && scopes == null
          ? keyReaders
          : _keyReadersOf(newScopes, newNodes),
      withdrawals: withdrawals == null
          ? this.withdrawals
          : List.unmodifiable(withdrawals),
      revision: revision ?? this.revision,
      nextNodeId: nextNodeId ?? this.nextNodeId,
      nextScopeId: nextScopeId ?? this.nextScopeId,
      nextTicket: nextTicket ?? this.nextTicket,
    );
  }
}

PMap<NodeId, PMap<NodeId, bool>> _readersOf(PMap<NodeId, NodeRecord> nodes) {
  var result = PMap.empty<NodeId, PMap<NodeId, bool>>();
  for (final node in nodes.values) {
    for (final dependency in node.dependencies) {
      result = _with(result, dependency, node.id);
    }
  }
  return result;
}

PMap<NodeId, PMap<NodeId, bool>> _with(
  PMap<NodeId, PMap<NodeId, bool>> index,
  NodeId publisher,
  NodeId reader,
) => index.put(
  publisher,
  (index[publisher] ?? PMap.empty<NodeId, bool>()).put(reader, true),
);

PMap<NodeId, PMap<NodeId, bool>> _without(
  PMap<NodeId, PMap<NodeId, bool>> index,
  NodeId publisher,
  NodeId reader,
) {
  final rest = (index[publisher] ?? PMap.empty<NodeId, bool>()).without(reader);
  return rest.isEmpty ? index.without(publisher) : index.put(publisher, rest);
}

/// The key under which [RuntimeState.keyReaders] lists the nodes that read a
/// strict collection.
const DiSetKey<Object?> collectionReaders = DiSetKey<Object?>(
  name: '#collection readers',
);

PMap<DiKeyBase, PMap<NodeId, bool>> _addKeyReader(
  PMap<DiKeyBase, PMap<NodeId, bool>> index,
  PMap<ScopeId, ScopeRecord> scopes,
  NodeRecord node,
) {
  final scope = scopes[node.scope];
  if (scope == null || node.index >= scope.components.length) return index;
  final component = scope.components[node.index];
  var next = index;
  void add(DiKeyBase key) {
    next = next.put(
      key,
      (next[key] ?? PMap.empty<NodeId, bool>()).put(node.id, true),
    );
  }

  component.requires.forEach(add);
  if (component.collectionKeys.isNotEmpty) {
    component.collectionKeys.forEach(add);
    add(collectionReaders);
  }
  return next;
}

PMap<DiKeyBase, PMap<NodeId, bool>> _keyReadersOf(
  PMap<ScopeId, ScopeRecord> scopes,
  PMap<NodeId, NodeRecord> nodes,
) {
  var result = PMap.empty<DiKeyBase, PMap<NodeId, bool>>();
  for (final node in nodes.values) {
    result = _addKeyReader(result, scopes, node);
  }
  return result;
}
