part of 'scope.dart';

// The state that the runtime keeps for each node and publication. A member
// that only reads the state delegates to a rule of `core/`. The state of a
// scope is `_RuntimeScope` in scope.dart, and the context of one activation
// is `_RuntimeContext` in runtime_context.dart.

/// The key under which one declared set contribution publishes. Each
/// declaration has its own key, so every contribution is one binding of one
/// key in one scope. It never leaves the runtime: `NodeState.key` is null for a
/// contribution.
final class _DiContributionKey implements DiKeyBase {
  _DiContributionKey(this.set);

  final DiSetKey<Object?> set;

  @override
  Type get type => set.type;

  @override
  String? get name => null;

  @override
  String toString() => 'contribution to $set';
}

/// The journal positions whose release started, for each activation. Only the
/// `ReleaseAtMostOnce` self-check touches it, inside an `assert`.
final Expando<Set<int>> _releaseStarts = Expando<Set<int>>('release starts');

/// Records that the release of journal entry [position] of [episode] starts,
/// and tells whether it is the first start. A release without an episode has
/// nothing to record.
bool _startRelease(_RuntimeContext? episode, int position) {
  if (episode == null) return true;
  return (_releaseStarts[episode] ??= <int>{}).add(position);
}

final class _RuntimePublisher implements CorePublisher<_RuntimeNode> {
  _RuntimePublisher(this.key, this.value, this.scope, this.owner);

  final DiKeyBase key;
  final Object? value;
  final _RuntimeScope scope;
  @override
  final _RuntimeNode owner;
  @override
  final Set<_RuntimeNode> dependents = <_RuntimeNode>{};
  @override
  bool available = true;
}

