part of 'scope.dart';

// The interpreter behind every Scope of one root: node activation and
// deactivation, and reconciliation. Its mutations run on the queue of
// runtime_mutation_queue.dart, and it reports through
// runtime_change_broadcaster.dart.

final class _Runtime {
  _Runtime({
    SlowMutationListener? onSlowMutation,
    required Duration slowMutationThreshold,
  }) : slowListener = onSlowMutation,
       slowThreshold = slowMutationThreshold {
    mutations = _RuntimeMutationQueue(
      onSlow: onSlowMutation == null
          ? null
          : (operation, elapsed) =>
                onSlowMutation(_slowMutation(operation, elapsed)),
      slowThreshold: slowMutationThreshold,
    );
  }

  /// The serial queue that every mutation of this runtime runs on.
  late final _RuntimeMutationQueue mutations;

  /// The listener of slow work, which also hears of a long wait for holds.
  final SlowMutationListener? slowListener;
  final Duration slowThreshold;

  final Set<Scope> scopes = <Scope>{};
  final Set<_RuntimeNode> nodes = <_RuntimeNode>{};

  /// The listeners and the error stream of this runtime.
  final _RuntimeChangeBroadcaster changes = _RuntimeChangeBroadcaster();

  int _nextNode = 0;

  /// The report of [operation], which runs for [elapsed] now.
  SlowMutation _slowMutation(String operation, Duration elapsed) {
    final inFlight = [
      for (final node in nodes)
        if (node.inFlight != null) node,
    ]..sort((a, b) => a.id.compareTo(b.id));
    return SlowMutation(
      operation: operation,
      elapsed: elapsed,
      running: [for (final node in inFlight) node.label],
      ignoringCancellation: [
        for (final node in inFlight)
          if (node.inFlight!.token.isCanceled) node.label,
      ],
      disposing: _releasing,
      queued: mutations.queued,
    );
  }

  _RuntimeNode createNode<A>(
    _RuntimeScope scope,
    Component<A> component, {
    required int declarationIndex,
  }) {
    final id = _nextNode++;
    final contributionKey = scope.contributionKeys[declarationIndex];
    final node = _RuntimeNode(
      id: id,
      scope: scope,
      label:
          component.debugLabel ??
          (component.key == null ? '${component.label}#$id' : component.label),
      run: (context) => runComponent(component, context),
      declaredRequires: Set<DiKeyBase>.of(component.requires),
      declaredPlainReads: <DiKeyBase>{
        ...component.requires,
        ...component.optional,
      },
      declaredPublishes: <DiKeyBase>{?component.key, ?contributionKey},
      declarationIndex: declarationIndex,
      publicKey: component.key,
      collectionKeys: Set<DiCollectionKey<Object?>>.of(
        component.collectionKeys,
      ),
      optionalCollectionKeys: Set<DiCollectionKey<Object?>>.of(
        component.optionalCollectionKeys,
      ),
      contributionKey: contributionKey,
    );
    nodes.add(node);
    for (final key in node.declaredRequires) {
      (_requirers[key] ??= <_RuntimeNode>{}).add(node);
    }
    for (final key in node.collectionKeys) {
      (_collectionReaders[key] ??= <_RuntimeNode>{}).add(node);
    }
    _track(node);
    node.state = _stateOf(node, tracked: true);
    return node;
  }

  /// The node of [scope] whose component publishes [key], or null when
  /// [scope] has no such node or the node is disposed.
  ///
  /// A scope has nodes from its `initialize` call, also before that call
  /// completes.
  _RuntimeNode? nodeOf(_RuntimeScope scope, DiKeyBase key) =>
      coreNodeOf(scope, key);

  /// The nearest node, other than [reader], that publishes [key] or has
  /// the contribution key [key], from the scope of [reader] to the root.
  _RuntimeNode? _nodeBehind(_RuntimeNode reader, DiKeyBase key) =>
      coreNodeBehind(reader, key);

  /// The error of a `Scope.get` call for [key] from [scope], when the key
  /// has no value (specs/runtime/lifecycle, "The cause of an unavailable
  /// key"). The search is [coreUnavailable].
  UnavailableKeyException unavailable(
    _RuntimeScope scope,
    DiKey<Object?> key,
  ) => coreUnavailable(
    scope,
    key,
    // The defect drops the failed nodes and keeps the message.
    dropFailedNodes: RuntimeFaults.injects(RuntimeDefect.dropFailedNodes),
  );

  /// Removes [node] from the runtime for good and fails its waiters.
  void removeNode(_RuntimeNode node) {
    node
      ..removed = true
      ..activationException = null;
    nodes.remove(node);
    for (final key in node.declaredRequires) {
      _unindex(_requirers, key, node);
    }
    for (final key in node.collectionKeys) {
      _unindex(_collectionReaders, key, node);
    }
    // A removed contributor leaves its collection.
    if (node.contributesTo != null) _membershipVersion++;
    final waiters = node.activationWaiters?.values.toList();
    if (waiters == null) return;
    node.activationWaiters = null;
    for (final waiter in waiters) {
      waiter.completeError(InactiveNodeException());
    }
  }

  /// The phase of [node], computed from the fields of the node.
  NodePhase phaseOf(_RuntimeNode node) => coreNodePhase(node);

  // ---- The state of the runtime (specs/runtime/lifecycle, "State of the
  // runtime"). A node holds its `NodeState`, which `refresh` replaces at a
  // transition. A scope holds its phase, and `stateOf` builds its
  // `ScopeState` at a read, for the scopes that a transition changed.

