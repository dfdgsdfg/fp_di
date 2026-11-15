// Internal functions. The library file does not export this file.
import 'package:fpdart/fpdart.dart';

import '../cause.dart';
import '../component.dart';
import '../failure.dart';
import '../key.dart';
import 'ids.dart';
import 'phases.dart';
import 'records.dart';
import 'runtime_state.dart';

/// The record of the scope [id]. An unknown id is a programming error.
ScopeRecord scopeRecord(RuntimeState s, ScopeId id) =>
    s.scopes[id] ?? (throw StateError('Unknown scope ${id.value}'));

/// The record of the node [id]. An unknown id is a programming error.
NodeRecord nodeRecord(RuntimeState s, NodeId id) =>
    s.nodes[id] ?? (throw StateError('Unknown node ${id.value}'));

/// The component that the node [n] runs.
Component<Object?> componentOf(RuntimeState s, NodeRecord n) =>
    scopeRecord(s, n.scope).components[n.index];

/// The nodes that the runtime did not remove, in ascending id.
List<NodeRecord> liveNodes(RuntimeState s) => [
  for (final node in s.nodes.values)
    if (!node.removed) node,
]..sort((a, b) => a.id.value.compareTo(b.id.value));

// ---- Seams. One function each.

/// The contribution keys that the node [n] reads for the collection key
/// [collection], in the order of the read.
///
/// The keys come from the declarations of the scope of the node and of its
/// ancestors, the ancestors first, and the declaration order within a scope. A
/// scope that did not run counts. The declaration of the node itself does not
/// count, and a node that the runtime removed in an initialized scope does not
/// count. A key that two scopes declare appears once, at its first position.
List<DiKey<Object?>> contributionKeysOf(
  RuntimeState s,
  NodeId n,
  DiCollectionKey<Object?> collection,
) {
  final node = nodeRecord(s, n);
  final chain = <ScopeRecord>[];
  for (
    ScopeId? at = node.scope;
    at != null;
    at = scopeRecord(s, at).parent.toNullable()
  ) {
    chain.add(scopeRecord(s, at));
  }
  final result = <DiKey<Object?>>[];
  final seen = <DiKey<Object?>>{};
  for (final scope in chain.reversed) {
    for (var i = 0; i < scope.components.length; i++) {
      final component = scope.components[i];
      final DiKey<Object?>? contribution = switch (collection) {
        DiSetKey<Object?>() =>
          component.contributesTo == collection
              ? scope.contributionKeys[i]
              : null,
        DiMapKey<Object?>() => switch (component.key) {
          final DiMapEntryKey<Object?> entry
              when component.hasKey && entry.mapKey == collection =>
            entry,
          _ => null,
        },
      };
      if (contribution == null) continue;
      if (scope.id == node.scope && i == node.index) continue;
      if (scope.initialized &&
          i < scope.nodes.length &&
          nodeRecord(s, scope.nodes[i]).removed) {
        continue;
      }
      if (seen.add(contribution)) result.add(contribution);
    }
  }
  return result;
}

/// The keys whose publisher the node [n] is bound to: the required keys, the
/// optional keys, and the contribution keys of every collection that it reads,
/// strictly or not.
Set<DiKey<Object?>> plainReads(RuntimeState s, NodeRecord n) {
  final component = componentOf(s, n);
  return {
    ...component.requires,
    ...component.optional,
    for (final collection in component.collectionKeys)
      ...contributionKeysOf(s, n.id, collection),
    for (final collection in component.optionalCollectionKeys)
      ...contributionKeysOf(s, n.id, collection),
  };
}

/// The keys that the node [n] publishes when it commits.
///
/// An effect publishes no key. A contribution publishes the key of its
/// declaration. A map entry publishes its entry key.
Set<DiKey<Object?>> declaredPublishes(RuntimeState s, NodeRecord n) {
  final component = componentOf(s, n);
  if (component.hasKey) return {component.key};
  final contribution = scopeRecord(s, n.scope).contributionKeys[n.index];
  return contribution == null ? const {} : {contribution};
}

// ---- Resolution.

