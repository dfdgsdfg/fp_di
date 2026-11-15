// Internal functions. The library file does not export this file.
import 'package:fpdart/fpdart.dart';

import '../cause.dart';
import '../component.dart';
import '../failure.dart';
import '../finalizers.dart';
import '../key.dart';
import 'ids.dart';
import 'phases.dart';
import 'queries.dart';
import 'records.dart';
import 'runtime_state.dart';

// Each transition is a pure function from a state to the next state. A
// transition raises the revision exactly when the change is observable: a
// phase, a missing key, a failure, a commit count, or the list of children.

RuntimeState _bumped(RuntimeState s) => s.copyWith(revision: s.revision + 1);

RuntimeState _withNode(RuntimeState s, NodeRecord node) =>
    s.copyWith(nodes: {...s.nodes, node.id: node});

RuntimeState _withScope(RuntimeState s, ScopeRecord scope) =>
    s.copyWith(scopes: {...s.scopes, scope.id: scope});

/// Whether the phase of one of [ids] differs between [before] and [after].
bool _phaseChanged(RuntimeState before, RuntimeState after, List<ScopeId> ids) {
  for (final id in ids) {
    if (scopePhase(before, id) != scopePhase(after, id)) return true;
  }
  return false;
}

/// [after] with the revision raised when the phase of a scope in [ids]
/// changed.
RuntimeState _bumpOnPhase(
  RuntimeState before,
  RuntimeState after,
  List<ScopeId> ids,
) => _phaseChanged(before, after, ids) ? _bumped(after) : after;

/// What an observer sees of one node.
typedef _NodeView = (NodePhase, List<DiKeyBase>, Cause<DiFailure>?, int);

_NodeView _viewOf(RuntimeState s, NodeId n) => (
  nodePhase(s, n),
  unmet(s, n),
  nodeRecord(s, n).activationFailure.toNullable(),
  nodeRecord(s, n).commits,
);

bool _sameView(_NodeView a, _NodeView b) {
  if (a.$1 != b.$1 || !identical(a.$3, b.$3) || a.$4 != b.$4) return false;
  if (a.$2.length != b.$2.length) return false;
  for (var i = 0; i < a.$2.length; i++) {
    if (a.$2[i] != b.$2[i]) return false;
  }
  return true;
}

/// Declares a scope with the components [cs] under [parent].
///
/// A child joins the children of its parent, and the revision rises. A root
/// has no observer yet, so the revision stays.
(RuntimeState, ScopeId) declareScope(
  RuntimeState s,
  Option<ScopeId> parent,
  List<Component<Object?>> cs,
) {
  final id = ScopeId(s.nextScopeId);
  final scopes = {
    ...s.scopes,
    id: ScopeRecord(id: id, parent: parent, components: cs),
  };
  final parentId = parent.toNullable();
  if (parentId != null) {
    final record = scopeRecord(s, parentId);
    scopes[parentId] = record.copyWith(children: [...record.children, id]);
  }
  return (
    s.copyWith(
      scopes: scopes,
      nextScopeId: s.nextScopeId + 1,
      revision: s.revision + (parentId == null ? 0 : 1),
    ),
    id,
  );
}

/// Creates one node for each component of the scope [id], in declaration
/// order, and starts the initialization of the scope.
///
/// The scope has no node before. The revision rises.
(RuntimeState, List<NodeId>) createNodes(RuntimeState s, ScopeId id) {
  final scope = scopeRecord(s, id);
  final ids = [
    for (var i = 0; i < scope.components.length; i++) NodeId(s.nextNodeId + i),
  ];
  final created = {
    for (var i = 0; i < ids.length; i++)
      ids[i]: NodeRecord(id: ids[i], scope: id, index: i),
  };
  final next = _withScope(
    s.copyWith(
      nodes: {...s.nodes, ...created},
      nextNodeId: s.nextNodeId + ids.length,
    ),
    scope.copyWith(nodes: ids, initializing: true),
  );
  return (_bumped(next), ids);
}

/// Starts an activation of the node [n].
///
/// The caller checked that the node is not removed and not active, that the
/// setup is not refused, that the required keys resolve, and that no
/// withdrawal holds the node. The result holds the ticket of the activation.
/// The node loses the failure of its last activation, and its flag `doomed`
/// is false. The revision rises.
(RuntimeState, int) beginActivation(RuntimeState s, NodeId n) {
  final node = nodeRecord(s, n);
  final ticket = s.nextTicket;
  final next = _withNode(
    s,
    node.copyWith(
      inFlight: Some(ticket),
      doomed: false,
      activationFailure: const None(),
    ),
  );
  return (_bumped(next.copyWith(nextTicket: ticket + 1)), ticket);
}