  /// The nodes that require each key. A commit or a withdrawal of a key can
  /// change the `missing` keys of these nodes, and of no other node.
  final Map<DiKeyBase, Set<_RuntimeNode>> _requirers =
      <DiKeyBase, Set<_RuntimeNode>>{};

  /// The nodes with a strict read of each collection key.
  final Map<DiCollectionKey<Object?>, Set<_RuntimeNode>> _collectionReaders =
      <DiCollectionKey<Object?>, Set<_RuntimeNode>>{};

  /// The nodes that wait for each contribution key: the values of
  /// `_RuntimeNode.witnesses`, by key.
  final Map<DiKeyBase, Set<_RuntimeNode>> _waiters =
      <DiKeyBase, Set<_RuntimeNode>>{};

  /// Removes [node] from the entry of [key] in [index], and the entry when
  /// it holds no other node. A set contribution has an internal key of its
  /// own in each scope, so an entry that stays would outlive its scope.
  static void _unindex<K>(
    Map<K, Set<_RuntimeNode>> index,
    K key,
    _RuntimeNode node,
  ) {
    final indexed = index[key];
    if (indexed == null) return;
    indexed.remove(node);
    if (indexed.isEmpty) index.remove(key);
  }

  /// The number of contributors that left a collection. A membership that a
  /// node holds from an earlier number is stale.
  int _membershipVersion = 0;

  /// Records the contribution key that [node] waits for, for each strict
  /// collection read that does not resolve now.
  ///
  /// A collection key is missing while one contribution key does not
  /// resolve. A commit of another contribution changes nothing for the
  /// node, so the runtime refreshes the node only when this one key
  /// resolves or leaves the collection. The search for the next key starts
  /// at the position of the last one and goes toward the first
  /// contribution, so a sequence of commits in any order reads each
  /// position once before the search starts again at the end.
  void _track(_RuntimeNode node) {
    if (node.collectionKeys.isEmpty) return;
    final before = node.witnesses;
    var next = const <DiCollectionKey<Object?>, ({DiKeyBase key, int index})>{};
    if (!node.removed && (!node.active || node.deactivating)) {
      final current = node.membershipVersion == _membershipVersion;
      if (!current) {
        node.membership.clear();
        node.membershipVersion = _membershipVersion;
      }
      next = <DiCollectionKey<Object?>, ({DiKeyBase key, int index})>{};
      for (final collection in node.collectionKeys) {
        final keys = node.membership[collection] ??= node.contributionKeysOf(
          collection,
        );
        final count = keys.length;
        // Without a position, the search starts at the last contribution:
        // members activate in declaration order when nothing else orders
        // them, so the last key resolves last.
        final start = (current ? before[collection]?.index : null) ?? count - 1;
        for (var step = 0; step < count; step++) {
          final index = (start - step) % count;
          if (node.resolve(keys[index]) == null) {
            next[collection] = (key: keys[index], index: index);
            break;
          }
        }
      }
    }
    // Only a key that changed leaves or enters the index.
    for (final MapEntry(key: collection, value: witness) in before.entries) {
      if (next[collection]?.key != witness.key) {
        _unindex(_waiters, witness.key, node);
      }
    }
    for (final MapEntry(key: collection, value: witness) in next.entries) {
      if (before[collection]?.key != witness.key) {
        (_waiters[witness.key] ??= <_RuntimeNode>{}).add(node);
      }
    }
    node.witnesses = next;
  }

  /// The `NodeState` of [node], computed from the fields of the node. See
  /// [coreNodeState] for [tracked].
  NodeState _stateOf(_RuntimeNode node, {bool tracked = false}) =>
      coreNodeState(node, tracked: tracked);

  /// Replaces the `NodeState` of [node] when its fields give another value.
  /// Returns whether it did.
  bool refresh(_RuntimeNode node) {
    _track(node);
    final next = _stateOf(node, tracked: true);
    if (next == node.state) return false;
    node.state = next;
    markChanged(node.scope);
    return true;
  }

  /// Records that the value of [scope] changed, so the next read builds the
  /// `ScopeState` of [scope] and of each ancestor again.
  void markChanged(_RuntimeScope scope) {
    for (
      _RuntimeScope? current = scope;
      current != null && !current.changed;
      current = current.parent
    ) {
      current.changed = true;
    }
  }

  /// The `ScopeState` of [scope]. It keeps the object of each scope whose
  /// nodes, children, and phase did not change.
  ScopeState stateOf(_RuntimeScope scope) {
    final held = scope.state;
    if (held != null && !scope.changed) return held;
    scope.changed = false;
    final childStates = [for (final child in scope.children) stateOf(child)];
    if (held != null &&
        held.phase == scope.phase &&
        held.nodeStates.length == scope.nodes.length &&
        held.childStates.length == childStates.length) {
      var same = true;
      for (var i = 0; same && i < childStates.length; i++) {
        same = identical(childStates[i], held.childStates[i]);
      }
      for (var i = 0; same && i < scope.nodes.length; i++) {
        same = identical(scope.nodes[i].state, held.nodeStates[i]);
      }
      if (same) return held;
    }
    return scope.state = createScopeState(
      phase: scope.phase,
      nodeStates: [for (final node in scope.nodes) node.state],
      childStates: childStates,
    );
  }