/// The nearest committed and available publisher of [key], from the scope
/// [from] to the root.
///
/// A publication that the node [exclude] owns does not count, and the walk
/// continues in the ancestors.
Option<PublisherRef> resolve(
  RuntimeState s,
  ScopeId from,
  DiKey<Object?> key, {
  Option<NodeId> exclude = const None(),
}) {
  final excluded = exclude.toNullable();
  ScopeId? at = from;
  while (at != null) {
    final scope = s.scopes[at];
    if (scope == null) break;
    final publisher = scope.bindings[key];
    if (publisher != null) {
      final owner = s.nodes[publisher.node];
      if (owner != null && owner.available && publisher.node != excluded) {
        return Some(publisher);
      }
    }
    at = scope.parent.toNullable();
  }
  return const None();
}

/// The publisher that the node [n] resolves now, for each key that it reads.
///
/// A key that does not resolve maps to `None`.
Map<DiKey<Object?>, Option<PublisherRef>> target(RuntimeState s, NodeId n) {
  final node = nodeRecord(s, n);
  return {
    for (final key in plainReads(s, node))
      key: resolve(s, node.scope, key, exclude: Some(n)),
  };
}

bool _samePublisher(Option<PublisherRef> a, Option<PublisherRef> b) =>
    a.toNullable() == b.toNullable();

/// Whether the resolved publisher of a key that the node [n] reads differs
/// from the publisher of the last commit.
///
/// The comparison is by identity of the commit. A key that the committed view
/// lacks counts as `None`.
bool targetChanged(RuntimeState s, NodeId n) {
  final node = nodeRecord(s, n);
  for (final key in plainReads(s, node)) {
    final next = resolve(s, node.scope, key, exclude: Some(n));
    final committed = node.committed[key] ?? const None();
    if (!_samePublisher(next, committed)) return true;
  }
  // A collection changed when its members changed, also when no member
  // resolves differently.
  final component = componentOf(s, node);
  for (final collection in [
    ...component.collectionKeys,
    ...component.optionalCollectionKeys,
  ]) {
    final previous = node.membership[collection];
    final keys = contributionKeysOf(s, n, collection);
    if (previous == null || !_sameKeys(previous, keys)) return true;
  }
  return false;
}