/// Commits the activation of the node [n] in one step.
///
/// The node becomes active with [value], with the committed [view], with the
/// publishers [deps] that it read, and with the release functions [owned]. The
/// [membership] holds the contribution keys of each collection that the
/// activation read.
/// The scope binds every key of [declaredPublishes] to a new publisher
/// identity, which has the new commit number. The caller checked with
/// [conflictingPublication] that no key is bound. The activation ends, so the
/// node has no ticket. The revision rises.
RuntimeState commit(
  RuntimeState s,
  NodeId n,
  Object? value,
  Map<DiKey<Object?>, Option<PublisherRef>> view,
  Set<NodeId> deps,
  Finalizers owned, {
  Map<DiCollectionKey<Object?>, List<DiKey<Object?>>> membership = const {},
}) {
  final node = nodeRecord(s, n);
  final commits = node.commits + 1;
  final publisher = PublisherRef(n, commits);
  final scope = scopeRecord(s, node.scope);
  final next = _withScope(
    _withNode(
      s,
      node.copyWith(
        active: true,
        deactivating: false,
        available: true,
        reactivationBlocked: false,
        doomed: false,
        inFlight: const None(),
        committed: view,
        membership: membership,
        dependencies: {
          for (final dependency in deps)
            if (dependency != n) dependency,
        },
        value: Some(value),
        finalizers: owned,
        activationFailure: const None(),
        commits: commits,
      ),
    ),
    scope.copyWith(
      bindings: {
        ...scope.bindings,
        for (final key in declaredPublishes(s, node)) key: publisher,
      },
    ),
  );
  return _bumped(next);
}

/// Ends the activation of the node [n] without a commit.
///
/// The three endings differ in [failed], [failure], and [awaiting]:
///
/// - A withdrawal canceled the activation: [failed] is false, [failure] is
///   `None`, and [awaiting] holds the roots of the withdrawals. The node
///   waits for them.
/// - The owner canceled the activation: [failed] is true, and [failure] is
///   `None`.
/// - The activation failed: [failed] is true, and [failure] holds the cause.
///
/// A failed activation of a scope that is not initialized makes the node
/// `doomed`: it stays `activating` until the rollback removes it. The
/// revision rises when what an observer sees of the node changed.
RuntimeState endActivation(
  RuntimeState s,
  NodeId n, {
  required Option<Cause<DiFailure>> failure,
  required Set<NodeId> awaiting,
  required bool failed,
}) {
  final node = nodeRecord(s, n);
  final scope = scopeRecord(s, node.scope);
  final next = _withNode(
    s,
    node.copyWith(
      inFlight: const None(),
      doomed: node.doomed || (failed && !scope.initialized),
      awaiting: {...node.awaiting, ...awaiting},
      activationFailure: failure.isSome() ? failure : null,
    ),
  );
  return _sameView(_viewOf(s, n), _viewOf(next, n)) ? next : _bumped(next);
}

/// Starts the release of the node [n].
///
/// The node is deactivating and unavailable, so its keys stop resolving. The
/// state stays as it was when the node is not active or already releases. The
/// revision rises.
RuntimeState beginRelease(RuntimeState s, NodeId n) {
  final node = nodeRecord(s, n);
  if (node.removed || !node.active || node.deactivating) return s;
  return _bumped(
    _withNode(s, node.copyWith(deactivating: true, available: false)),
  );
}

/// Ends the release of the node [n].
///
/// The scope drops the bindings of the node. The node loses its value, its
/// committed view, its dependencies, and its release functions. [ownFailed]
/// states that a dispose function of the node failed, which blocks the
/// reactivation. A [permanent] release removes the node. A node that does not
/// release is removed when the release is [permanent], and stays as it is
/// otherwise. The revision rises when the state changes.
RuntimeState endRelease(
  RuntimeState s,
  NodeId n, {
  required bool ownFailed,
  required bool permanent,
}) {
  final node = nodeRecord(s, n);
  if (node.removed) return s;
  if (!node.deactivating) return permanent ? removeNode(s, n) : s;
  final released = _withNode(
    _withoutBindings(s, node),
    node.copyWith(
      active: false,
      deactivating: false,
      available: false,
      reactivationBlocked: ownFailed,
      committed: const {},
      membership: const {},
      dependencies: const {},
      value: const None(),
      finalizers: Finalizers.empty,
      removed: permanent,
      activationFailure: permanent ? const None() : null,
    ),
  );
  return _bumped(released);
}

RuntimeState _withoutBindings(RuntimeState s, NodeRecord node) {
  final scope = scopeRecord(s, node.scope);
  return _withScope(
    s,
    scope.copyWith(
      bindings: {
        for (final MapEntry(:key, value: publisher) in scope.bindings.entries)
          if (publisher.node != node.id) key: publisher,
      },
    ),
  );
}