  /// The transition of [node]: refreshes its state, and the state of each
  /// node whose `missing` keys can change with [keys]. The keys are those
  /// that the transition made available or withdrew, or the keys of a node
  /// that the transition removed. [withdrawal] states that the keys do not
  /// resolve to [node] now. Calls the listeners when a state changed.
  void nodeTransition(
    _RuntimeNode node, {
    Iterable<DiKeyBase> keys = const [],
    bool withdrawal = false,
    bool silent = false,
  }) {
    var changed = refresh(node);
    // The fault leaves the waiting nodes as they were.
    if (!RuntimeFaults.breaks(RuntimeSelfCheckFault.stateCurrent)) {
      for (final key in keys) {
        // A refresh changes the waiters of a key, so the loop reads a copy.
        final affected = [...?_requirers[key], ...?_waiters[key]];
        for (final other in affected) {
          if (refresh(other)) changed = true;
        }
      }
      // A withdrawn contribution makes its collection key missing for a
      // strict reader. A reader that already waits for another contribution
      // of that collection does not change.
      final collection = withdrawal ? node.contributesTo : null;
      if (collection != null) {
        final readers = _collectionReaders[collection];
        if (readers != null) {
          for (final reader in readers) {
            if (reader.witnesses.containsKey(collection)) continue;
            if (refresh(reader)) changed = true;
          }
        }
      }
    }
    if (changed) _transition(silent: silent);
  }

  /// The transition of [scopes]: computes the phase of each, and calls the
  /// listeners when a phase changed. [disposed] is the scope that the
  /// transition disposed.
  void scopeTransition(
    Iterable<_RuntimeScope> scopes, {
    _RuntimeScope? disposed,
  }) {
    var changed = false;
    for (final scope in scopes) {
      final phase = scope.currentPhase;
      if (phase == scope.phase) continue;
      scope.phase = phase;
      markChanged(scope);
      changed = true;
    }
    if (changed) _transition(disposed: disposed);
  }

  /// Ends one transition after the state was replaced.
  void _transition({_RuntimeScope? disposed, bool silent = false}) {
    assert(
      RuntimeFaults.selfChecksMuted || _stateIsCurrent(),
      'SelfCheck StateCurrent: ${_stale()}',
    );
    changes.transition(disposed: disposed, silent: silent);
  }

  /// What differs between the state of the runtime and the fields of its
  /// nodes and scopes, or null: a node whose `NodeState` differs, a scope
  /// whose phase differs, or an index that holds an empty entry or a
  /// disposed node. Only the `StateCurrent` self-check calls it. A runtime
  /// of many nodes skips the check, because it reads every node at every
  /// transition.
  String? _stale() {
    if (nodes.length > 512) return null;
    for (final node in nodes) {
      if (_stateOf(node) != node.state) {
        return 'the state of ${node.label} differs from its fields';
      }
    }
    for (final scope in scopes) {
      if (scope._scope.currentPhase != scope._scope.phase) {
        return 'the phase of a scope differs from its fields';
      }
    }
    final indexes = <Map<Object, Set<_RuntimeNode>>>[
      _requirers,
      _collectionReaders,
      _waiters,
    ];
    for (final index in indexes) {
      for (final MapEntry(:key, value: indexed) in index.entries) {
        if (indexed.isEmpty) return 'an index holds no node for $key';
        for (final node in indexed) {
          if (node.removed) {
            return 'an index holds the disposed node ${node.label} for $key';
          }
        }
      }
    }
    return null;
  }

  /// [scope] and its descendants, parents first.
  List<_RuntimeScope> subtreeOf(_RuntimeScope scope) =>
      coreSubtree<_RuntimeScope, _RuntimePublisher, _RuntimeNode>(scope);

  /// The transition that creates the child scope [child].
  void childCreated(_RuntimeScope child) {
    child.phase = child.currentPhase;
    markChanged(child);
    _transition();
  }

  bool _stateIsCurrent() => _stale() == null;

  /// Runs [action] as one mutation. The `StateCurrent` self-check runs again
  /// at its end.
  Future<T> mutate<T>(String operation, Future<T> Function() action) =>
      mutations.run(operation, () async {
        try {
          return await action();
        } finally {
          assert(
            RuntimeFaults.selfChecksMuted || _stateIsCurrent(),
            'SelfCheck StateCurrent: at the end of $operation, ${_stale()}',
          );
        }
      });

  /// Whether the disposal of [node] or of its scope was requested, so that
  /// no setup starts. The defect `setupWhileHeld` ignores the request of the
  /// scope and keeps the request of the node.
  bool _setupRefused(_RuntimeNode node) =>
      RuntimeFaults.injects(RuntimeDefect.setupWhileHeld)
      ? node.disposeRequested
      : node.disposalRequested;