bool _sameKeys(List<DiKey<Object?>> a, List<DiKey<Object?>> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The keys that keep the node [n] from activating, in a stable order: the
/// required keys that do not resolve now, in the order of the declaration, and
/// then each strict collection key that has a contribution key that does not
/// resolve.
List<DiKeyBase> unmet(RuntimeState s, NodeId n) {
  final node = nodeRecord(s, n);
  final component = componentOf(s, node);
  bool unresolved(DiKey<Object?> key) =>
      resolve(s, node.scope, key, exclude: Some(n)).isNone();
  return [
    for (final key in component.requires)
      if (unresolved(key)) key,
    for (final collection in component.collectionKeys)
      if (contributionKeysOf(s, n, collection).any(unresolved)) collection,
  ];
}

/// Whether every required key of the node [n] resolves now, and every
/// contribution of each strict collection that it reads.
bool satisfied(RuntimeState s, NodeId n) => unmet(s, n).isEmpty;

// ---- Phases.

/// The phase of the node [n]: the first row that holds.
NodePhase nodePhase(RuntimeState s, NodeId n) {
  final node = nodeRecord(s, n);
  if (node.removed) return NodePhase.disposed;
  if (node.active && !node.deactivating) return NodePhase.active;
  if (node.deactivating) return NodePhase.deactivating;
  if (node.inFlight.isSome() || node.doomed) return NodePhase.activating;
  if (node.reactivationBlocked) return NodePhase.disposeFailed;
  if (unmet(s, n).isNotEmpty) return NodePhase.waiting;
  if (node.activationFailure.isSome()) return NodePhase.activationFailed;
  return NodePhase.inactive;
}

/// The phase of the scope [id]: the first row that holds.
///
/// A disposal that an ancestor accepted gives `disposeRequested`.
ScopePhase scopePhase(RuntimeState s, ScopeId id) {
  final scope = scopeRecord(s, id);
  if (scope.disposed) return ScopePhase.disposed;
  if (scope.disposing) return ScopePhase.disposing;
  if (disposalRequested(s, id)) return ScopePhase.disposeRequested;
  if (scope.initialized) return ScopePhase.initialized;
  if (scope.initializing) return ScopePhase.initializing;
  return ScopePhase.declared;
}

/// Whether the scope [id] or an ancestor accepted a disposal.
///
/// A scope that is disposing or disposed has accepted it.
bool disposalRequested(RuntimeState s, ScopeId id) {
  ScopeId? at = id;
  while (at != null) {
    final scope = s.scopes[at];
    if (scope == null) return false;
    if (scope.disposeRequested || scope.disposing || scope.disposed) {
      return true;
    }
    at = scope.parent.toNullable();
  }
  return false;
}

/// Whether the disposal of the node [n], of its scope, or of an ancestor of
/// its scope was requested, so that no setup starts.
bool setupRefused(RuntimeState s, NodeId n) {
  final node = nodeRecord(s, n);
  return node.disposeRequested || disposalRequested(s, node.scope);
}

// ---- Relations.

/// The nodes that committed a read of a value of [publisher], in descending
/// id, and that are active or deactivating.
///
/// A release of [publisher] releases these nodes first.
List<NodeId> dependentsOf(RuntimeState s, NodeId publisher) => [
  for (final node in s.nodes.values)
    if (!node.removed &&
        node.id != publisher &&
        (node.active || node.deactivating) &&
        node.dependencies.contains(publisher))
      node.id,
]..sort((a, b) => b.value.compareTo(a.value));

/// The active nodes that are not removed and whose target changed, in
/// descending id.
List<NodeId> staleActives(RuntimeState s) => [
  for (final node in liveNodes(s))
    if (node.active && targetChanged(s, node.id)) node.id,
]..sort((a, b) => b.value.compareTo(a.value));

/// The nodes that a reconciliation may activate, in ascending id.
///
/// A node qualifies when it is not removed and not active, when its release
/// is not blocked, when its scope is not disposing or disposed, when no
/// disposal was requested for it, when no withdrawal holds it, when it is not
/// in [failed], and when its required keys resolve.
List<NodeId> dormantCandidates(RuntimeState s, Set<NodeId> failed) => [
  for (final node in liveNodes(s))
    if (!node.active &&
        !node.reactivationBlocked &&
        !scopeRecord(s, node.scope).disposed &&
        !scopeRecord(s, node.scope).disposing &&
        !setupRefused(s, node.id) &&
        node.awaiting.isEmpty &&
        !failed.contains(node.id) &&
        satisfied(s, node.id))
      node.id,
]..sort((a, b) => a.value.compareTo(b.value));

/// The scope [id] and its descendants, parents first. The children keep their
/// creation order.
List<ScopeId> subtree(RuntimeState s, ScopeId id) {
  final result = <ScopeId>[];
  void collect(ScopeId at) {
    result.add(at);
    scopeRecord(s, at).children.forEach(collect);
  }

  collect(id);
  return result;
}

/// The path of the scope [id], as `describeScope` names it: `scope` for the
/// root, and `child scope 1.2` for the second child of the first child.
///
/// A scope has the index of its position among the children of its parent,
/// counted from 1.
String scopePath(RuntimeState s, ScopeId id) {
  final indexes = <int>[];
  var at = id;
  var parent = scopeRecord(s, at).parent.toNullable();
  while (parent != null) {
    indexes.add(scopeRecord(s, parent).children.indexOf(at) + 1);
    at = parent;
    parent = scopeRecord(s, at).parent.toNullable();
  }
  return indexes.isEmpty
      ? 'scope'
      : 'child scope ${indexes.reversed.join('.')}';
}

/// The first key of the node [n] that its scope binds already, or `None`.
///
/// A commit of the node fails when its scope binds one of its keys.
Option<DiKey<Object?>> conflictingPublication(RuntimeState s, NodeId n) {
  final node = nodeRecord(s, n);
  final bindings = scopeRecord(s, node.scope).bindings;
  for (final key in declaredPublishes(s, node)) {
    if (bindings.containsKey(key)) return Some(key);
  }
  return const None();
}

/// The check that runs before the initialization changes any state.
///
/// The cause holds every problem, joined with `&`: the problems of each
/// declaration first, in the order of the components, then the duplicate keys,
/// and then the undeclared keys. Each group follows the order of the
/// declaration. The cause is empty when the components pass.
///
/// A key is undeclared when a member requires it, and neither another member
/// of the scope nor an ancestor of the scope declares it. An ancestor counts
/// with its declared keys, whether or not it is initialized. A member never
/// satisfies its own requirement. An effect declares no key.
Cause<DiFailure> preCheck(RuntimeState s, ScopeId id) {
  final scope = scopeRecord(s, id);
  final members = scope.components;
  final owners = <DiKey<Object?>, List<String>>{};
  for (final member in members) {
    if (member.hasKey) (owners[member.key] ??= []).add(member.label);
  }
  final declared = <DiKey<Object?>>{};
  for (
    ScopeId? at = scope.parent.toNullable();
    at != null;
    at = scopeRecord(s, at).parent.toNullable()
  ) {
    for (final component in scopeRecord(s, at).components) {
      if (component.hasKey) declared.add(component.key);
    }
  }
  final problems = <Cause<DiFailure>>[
    for (final member in members) ..._declarationProblems(member),
    for (final MapEntry(:key, value: labels) in owners.entries)
      if (labels.length > 1)
        Fail<DiFailure>(DuplicateKeyFailure(key, labels), StackTrace.current),
  ];
  for (var i = 0; i < members.length; i++) {
    for (final key in members[i].requires) {
      if (declared.contains(key)) continue;
      var published = false;
      for (var j = 0; j < members.length && !published; j++) {
        published = j != i && members[j].hasKey && members[j].key == key;
      }
      if (!published) {
        problems.add(
          Fail<DiFailure>(
            UndeclaredKeyFailure(key, owner: members[i].label),
            StackTrace.current,
          ),
        );
      }
    }
  }
  return problems.fold<Cause<DiFailure>>(
    const Empty<DiFailure>(),
    (all, next) => all & next,
  );
}

/// The problems of one declaration: a component that does not fit its type
/// argument, a published key or a read key without a name of a core value
/// type, and a published key that no read can produce.
///
/// An effect and a contribution publish no key, so no key check applies to
/// them. A collection key always has a name.
List<Cause<DiFailure>> _declarationProblems(Component<Object?> member) {
  final label = member.label;
  final found = <DiFailure>[];
  final reason = member.invalidReason;
  if (reason != null) found.add(InvalidComponentFailure(label, reason));
  if (member.hasKey) {
    if (member.key.needsName) {
      found.add(UnnamedKeyFailure(member.key, owner: label));
    }
    if (member.key.isUnreachable) {
      found.add(UnreachableKeyFailure(member.key));
    }
  }
  for (final read in {...member.requires, ...member.optional}) {
    if (read.needsName) found.add(UnnamedKeyFailure(read, owner: label));
  }
  return [
    for (final failure in found) Fail<DiFailure>(failure, StackTrace.current),
  ];
}

/// The node [root] and its transitive dependents that are active.
///
/// The withdrawal of [root] deactivates exactly these nodes. An active node
/// includes a node whose release started.
Set<NodeId> withdrawalReach(RuntimeState s, NodeId root) {
  final reach = <NodeId>{root};
  final pending = <NodeId>[root];
  while (pending.isNotEmpty) {
    final next = pending.removeLast();
    for (final node in s.nodes.values) {
      if (!node.removed &&
          node.active &&
          node.dependencies.contains(next) &&
          reach.add(node.id)) {
        pending.add(node.id);
      }
    }
  }
  return reach;
}

/// The roots of the pending withdrawals whose reach holds the node [owner].
///
/// A reader that reads a value of [owner] while one of these withdrawals is
/// pending must cancel its activation.
List<NodeId> withdrawalsOf(RuntimeState s, NodeId owner) => [
  for (final withdrawal in s.withdrawals)
    if (withdrawal.reach.contains(owner)) withdrawal.root,
];

/// The nodes whose running activation a withdrawal with [reach] cancels.
///
/// A node qualifies when an activation of it runs, when no disposal was
/// requested for it, and when it reads a value of a node in [reach]. The
/// reads are those in [reads], which the runtime recorded while the
/// activation ran, and the keys that the node reads and that resolve to such
/// a node now.
Set<NodeId> withdrawalCancels(
  RuntimeState s,
  Set<NodeId> reach, {
  Map<NodeId, Set<NodeId>> reads = const {},
}) {
  final canceled = <NodeId>{};
  for (final node in liveNodes(s)) {
    if (node.inFlight.isNone() || setupRefused(s, node.id)) continue;
    if ((reads[node.id] ?? const <NodeId>{}).any(reach.contains)) {
      canceled.add(node.id);
      continue;
    }
    for (final key in plainReads(s, node)) {
      final publisher = resolve(s, node.scope, key, exclude: Some(node.id));
      if (publisher.toNullable() case final found?
          when reach.contains(found.node)) {
        canceled.add(node.id);
        break;
      }
    }
  }
  return canceled;
}
