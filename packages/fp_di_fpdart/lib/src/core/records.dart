// Internal types. The library file does not export this file.
import 'package:fpdart/fpdart.dart';

import '../cause.dart';
import '../component.dart';
import '../failure.dart';
import '../finalizers.dart';
import '../key.dart';
import 'ids.dart';

/// The immutable record of one scope.
///
/// The collections of a record are unmodifiable. A transition builds a new
/// record with [copyWith].
final class ScopeRecord {
  /// Creates the record of the scope [id].
  ///
  /// A record without [contributionKeys] makes one key for each declaration
  /// that contributes to a set.
  factory ScopeRecord({
    required ScopeId id,
    Option<ScopeId> parent = const None(),
    required List<Component<Object?>> components,
    List<ScopeId> children = const [],
    bool initializing = false,
    bool initialized = false,
    bool disposeRequested = false,
    bool disposing = false,
    bool disposed = false,
    List<NodeId> nodes = const [],
    Map<DiKey<Object?>, PublisherRef> bindings = const {},
    List<ContributionKey?>? contributionKeys,
    Map<DiKey<Object?>, int>? keyIndex,
  }) {
    final keys = contributionKeys ?? _contributionKeysOf(components);
    return ScopeRecord._(
      id: id,
      parent: parent,
      components: List.unmodifiable(components),
      children: List.unmodifiable(children),
      initializing: initializing,
      initialized: initialized,
      disposeRequested: disposeRequested,
      disposing: disposing,
      disposed: disposed,
      nodes: List.unmodifiable(nodes),
      bindings: Map.unmodifiable(bindings),
      contributionKeys: List.unmodifiable(keys),
      keyIndex: Map.unmodifiable(keyIndex ?? _indexOfKeys(components, keys)),
    );
  }

  const ScopeRecord._({
    required this.id,
    required this.parent,
    required this.components,
    required this.children,
    required this.initializing,
    required this.initialized,
    required this.disposeRequested,
    required this.disposing,
    required this.disposed,
    required this.nodes,
    required this.bindings,
    required this.contributionKeys,
    required this.keyIndex,
  });

  /// The identity of the scope.
  final ScopeId id;

  /// The parent scope, or `None` for a root.
  final Option<ScopeId> parent;

  /// The components that the initialization turns into nodes.
  final List<Component<Object?>> components;

  /// The children in creation order. A disposed child leaves the list.
  final List<ScopeId> children;

  /// The initialization runs, from the creation of the nodes to its end.
  final bool initializing;

  /// An initialization succeeded. The flag never resets.
  final bool initialized;

  /// This scope accepted a disposal. The flag never resets.
  final bool disposeRequested;

  /// The disposal of this scope releases the nodes.
  final bool disposing;

  /// The disposal of this scope finished.
  final bool disposed;

  /// The nodes in declaration order. The list is empty until the
  /// initialization creates the nodes. A removed node keeps its place.
  final List<NodeId> nodes;

  /// The committed publications of the nodes of this scope, by key.
  final Map<DiKey<Object?>, PublisherRef> bindings;

  /// The key of each declaration that contributes to a set, by position, and
  /// `null` for another component. Each declaration has a key of its own, so
  /// every contribution is one binding of one key.
  final List<ContributionKey?> contributionKeys;

  /// The position of the component that publishes each key, and of the
  /// contribution that has each contribution key. An effect publishes no key.
  /// The map is a function of [components], so a copy keeps it.
  final Map<DiKey<Object?>, int> keyIndex;

  /// A record with the given fields replaced.
  ScopeRecord copyWith({
    List<ScopeId>? children,
    bool? initializing,
    bool? initialized,
    bool? disposeRequested,
    bool? disposing,
    bool? disposed,
    List<NodeId>? nodes,
    Map<DiKey<Object?>, PublisherRef>? bindings,
  }) => ScopeRecord(
    id: id,
    parent: parent,
    components: components,
    children: children ?? this.children,
    initializing: initializing ?? this.initializing,
    initialized: initialized ?? this.initialized,
    disposeRequested: disposeRequested ?? this.disposeRequested,
    disposing: disposing ?? this.disposing,
    disposed: disposed ?? this.disposed,
    nodes: nodes ?? this.nodes,
    bindings: bindings ?? this.bindings,
    contributionKeys: contributionKeys,
    keyIndex: keyIndex,
  );
}

List<ContributionKey?> _contributionKeysOf(
  List<Component<Object?>> components,
) => [
  for (final component in components)
    if (component.contributesTo case final set?) ContributionKey(set) else null,
];

Map<DiKey<Object?>, int> _indexOfKeys(
  List<Component<Object?>> components,
  List<ContributionKey?> contributions,
) {
  final index = <DiKey<Object?>, int>{};
  for (var i = 0; i < components.length; i++) {
    if (components[i].hasKey) index.putIfAbsent(components[i].key, () => i);
    if (contributions[i] case final key?) index[key] = i;
  }
  return index;
}