  /// Tries to activate [node] and tells what came of the attempt (see
  /// [CoreActivationOutcome]). A throw of the runtime itself still throws.
  ///
  /// The attempt has three steps. [_beginActivation] opens the episode,
  /// [_commitActivation] publishes it, and [_failActivation] ends it without
  /// a commit. Each step is the only writer of its node fields. Only the
  /// rollback of a failed activation waits here, between two of them.
  Future<CoreActivationOutcome> activate(_RuntimeNode node) async {
    if (node.removed) return const CoreNotStarted(CoreNotStartedReason.removed);
    if (node.active) return const CoreNotStarted(CoreNotStartedReason.active);
    if (node.scope.disposing) {
      return const CoreNotStarted(CoreNotStartedReason.scopeDisposing);
    }
    // Setup never starts for an owner whose disposal was requested.
    if (_setupRefused(node)) {
      return CoreInterrupted(
        CoreInterrupt(ActivationCanceledException(), StackTrace.current),
      );
    }
    // A component never runs against an unsatisfied environment, so
    // `Dependency.require` inside it cannot fail and no partial effect is ever
    // staged.
    if (!node.satisfied) {
      return const CoreNotStarted(CoreNotStartedReason.unsatisfied);
    }
    // A node whose reads a pending withdrawal removes waits for it.
    if (node.awaiting.isNotEmpty) {
      return const CoreNotStarted(CoreNotStartedReason.withdrawalPending);
    }
    final activation = _beginActivation(node);
    try {
      node.value = await node.run(activation);
      // A canceled activation never commits, even when its last step settled
      // after the cancellation.
      activation.checkpoint();
      _commitActivation(node, activation);
      return const CoreCommitted();
    } on Object catch (error, stackTrace) {
      // A step failure is local to this region: cancel its token before the
      // first dispose function, so a worker of a completed step can stop.
      final canceledBy = _cancelFailedActivation(node, activation);
      var rollback = activation.rollback;
      // The defect `DropLease` skips the release of the journal.
      if (!RuntimeFaults.injects(RuntimeDefect.dropLease)) {
        rollback = rollback.then(
          await runCleanups(
            activation.cleanups,
            '${node.label} activation rollback',
            episode: activation,
          ),
        );
      }
      return _failActivation(
        node,
        activation,
        error,
        stackTrace,
        canceledBy: canceledBy,
        rollback: rollback,
      );
    } finally {
      if (identical(node.inFlight, activation)) node.inFlight = null;
    }
  }

  /// Opens the activation episode of [node]. The only writer of the fields
  /// `inFlight` and `doomed` at the start of an activation.
  _RuntimeActivation _beginActivation(_RuntimeNode node) {
    final activation = _RuntimeActivation(this, node);
    node
      ..inFlight = activation
      ..doomed = false
      ..activationException = null;
    nodeTransition(node);
    return activation;
  }

  /// Publishes the staged values of [activation] and makes [node] active.
  /// The only writer of the committed fields of a node. Throws
  /// [DuplicateKeyError] before it writes anything.
  void _commitActivation(_RuntimeNode node, _RuntimeActivation activation) {
    final stagedKeys = <DiKeyBase>{};
    for (final publisher in activation.staged) {
      if (!stagedKeys.add(publisher.key) ||
          node.scope.bindings.containsKey(publisher.key)) {
        throw DuplicateKeyError(publisher.key);
      }
    }
    for (final publisher in activation.staged) {
      node.scope.bindings[publisher.key] = publisher;
      node.publishers.add(publisher);
    }
    commitDependencies(node, activation.dependencies);
    node
      ..cleanups = _RuntimeJournal.copyOf(activation.cleanups)
      ..committed = Map<DiKeyBase, _RuntimePublisher>.of(activation.committed)
      ..committedMembership = Map.of(activation.committedMembership)
      ..active = true
      ..reactivationBlocked = false
      ..commits += 1;
    // One transition: the keys resolve, and the node is active.
    nodeTransition(
      node,
      keys: [for (final publisher in activation.staged) publisher.key],
    );
    final waiters = node.activationWaiters?.values.toList();
    if (waiters != null) {
      node.activationWaiters = null;
      for (final waiter in waiters) {
        waiter.complete(node.value);
      }
    }
  }

  /// The first step of a failed activation: cancels the token, when no
  /// cancellation came first, and unlinks the reads. Returns the reason of
  /// the cancellation that came first, or null.
  CancelReason? _cancelFailedActivation(
    _RuntimeNode node,
    _RuntimeActivation activation,
  ) {
    final canceledBy = activation.token.reason;
    if (canceledBy == null) activation.token.cancel(CancelReason.failure);
    for (final dependency in activation.dependencies) {
      dependency.dependents.remove(node);
    }
    return canceledBy;
  }

  /// The last step of an activation that did not commit, after its journal
  /// was released. [rollback] holds the release failures of the rollback.
  /// The only writer of the fields of a node that a failed activation
  /// changes.
  CoreActivationOutcome _failActivation(
    _RuntimeNode node,
    _RuntimeActivation activation,
    Object error,
    StackTrace stackTrace, {
    required CancelReason? canceledBy,
    required CoreCause rollback,
  }) {
    node
      ..value = null
      ..active = false;
    // The fault publishes the staged values of the failed activation.
    if (RuntimeFaults.breaks(RuntimeSelfCheckFault.atomicPublication)) {
      for (final publisher in activation.staged) {
        node.scope.bindings[publisher.key] = publisher;
      }
    }
    assert(
      RuntimeFaults.selfChecksMuted ||
          activation.staged.every(
            (publisher) =>
                !identical(node.scope.bindings[publisher.key], publisher),
          ),
      'SelfCheck AtomicPublication: ${node.label} failed, and a staged '
      'publisher of it is in a scope binding',
    );
    // The defect `DropLate` drops the rollback failures of a canceled
    // activation.
    if (canceledBy != null && RuntimeFaults.injects(RuntimeDefect.dropLate)) {
      rollback = CoreCause.empty;
    }
    final rollbackFailures = rollback.disposeFailures;
    if (canceledBy == CancelReason.withdrawal && !node.disposalRequested) {
      // Not a failure: the node stays inactive and waits for the
      // withdrawal. Releases that failed during the rollback still count.
      _endActivation(node, activation, failed: false);
      changes.reportCause(rollback);
      return const CoreWithdrawn();
    }
    if (canceledBy != null) {
      _endActivation(node, activation, failed: true);
      final cause = error is ActivationCanceledException ? error.cause : error;
      return CoreInterrupted(
        CoreInterrupt(
          ActivationCanceledException(
            cause: cause,
            stackTrace: cause == null ? null : stackTrace,
            rollbackFailures: rollbackFailures,
          ),
          StackTrace.current,
        ),
      );
    }
    // A canceled activation is not a failure, so only this path records
    // one. The record keeps the cause and its stack trace for
    // `ComponentNode.activationException`.
    if ((error is DiError || error is DiException) &&
        rollbackFailures.isEmpty) {
      node.activationException = error is ActivationException
          ? error
          : ActivationException(error, stackTrace);
      _endActivation(node, activation, failed: true);
      return CoreFailed(CoreFail(error, stackTrace));
    }
    final failure = ActivationException(error, stackTrace, rollbackFailures);
    node.activationException = failure;
    _endActivation(node, activation, failed: true);
    return CoreFailed(CoreFail(failure, StackTrace.current));
  }