final class _RuntimeNode
    implements CoreNode<_RuntimeScope, _RuntimePublisher, _RuntimeNode> {
  _RuntimeNode({
    required this.id,
    required this.scope,
    required this.label,
    required this.run,
    required this.declaredRequires,
    required this.declaredPlainReads,
    required this.declaredPublishes,
    required this.declarationIndex,
    required this.publicKey,
    this.collectionKeys = const {},
    this.optionalCollectionKeys = const {},
    this.contributionKey,
  });

  @override
  final int id;
  @override
  final _RuntimeScope scope;
  @override
  final String label;
  final Future<Object?> Function(DiContext context) run;

  @override
  final Set<DiKeyBase> declaredRequires;

  /// Every key whose publisher identity this node is bound to.
  @override
  final Set<DiKeyBase> declaredPlainReads;
  @override
  final Set<DiKeyBase> declaredPublishes;

  /// The position of the component of this node in the module of its scope.
  @override
  final int declarationIndex;

  /// The collection keys that this node reads strictly and optionally. Their
  /// contribution keys are expanded against the current membership each time,
  /// not captured here, because a disposal removes a contribution.
  @override
  final Set<DiCollectionKey<Object?>> collectionKeys;
  @override
  final Set<DiCollectionKey<Object?>> optionalCollectionKeys;

  /// The contribution key of a set contribution, or null.
  final _DiContributionKey? contributionKey;

  @override
  DiSetKey<Object?>? get contributionSet => contributionKey?.set;

  /// The key of the component, which `NodeState.key` shows, or null. A
  /// contribution key is never one.
  @override
  final DiKeyBase? publicKey;

  /// The collection that this node contributes to, as a set contribution or
  /// a map entry, or null. Its commit, its withdrawal, and its removal can
  /// change the `missing` keys of a strict reader of that collection.
  late final DiCollectionKey<Object?>? contributesTo =
      contributionKey?.set ??
      switch (publicKey) {
        final DiMapEntryKey<Object?> entry => entry.mapKey,
        _ => null,
      };

  /// For each strict collection read that is missing in the state of this
  /// node, one contribution key that the runtime found unresolved, with its
  /// position in [membership]. The state of this node cannot lose that
  /// collection key before this contribution key resolves or leaves, so the
  /// runtime refreshes the node only then. Only `_Runtime._track` writes it.
  @override
  Map<DiCollectionKey<Object?>, ({DiKeyBase key, int index})> witnesses =
      const {};

  /// The contribution keys of each strict collection read, as
  /// [contributionKeysOf] returned them at [membershipVersion]. Only
  /// `_Runtime._track` reads and writes the two fields.
  final Map<DiCollectionKey<Object?>, List<DiKeyBase>> membership =
      <DiCollectionKey<Object?>, List<DiKeyBase>>{};
  int membershipVersion = -1;

  /// The state of this node in the state of the runtime. Only
  /// `_Runtime.refresh` replaces it, so each public read of a node agrees
  /// with `Scope.state`.
  @override
  late NodeState state;

  /// The number of activations that this node committed.
  @override
  int commits = 0;

  /// An activation of this node failed while `initialize` of its scope runs.
  /// The rollback of that call disposes the node, so its phase stays
  /// `activating` until then.
  @override
  bool doomed = false;
  Object? value;
  List<DisposeFunction> cleanups = <DisposeFunction>[];
  @override
  Set<_RuntimePublisher> dependencies = <_RuntimePublisher>{};

  /// The number of entries in the committed `dependencies` of all nodes whose
  /// publisher this node owns. When it is zero, no walk over the committed
  /// reads reaches this node, so the cycle check of its reads skips the walk.
  /// Only `_Runtime.commitDependencies` and `_Runtime.clearDependencies`
  /// change it.
  int committedReaders = 0;
  @override
  Set<_RuntimePublisher> publishers = <_RuntimePublisher>{};
  @override
  Map<DiKeyBase, _RuntimePublisher> committed =
      <DiKeyBase, _RuntimePublisher>{};

  /// The membership of each collection read at the committed activation.
  @override
  Map<DiCollectionKey<Object?>, List<DiKeyBase>> committedMembership =
      <DiCollectionKey<Object?>, List<DiKeyBase>>{};
  _RuntimeContext? activationContext;

  /// The activation that is running now, or null.
  _RuntimeContext? inFlight;

  @override
  bool get activationInFlight => inFlight != null;

  /// `ComponentNode.dispose` was called for this node.
  bool disposeRequested = false;

  /// The result of the first `ComponentNode.dispose` call.
  Future<void>? disposal;

  /// Whether [disposal] completed.
  bool disposalFinished = false;

  /// The withdrawals that canceled an activation of this node and have not
  /// finished. The node stays inactive until the set is empty.
  final Set<_RuntimeNode> awaiting = <_RuntimeNode>{};

  /// Whether the disposal of this node, its scope, or an ancestor was
  /// requested.
  bool get disposalRequested => disposeRequested || scope.disposalRequested;
  @override
  bool removed = false;
  @override
  bool active = false;
  @override
  bool reactivationBlocked = false;

  /// The failure of the last activation of this node, when that activation
  /// failed and was not canceled. Only `_Runtime.stateOf` and
  /// `_Runtime.activationExceptionOf` read it; no decision of the runtime does.
  @override
  ActivationException? activationException;
  @override
  bool deactivating = false;

  /// The next commit that `ComponentNode.whenActive` callers wait for.
  /// The callers of one zone share one completer, so repeated reads do not
  /// grow state. A completer completes by a microtask of the zone that created
  /// it, so a caller of another zone cannot share it: that zone can be dead.
  Map<Zone, Completer<Object?>>? activationWaiters;

  /// The nearest available publisher of [key] that this node does not own.
  @override
  _RuntimePublisher? resolve(DiKeyBase key) =>
      scope.resolve(key, excludeOwner: this);

  /// The contribution keys of [key] that this node reads, as
  /// [coreContributionKeysOf] computes them.
  List<DiKeyBase> contributionKeysOf(DiCollectionKey<Object?> key) =>
      coreContributionKeysOf(this, key);

  /// Every key whose publisher identity this node is bound to now: its plain
  /// reads and the contribution keys of its collection reads.
  Iterable<DiKeyBase> get plainReads => corePlainReads(this);

  /// Whether every declared requirement of this node resolves now, and
  /// every contribution key of each of its strict collection reads.
  bool get satisfied => coreSatisfied(this);

  /// For each strict collection read with a contribution key that does not
  /// resolve now, the last such contribution key.
  Map<DiCollectionKey<Object?>, DiKeyBase> get unresolvedContributions =>
      coreUnresolvedContributions(this);

  /// The keys gating this node that do not resolve now, in a stable order:
  /// its required keys, then each strict collection key with a contribution
  /// key that does not resolve.
  List<DiKeyBase> get unmet => coreUnmet(this);
}