/// Removes the node [n] for good.
///
/// The node leaves its bindings and loses its failure. The caller releases an
/// active node before. The node keeps its place in its scope, so its phase is
/// `disposed`. The revision rises.
RuntimeState removeNode(RuntimeState s, NodeId n) {
  final node = nodeRecord(s, n);
  if (node.removed) return s;
  return _bumped(
    _withNode(
      _withoutBindings(s, node),
      node.copyWith(removed: true, activationFailure: const None()),
    ),
  );
}

/// Ends the initialization of the scope [id] with success.
///
/// The scope is initialized and not initializing. The phase of a scope that
/// accepted a disposal stays `disposeRequested`. The revision rises when the
/// phase changes.
RuntimeState finishInitialize(RuntimeState s, ScopeId id) => _bumpOnPhase(
  s,
  _withScope(
    s,
    scopeRecord(s, id).copyWith(initialized: true, initializing: false),
  ),
  [id],
);

/// Ends the initialization of the scope [id] with a rollback.
///
/// The scope is not initializing. When no disposal was requested, the scope
/// is `declared` again and lists no node. Otherwise the scope keeps the list
/// of its nodes, and its phase stays `disposeRequested`. The records of the
/// nodes stay in the state in both cases, so a holder of a node id still reads
/// the phase `disposed`. The caller removed the nodes before. The revision
/// rises when the phase changes.
RuntimeState rollbackInitialize(RuntimeState s, ScopeId id) {
  final scope = scopeRecord(s, id);
  final next = _withScope(
    s,
    scope.copyWith(
      initializing: false,
      nodes: disposalRequested(s, id) ? null : const [],
    ),
  );
  return _bumpOnPhase(s, next, [id]);
}

/// Records that the scope [id] accepted a disposal.
///
/// The scope and its descendants have the phase `disposeRequested` from now
/// on, unless they are further. The revision rises when a phase changes.
RuntimeState requestScopeDisposal(RuntimeState s, ScopeId id) {
  final next = _withScope(
    s,
    scopeRecord(s, id).copyWith(disposeRequested: true),
  );
  return _bumpOnPhase(s, next, subtree(s, id));
}

/// Records that a caller asked to dispose the node [n].
///
/// The revision stays, because no observer sees the flag.
RuntimeState requestNodeDisposal(RuntimeState s, NodeId n) =>
    _withNode(s, nodeRecord(s, n).copyWith(disposeRequested: true));

/// Registers the withdrawal of [root].
///
/// The withdrawal keeps the reach of [root] as of now. Each node of
/// [canceled] had its activation canceled, so it waits for [root]. The
/// revision stays.
RuntimeState addWithdrawal(RuntimeState s, NodeId root, Set<NodeId> canceled) {
  final withdrawals = [
    ...s.withdrawals,
    Withdrawal(root, withdrawalReach(s, root)),
  ];
  return s.copyWith(
    withdrawals: withdrawals,
    nodes: {
      for (final MapEntry(:key, value: node) in s.nodes.entries)
        key: canceled.contains(key)
            ? node.copyWith(awaiting: {...node.awaiting, root})
            : node,
    },
  );
}

/// Ends the withdrawal of [root].
///
/// No node waits for [root] any more. The revision stays.
RuntimeState finishWithdrawal(RuntimeState s, NodeId root) => s.copyWith(
  withdrawals: [
    for (final withdrawal in s.withdrawals)
      if (withdrawal.root != root) withdrawal,
  ],
  nodes: {
    for (final MapEntry(:key, value: node) in s.nodes.entries)
      key: node.awaiting.contains(root)
          ? node.copyWith(awaiting: {...node.awaiting}..remove(root))
          : node,
  },
);

/// Starts the disposal of the scopes of [subtree].
///
/// Each scope is disposing. The revision rises when a phase changes.
RuntimeState markDisposing(RuntimeState s, List<ScopeId> subtree) {
  var next = s;
  for (final id in subtree) {
    next = _withScope(next, scopeRecord(next, id).copyWith(disposing: true));
  }
  return _bumpOnPhase(s, next, subtree);
}

/// Ends the disposal of the scope [id].
///
/// The scope is disposed, has no binding, and leaves the children of its
/// parent. The record stays, so its phase answers. The revision rises.
RuntimeState markDisposed(RuntimeState s, ScopeId id) {
  final scope = scopeRecord(s, id);
  final next = _withScope(
    s,
    scope.copyWith(disposed: true, disposing: false, bindings: const {}),
  );
  final parent = scope.parent.toNullable();
  if (parent == null) return _bumped(next);
  final record = scopeRecord(next, parent);
  return _bumped(
    _withScope(
      next,
      record.copyWith(
        children: [
          for (final child in record.children)
            if (child != id) child,
        ],
      ),
    ),
  );
}