  /// The activation ended without a commit. A member of a running
  /// `initialize` whose activation failed keeps the phase `activating`: the
  /// rollback of that call disposes it.
  void _endActivation(
    _RuntimeNode node,
    _RuntimeActivation activation, {
    required bool failed,
  }) {
    if (identical(node.inFlight, activation)) node.inFlight = null;
    if (failed && !node.scope.initialized) node.doomed = true;
    nodeTransition(node);
  }

  /// Cancels the activations in flight in [scope] and its descendants, at
  /// the `dispose` call and before its mutation reaches the queue.
  void requestScopeDisposal(_RuntimeScope scope) {
    scope.requestDisposal();
    for (final node in nodes) {
      if (node.scope.disposalRequested) {
        node.inFlight?.token.cancel(CancelReason.owner);
      }
    }
  }

  /// The open holds of [scope] and of its descendants.
  int subtreeHolds(_RuntimeScope scope) => coreSubtreeHolds(scope);

  /// The state of each open hold of [scope] and of its descendants.
  List<HoldState> holdStatesOf(_RuntimeScope scope) => [
    for (final current in subtreeOf(scope))
      for (final hold in current.holds) hold.stateIn(pathOf(current)),
  ];

  /// [scope] as `describe` of its root names it.
  String pathOf(_RuntimeScope scope) => corePathOf(scope);

  /// A hold of [scope] closed. Queues each waiting disposal of [scope] or of
  /// an ancestor whose subtree has no open hold any more.
  void holdClosed(_RuntimeScope scope) {
    for (
      _RuntimeScope? current = scope;
      current != null;
      current = current.parent
    ) {
      final parked = current.parked;
      if (parked != null && subtreeHolds(current) == 0) parked.queue();
    }
  }

  /// Cancels the activation of [node] in flight, at the `dispose` call.
  void requestNodeDisposal(_RuntimeNode node) {
    node.disposeRequested = true;
    node.inFlight?.token.cancel(CancelReason.owner);
    _requestWithdrawal(node);
  }

  /// The withdrawals requested and not yet finished: the disposed node, and
  /// every node that its withdrawal deactivates.
  final List<_RuntimeWithdrawal> pendingWithdrawals = [];

  /// Records the withdrawal of [root] and cancels the activations in flight
  /// that read a value it withdraws, at the `dispose` call.
  void _requestWithdrawal(_RuntimeNode root) {
    final reach =
        coreWithdrawalReach<_RuntimeScope, _RuntimePublisher, _RuntimeNode>(
          root,
        );
    pendingWithdrawals.add(_RuntimeWithdrawal(root, reach));
    for (final node in nodes) {
      final activation = node.inFlight;
      if (activation == null || node.disposalRequested) continue;
      if (_readsAny(node, activation, reach)) {
        activation.cancelForWithdrawal();
      }
    }
  }

  /// Whether the activation of [node] read, or will read by its shape, a
  /// value that a node in [reach] publishes.
  bool _readsAny(
    _RuntimeNode node,
    _RuntimeActivation activation,
    Set<_RuntimeNode> reach,
  ) => coreReadsOwner(node, activation.dependencies, reach.contains);

  /// The pending withdrawals that withdraw [publisher], or none.
  Iterable<_RuntimeNode> withdrawalsOf(_RuntimePublisher publisher) => [
    for (final pending in pendingWithdrawals)
      if (pending.reaches(publisher.owner)) pending.root,
  ];

  /// The withdrawal of [root] finished: nodes that waited for it may
  /// activate again in the next reconciliation.
  void finishWithdrawal(_RuntimeNode root) {
    pendingWithdrawals.removeWhere((pending) => identical(pending.root, root));
    for (final node in nodes) {
      node.awaiting.remove(root);
    }
  }