/// The immutable record of one node.
///
/// The collections of a record are unmodifiable. A transition builds a new
/// record with [copyWith].
final class NodeRecord {
  /// Creates the record of the node [id], which the component at [index] of
  /// [scope] declares.
  NodeRecord({
    required this.id,
    required this.scope,
    required this.index,
    this.active = false,
    this.deactivating = false,
    this.removed = false,
    this.doomed = false,
    this.reactivationBlocked = false,
    this.disposeRequested = false,
    this.available = true,
    this.inFlight = const None(),
    Map<DiKey<Object?>, Option<PublisherRef>> committed = const {},
    Set<NodeId> dependencies = const {},
    this.value = const None(),
    this.finalizers = Finalizers.empty,
    Map<DiCollectionKey<Object?>, List<DiKey<Object?>>> membership = const {},
    Set<NodeId> awaiting = const {},
    this.activationFailure = const None(),
    this.commits = 0,
  }) : committed = Map.unmodifiable(committed),
       membership = Map.unmodifiable({
         for (final MapEntry(:key, :value) in membership.entries)
           key: List<DiKey<Object?>>.unmodifiable(value),
       }),
       dependencies = Set.unmodifiable(dependencies),
       awaiting = Set.unmodifiable(awaiting);

  /// The identity of the node.
  final NodeId id;

  /// The scope that owns the node.
  final ScopeId scope;

  /// The position of the component of the node in its scope.
  final int index;

  /// The node has a committed value. The flag stays true while the release
  /// runs.
  final bool active;

  /// The release of the node runs.
  final bool deactivating;

  /// The runtime removed the node for good.
  final bool removed;

  /// An activation failed while the initialization of the scope runs. The
  /// rollback of the initialization removes the node.
  final bool doomed;

  /// A dispose function of the node failed in a release that was not final.
  final bool reactivationBlocked;

  /// A caller asked to dispose the node.
  final bool disposeRequested;

  /// The keys of the node resolve. The flag is false from the start of a
  /// release until the next commit.
  final bool available;

  /// The ticket of the activation that runs, or `None`. The shell maps the
  /// ticket to a cancellation token.
  final Option<int> inFlight;

  /// The publisher that each read key had at the last commit, or `None` for a
  /// key that did not resolve. A key that the map lacks counts as `None`.
  final Map<DiKey<Object?>, Option<PublisherRef>> committed;

  /// The contribution keys of each collection that the committed activation
  /// read, in the order of the read.
  final Map<DiCollectionKey<Object?>, List<DiKey<Object?>>> membership;

  /// The publishers that the committed activation read.
  final Set<NodeId> dependencies;

  /// The value of the node while it is active.
  final Option<Object?> value;

  /// The release functions of the values that the committed activation owns.
  final Finalizers finalizers;

  /// The roots of the pending withdrawals that canceled an activation of this
  /// node. The node stays ineligible while the set holds a root.
  final Set<NodeId> awaiting;

  /// The failure of the last activation that was not canceled.
  final Option<Cause<DiFailure>> activationFailure;

  /// The number of commits of the node.
  final int commits;

  /// A record with the given fields replaced.
  ///
  /// A parameter of type `Option` replaces the field, so `const None()`
  /// resets the field.
  NodeRecord copyWith({
    bool? active,
    bool? deactivating,
    bool? removed,
    bool? doomed,
    bool? reactivationBlocked,
    bool? disposeRequested,
    bool? available,
    Option<int>? inFlight,
    Map<DiKey<Object?>, Option<PublisherRef>>? committed,
    Map<DiCollectionKey<Object?>, List<DiKey<Object?>>>? membership,
    Set<NodeId>? dependencies,
    Option<Object?>? value,
    Finalizers? finalizers,
    Set<NodeId>? awaiting,
    Option<Cause<DiFailure>>? activationFailure,
    int? commits,
  }) => NodeRecord(
    id: id,
    scope: scope,
    index: index,
    active: active ?? this.active,
    deactivating: deactivating ?? this.deactivating,
    removed: removed ?? this.removed,
    doomed: doomed ?? this.doomed,
    reactivationBlocked: reactivationBlocked ?? this.reactivationBlocked,
    disposeRequested: disposeRequested ?? this.disposeRequested,
    available: available ?? this.available,
    inFlight: inFlight ?? this.inFlight,
    committed: committed ?? this.committed,
    membership: membership ?? this.membership,
    dependencies: dependencies ?? this.dependencies,
    value: value ?? this.value,
    finalizers: finalizers ?? this.finalizers,
    awaiting: awaiting ?? this.awaiting,
    activationFailure: activationFailure ?? this.activationFailure,
    commits: commits ?? this.commits,
  );
}