  /// Activates the member [nodes] of [module] by dependency.
  ///
  /// A member waits for the members that publish a key it reads. A
  /// prerequisite is settled when its activation
  /// returns, committed or dormant. A dormant publisher cannot block a
  /// dependent, which then stays dormant itself. A cycle among members
  /// leaves no member ready, so the runtime starts the first unstarted member
  /// in creation order, as a sequential initialization would.
  ///
  /// After a failure no further member starts. The method returns only after
  /// every started activation has settled, because a late commit into a
  /// disposed node would leak its bindings. It then returns the causes of
  /// the members in declaration order, so the first failure of the cause is
  /// the failure of the failed member that is first in creation order.
  Future<CoreCause> activateMembers(List<_RuntimeNode> nodes) async {
    final count = nodes.length;
    final (:waitingFor, :dependents) = coreActivationPlan(nodes);

    final started = List<bool>.filled(count, false);
    final ready = SplayTreeSet<int>()
      ..addAll([
        for (var i = 0; i < count; i++)
          if (waitingFor[i] == 0) i,
      ]);
    final causes = List<CoreCause>.filled(count, CoreCause.empty);
    var failed = false;
    final finished = Completer<void>();
    var inFlight = 0;
    var unstarted = count;

    late final void Function() pump;

    void settle(int index) {
      for (final dependent in dependents[index]) {
        if (started[dependent]) continue;
        if (--waitingFor[dependent] == 0) ready.add(dependent);
      }
    }

    void start(int index) {
      started[index] = true;
      inFlight++;
      unstarted--;
      unawaited(() async {
        try {
          switch (await activate(nodes[index])) {
            case CoreInterrupted(:final interrupt):
              causes[index] = interrupt;
              failed = true;
            case CoreFailed(:final failure):
              causes[index] = failure;
              failed = true;
            // A member that did not commit, and did not fail, stops no one.
            case CoreCommitted() || CoreNotStarted() || CoreWithdrawn():
              break;
          }
        } on Object catch (error, stackTrace) {
          // A throw of the runtime itself fails the member.
          causes[index] = CoreFail(error, stackTrace);
          failed = true;
        }
        inFlight--;
        settle(index);
        pump();
      }());
    }

    pump = () {
      if (!failed) {
        while (ready.isNotEmpty) {
          final index = ready.first;
          ready.remove(index);
          start(index);
        }
        if (inFlight == 0 && unstarted > 0) {
          start(started.indexOf(false));
        }
      }
      if (inFlight == 0 && (failed || unstarted == 0)) {
        if (!finished.isCompleted) finished.complete();
      }
    };

    pump();
    await finished.future;
    return CoreCause.all(causes);
  }

  /// Deactivates [node], after its live dependents, and returns the dispose
  /// failures of the dependents, then those of the node.
  Future<CoreCause> deactivate(
    _RuntimeNode node, {
    required bool permanent,
  }) async {
    if (node.removed) return CoreCause.empty;
    if (!node.active || node.deactivating) {
      if (permanent && !node.deactivating) {
        removeNode(node);
        // A removed contributor leaves its collection.
        nodeTransition(node, keys: node.declaredPublishes);
      }
      return CoreCause.empty;
    }

    _beginRelease(node);

    final orderedDependents = coreDependentsOf(node);

    // Dependent failures are reported to the caller but must not be charged
    // to this node: only its own dispose functions can leave *its* effects
    // half released, and only that justifies blocking its reactivation.
    var dependentCause = CoreCause.empty;
    // The fault skips the release of the dependents.
    if (!RuntimeFaults.breaks(RuntimeSelfCheckFault.dependentFirst)) {
      for (final dependent in orderedDependents) {
        dependentCause = dependentCause.then(
          await deactivate(dependent, permanent: false),
        );
      }
    }

    assert(() {
      if (RuntimeFaults.selfChecksMuted) return true;
      for (final publisher in node.publishers) {
        for (final dependent in publisher.dependents) {
          if (identical(dependent, node)) continue;
          if (!dependent.active && !dependent.deactivating) continue;
          // In a read cycle each node is a dependent of the next, so the
          // fallback of the teardown releases them in a ring.
          if (_path(node, dependent) != null) continue;
          throw AssertionError(
            'SelfCheck DependentFirst: ${node.label} starts its release '
            'while its dependent ${dependent.label} is still '
            '${dependent.deactivating ? 'releasing' : 'active'}',
          );
        }
      }
      return true;
    }());

    node.activationContext?.tearingDown = true;
    final ownCause = await runCleanups(
      node.cleanups,
      node.label,
      episode: node.activationContext,
    );

    _endRelease(node, ownCause, permanent: permanent);
    return dependentCause.then(ownCause);
  }

  /// Starts the release of [node]: marks it as deactivating and withdraws its
  /// publishers. [_endRelease] ends the release. The two methods are the only
  /// writers of `deactivating`.
  void _beginRelease(_RuntimeNode node) {
    node.deactivating = true;
    // The token of an activation lives as long as the activation.
    node.activationContext?.token.cancel(CancelReason.deactivation);

    // Leave the publisher set before waiting on dependents. Their releases
    // run first, while this node's values are still alive.
    final withdrawn = <DiKeyBase>[];
    for (final publisher in node.publishers) {
      if (publisher.available) {
        publisher.available = false;
        withdrawn.add(publisher.key);
      }
    }
    // One transition: the keys do not resolve to the node, and its release
    // runs. The defect `SilentReleaseStart` calls no listener for it.
    nodeTransition(
      node,
      keys: withdrawn,
      withdrawal: true,
      silent: RuntimeFaults.injects(RuntimeDefect.silentReleaseStart),
    );
  }

  /// Ends the release of [node], after its journal ran. [ownCause] holds the
  /// dispose failures of the node. A permanent release removes the node. The
  /// only writer of the fields that a release clears.
  void _endRelease(
    _RuntimeNode node,
    CoreCause ownCause, {
    required bool permanent,
  }) {
    for (final publisher in node.publishers) {
      if (identical(node.scope.bindings[publisher.key], publisher)) {
        node.scope.bindings.remove(publisher.key);
      }
      publisher.dependents.clear();
    }
    for (final dependency in node.dependencies) {
      dependency.dependents.remove(node);
    }
    clearDependencies(node);
    node
      ..publishers.clear()
      ..committed.clear()
      ..committedMembership.clear()
      ..cleanups.clear()
      ..value = null
      ..active = false
      ..reactivationBlocked = !ownCause.isEmpty
      ..deactivating = false
      ..activationContext = null;
    // One transition for the end of the release, also when it removes the
    // node. A removed contributor leaves its collection.
    if (permanent) removeNode(node);
    nodeTransition(
      node,
      keys: permanent ? node.declaredPublishes : const <DiKeyBase>[],
    );
  }

  /// Brings every node to its target: rebuilds active nodes whose resolved
  /// publishers changed, then activates eligible dormant nodes, and repeats
  /// while an activation of this pass changed the target of an active node.
  ///
  /// An automatic activation failure is reported through [errors]. A failure
  /// of a node in [sink] goes to the sink instead, so its caller can decide.
  ///
  /// An acyclic read graph settles within one pass per node. Optional reads
  /// that feed back into each other may not settle, so the runtime stops
  /// after `nodes.length + 1` passes with a [DependencyCycleError.unsettled]
  /// of the nodes that are still stale. When one of them is in [sink], the
  /// error goes to the sink, so `initialize` fails and rolls back; otherwise
  /// it is reported through [errors], wrapped in an [ActivationException].
  Future<void> reconcile({_RuntimeFailureSink? sink}) async {
    final failed = <_RuntimeNode>{};
    final limit = nodes.length + 1;
    for (var pass = 1; ; pass++) {
      await _rebuildChanged();
      await _activateDormant(failed, sink);
      final stale = [
        for (final node in nodes)
          if (!node.removed && node.active && _targetChanged(node)) node,
      ];
      if (stale.isEmpty) return;
      if (pass >= limit) {
        final error = DependencyCycleError.unsettled([
          for (final node in stale) node.label,
        ], pass);
        final own = sink == null
            ? const <_RuntimeNode>[]
            : [
                for (final node in stale)
                  if (sink.members.contains(node)) node,
              ];
        if (own.isNotEmpty) {
          sink!.failures[own.first] = CoreFail(error, StackTrace.current);
        } else {
          changes.reportCause(CoreFail(error, StackTrace.current));
        }
        return;
      }
    }
  }

  Future<void> _rebuildChanged() async {
    final active = nodes.where((node) => !node.removed && node.active).toList()
      ..sort((left, right) => right.id.compareTo(left.id));
    for (final node in active) {
      if (_targetChanged(node)) {
        changes.reportCause(await deactivate(node, permanent: false));
      }
    }
  }

  Future<void> _activateDormant(
    Set<_RuntimeNode> failed,
    _RuntimeFailureSink? sink,
  ) async {
    var progressed = true;
    while (progressed) {
      progressed = false;
      final dormant =
          nodes
              .where(
                (node) =>
                    !node.removed &&
                    !node.active &&
                    !node.reactivationBlocked &&
                    !node.scope.disposed &&
                    !node.scope.disposing &&
                    !_setupRefused(node) &&
                    node.awaiting.isEmpty &&
                    !failed.contains(node) &&
                    node.satisfied,
              )
              .toList()
            ..sort((left, right) => left.id.compareTo(right.id));
      for (final node in dormant) {
        final CoreCause cause;
        switch (await activate(node)) {
          // The pass made no failure, so it can make more nodes ready. A node
          // that did not start, or that waits for a withdrawal, counts too.
          case CoreCommitted() || CoreNotStarted() || CoreWithdrawn():
            progressed = true;
            continue;
          case CoreInterrupted(:final interrupt):
            cause = interrupt;
          case CoreFailed(:final failure):
            cause = failure;
        }
        failed.add(node);
        if (sink != null && sink.members.contains(node)) {
          sink.failures[node] = cause;
        } else {
          // A canceled activation is not a failure; its owner is going
          // away, but releases that failed during its rollback still count.
          // A wiring error that no caller receives is reported as the
          // failed activation that it caused.
          changes.reportCause(cause);
        }
      }
    }
  }

  bool _targetChanged(_RuntimeNode node) => coreTargetChanged(node);

  /// Releases [owned], ordered by descending id, along the reverse of their
  /// committed read graph, through `RuntimeTeardownScheduler`
  /// (runtime_teardown.dart, Teardown.tla).
  ///
  /// A node starts once every node that read one of its values has finished
  /// its release, so it releases while the values it read are alive. Nodes
  /// that do not wait for each other release at the same time; the dispose
  /// functions of one node still run one after another, last first. A reader
  /// of a disposed node lives in the same scope or a descendant, so every
  /// dependent is in [owned].
  ///
  /// A read cycle leaves no node ready. Then the highest unstarted node
  /// starts alone, and its `deactivate` releases its live dependents depth
  /// first, as a sequential teardown does.
  ///
  /// The method returns after every started release has settled. The
  /// dispose failures follow descending node order, whatever order the
  /// releases finished in.
  /// Inside the cycle fallback, the dependents that a `deactivate` released
  /// report with that node, in its depth-first order.
  Future<CoreCause> _releaseOwned(List<_RuntimeNode> owned) =>
      RuntimeTeardownScheduler<_RuntimeNode>(
        // A dependent is done when it is neither active nor releasing. A
        // finished dependent also leaves the publisher's dependents.
        ready: coreReleaseReady,
        release: (node) => deactivate(node, permanent: true),
        // A node is a dependent of a publisher through a read of its
        // committed activation or of its running activation.
        reads: (node) => {
          for (final publisher in node.dependencies) publisher.owner,
          for (final activation in [node.activationContext, node.inFlight])
            for (final publisher
                in activation?.dependencies ?? const <_RuntimePublisher>{})
              publisher.owner,
        },
      ).releaseAlongReads(owned);

  /// [started] runs after the transition that starts the disposal, while
  /// the error stream of the root is still open.
  Future<CoreCause> disposeScope(
    _RuntimeScope scope, {
    void Function()? started,
  }) async {
    final subtree = <_RuntimeScope>[];
    void collect(_RuntimeScope current) {
      current.markDisposing();
      subtree.add(current);
      for (final child in current.children) {
        collect(child);
      }
    }

    collect(scope);
    scopeTransition(subtree);
    started?.call();
    final included = subtree.toSet();
    final ownedNodes =
        nodes.where((node) => included.contains(node.scope)).toList()
          ..sort((left, right) => right.id.compareTo(left.id));
    final released = await _releaseOwned(ownedNodes);
    // A release that threw leaves the disposal half done: the scopes stay
    // as they are, and the error stream stays open.
    if (released.firstFail case final thrown?) {
      Error.throwWithStackTrace(thrown.error, thrown.stackTrace);
    }

    for (final current in subtree.reversed) {
      current.bindings.clear();
      current.markDisposed();
      current.parent?.children.remove(current);
      final public = current.public;
      if (public != null) scopes.remove(public);
      // The listeners of the scope are called for this transition and then
      // leave.
      scopeTransition([current], disposed: current);
    }
    if (scope.parent == null) await changes.errors.close();
    assert(() {
      if (scope.parent == null) _RuntimeInspector.rootDisposed(this);
      return true;
    }());
    return released;
  }

  /// The owners whose cleanups run now, in the order they started, for a
  /// slow-mutation report. Members roll back concurrently, so more than one
  /// owner can release at a time.
  final List<String> _releasing = [];

  /// Releases the journal [cleanups] of [owner], last entry first. [episode]
  /// is the activation that owns the journal, or null.
  Future<CoreCause> runCleanups(
    _RuntimeJournal cleanups,
    String owner, {
    _RuntimeActivation? episode,
  }) async {
    var failures = CoreCause.empty;
    // A dispose function that threw is a [CoreDie]. A [DisposeException]
    // expands to its failures.
    void record(Object error, StackTrace stackTrace) {
      failures = failures.then(
        error is DisposeException
            ? CoreCause.dying(error.disposeFailures)
            : CoreDie(DisposeFailure(owner, error, stackTrace)),
      );
    }

    // The fault runs the journal a second time.
    final passes = RuntimeFaults.breaks(RuntimeSelfCheckFault.releaseAtMostOnce)
        ? 2
        : 1;
    // The defect `AcqOrder` releases the journal first entry first.
    final ordered = RuntimeFaults.injects(RuntimeDefect.acqOrder)
        ? cleanups.lastFirst.toList().reversed
        : cleanups.lastFirst;
    Future<void> release(DisposeFunction cleanup) async {
      try {
        await cleanup();
      } on Object catch (error, stackTrace) {
        record(error, stackTrace);
      }
    }

    _releasing.add(owner);
    try {
      for (var pass = 0; pass < passes; pass++) {
        var position = 0;
        final started = <Future<void>>[];
        for (final cleanup in ordered) {
          assert(
            RuntimeFaults.selfChecksMuted || _startRelease(episode, position++),
            'SelfCheck ReleaseAtMostOnce: $owner starts the release of '
            'journal entry ${position - 1} a second time',
          );
          // The defect `ParallelSteps` starts every entry before it awaits one.
          if (RuntimeFaults.injects(RuntimeDefect.parallelSteps)) {
            started.add(release(cleanup));
            continue;
          }
          try {
            await cleanup();
          } on Object catch (error, stackTrace) {
            record(error, stackTrace);
          }
        }
        if (started.isNotEmpty) await Future.wait(started);
      }
    } finally {
      _releasing.removeAt(_releasing.lastIndexOf(owner));
    }
    return failures;
  }

  void addDependency(
    _RuntimeNode node,
    _RuntimePublisher publisher,
    _RuntimeActivation activation,
  ) {
    final owner = publisher.owner;
    if (identical(owner, node)) {
      throw DependencyCycleError([node.label, node.label]);
    }
    // The walk reaches [node] only through a committed dependency that
    // [node] owns, so it cannot find a cycle while no node reads a value of
    // [node] (R-UC-RT-LC-023).
    if (node.committedReaders > 0) {
      final path = _path(owner, node);
      if (path != null) {
        throw DependencyCycleError([
          node.label,
          ...path.map((item) => item.label),
        ]);
      }
    }
    activation.dependencies.add(publisher);
    activation.committed[publisher.key] = publisher;
    publisher.dependents.add(node);
  }

  /// Makes [reads] the committed dependencies of [node], and counts them for
  /// the owners of the publishers.
  void commitDependencies(_RuntimeNode node, Set<_RuntimePublisher> reads) {
    clearDependencies(node);
    node.dependencies = Set<_RuntimePublisher>.of(reads);
    for (final publisher in node.dependencies) {
      publisher.owner.committedReaders++;
    }
  }

  /// Removes the committed dependencies of [node] and their counts.
  void clearDependencies(_RuntimeNode node) {
    for (final publisher in node.dependencies) {
      publisher.owner.committedReaders--;
    }
    node.dependencies.clear();
  }

  /// The path of committed reads from [from] to [target], or null.
  List<_RuntimeNode>? _path(_RuntimeNode from, _RuntimeNode target) =>
      corePath<_RuntimeScope, _RuntimePublisher, _RuntimeNode>(
        from,
        target,
        <_RuntimeNode>{},
      );
}

/// Collects the reconciliation failures of selected nodes.
///
/// `initialize` uses it to fail for its own members while other
/// nodes keep the reporting rules of reconciliation.
final class _RuntimeFailureSink {
  _RuntimeFailureSink(this.members);

  final Set<_RuntimeNode> members;
  final Map<_RuntimeNode, CoreCause> failures = {};
}
