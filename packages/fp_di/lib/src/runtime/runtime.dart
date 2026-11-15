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

  /// The rollback failures that [error] carries.
  static List<DisposeFailure> disposeFailuresOf(Object error) =>
      switch (error) {
        ActivationException(:final rollbackFailures) => rollbackFailures,
        ActivationCanceledException(:final rollbackFailures) =>
          rollbackFailures,
        _ => const <DisposeFailure>[],
      };

  /// [error] with [extra] rollback failures attached, keeping its kind.
  static Object withDisposeFailures(
    Object error,
    StackTrace stackTrace,
    List<DisposeFailure> extra,
  ) {
    if (extra.isEmpty) return error;
    return switch (error) {
      ActivationException() => ActivationException(
        error.cause,
        error.stackTrace,
        <DisposeFailure>[...error.rollbackFailures, ...extra],
      ),
      ActivationCanceledException() => ActivationCanceledException(
        cause: error.cause,
        stackTrace: error.stackTrace,
        rollbackFailures: <DisposeFailure>[...error.rollbackFailures, ...extra],
      ),
      _ => ActivationException(error, stackTrace, extra),
    };
  }

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
  _RuntimeNode? nodeOf(_RuntimeScope scope, DiKeyBase key) {
    if (!scope.declared.publishes.contains(key)) return null;
    return _declaredNode(scope, key);
  }

  /// The node of [scope] whose component publishes [key] or has the
  /// internal contribution key [key], or null.
  _RuntimeNode? _declaredNode(_RuntimeScope scope, DiKeyBase key) {
    if (scope.nodes.isEmpty) return null;
    final index = scope.declarationIndexes[key];
    if (index == null) return null;
    final node = scope.nodes[index];
    return node.removed ? null : node;
  }

  /// The nearest node, other than [reader], that publishes [key] or has
  /// the contribution key [key], from the scope of [reader] to the root.
  _RuntimeNode? _nodeBehind(_RuntimeNode reader, DiKeyBase key) {
    for (
      _RuntimeScope? scope = reader.scope;
      scope != null;
      scope = scope.parent
    ) {
      final node = _declaredNode(scope, key);
      if (node != null && !identical(node, reader)) return node;
    }
    return null;
  }

  /// The error of a `Scope.get` call for [key] from [scope], when the key
  /// has no value (specs/runtime/lifecycle, "The cause of an unavailable
  /// key").
  ///
  /// The search starts at the node that `findNode` returns. A failed node
  /// ends its path. A waiting node continues at the nodes of its missing
  /// keys: the nearest node of a required key, and each contributing node
  /// of a collection key whose contribution does not resolve. The search
  /// is depth-first, visits each node one time, and changes no state.
  UnavailableKeyException unavailable(_RuntimeScope scope, DiKey<Object?> key) {
    _RuntimeNode? first;
    var declaredOnly = false;
    for (_RuntimeScope? s = scope; s != null; s = s.parent) {
      first = nodeOf(s, key);
      if (first != null) break;
      declaredOnly |=
          s.phase == ScopePhase.declared && s.declared.publishes.contains(key);
    }
    if (first == null) {
      return UnavailableKeyException(
        key,
        message: declaredOnly
            ? 'No node publishes $key: a scope declares the key and is not '
                  'initialized.'
            : 'No node publishes $key.',
      );
    }

    final failed = <NodeState>[];
    final seen = <_RuntimeNode>{};
    final pending = <_RuntimeNode>[first];
    while (pending.isNotEmpty) {
      final node = pending.removeLast();
      if (!seen.add(node)) continue;
      final state = node.state;
      if (state.phase == NodePhase.activationFailed) {
        failed.add(state);
        continue;
      }
      if (state.phase != NodePhase.waiting) continue;
      final next = <_RuntimeNode>[];
      for (final missing in state.missing) {
        if (missing is DiCollectionKey<Object?>) {
          for (final contribution in node.contributionKeysOf(missing)) {
            if (node.resolve(contribution) != null) continue;
            if (_nodeBehind(node, contribution) case final behind?) {
              next.add(behind);
            }
          }
        } else if (_nodeBehind(node, missing) case final behind?) {
          next.add(behind);
        }
      }
      // The last node of the stack is the next one, so the first node
      // behind this node goes on last.
      pending.addAll(next.reversed);
    }

    final state = first.state;
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
      buffer.write(': ${cause.activationException!.cause}');
    }
    return UnavailableKeyException(
      key,
      message: buffer.toString(),
      // The defect drops the failed nodes and keeps the message.
      failedNodeStates: RuntimeFaults.injects(RuntimeDefect.dropFailedNodes)
          ? const <NodeState>[]
          : List<NodeState>.unmodifiable(failed),
    );
  }

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
  ///
  /// `active` is before `activating`, because a listener runs at the commit,
  /// before the activation leaves `inFlight`. `inactive` is the word for a
  /// node that is not active when no narrower word applies, such as a node
  /// whose activation was canceled and that waits for a withdrawal or its
  /// removal.
  NodePhase phaseOf(_RuntimeNode node) {
    if (node.removed) return NodePhase.disposed;
    if (node.active && !node.deactivating) return NodePhase.active;
    return _phaseOf(node, waits: node.unmet.isNotEmpty);
  }

  /// The phase of a node that is neither disposed nor active. [waits] states
  /// that a required key of the node does not resolve.
  static NodePhase _phaseOf(_RuntimeNode node, {required bool waits}) {
    if (node.deactivating) return NodePhase.deactivating;
    if (node.inFlight != null || node.doomed) return NodePhase.activating;
    if (node.reactivationBlocked) return NodePhase.disposeFailed;
    if (waits) return NodePhase.waiting;
    if (node.activationException != null) return NodePhase.activationFailed;
    return NodePhase.inactive;
  }

  /// The word of `Scope.describe` for [phase].
  static String stateWord(NodePhase phase) => switch (phase) {
    NodePhase.active => 'active',
    NodePhase.activating => 'activating',
    NodePhase.deactivating => 'deactivating',
    NodePhase.waiting => 'waiting',
    NodePhase.activationFailed => 'activation failed',
    NodePhase.disposeFailed => 'dispose failed',
    NodePhase.inactive => 'inactive',
    NodePhase.disposed => 'disposed',
  };

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

  /// The `NodeState` of [node], computed from the fields of the node.
  ///
  /// With [tracked], the missing collection keys are those of
  /// `_RuntimeNode.witnesses`, which `_track` has just written. Without it,
  /// the method reads every contribution key again, as the `StateCurrent`
  /// self-check needs.
  NodeState _stateOf(_RuntimeNode node, {bool tracked = false}) {
    var missing = const <DiKeyBase>[];
    final NodePhase phase;
    if (node.removed) {
      phase = NodePhase.disposed;
    } else if (node.active && !node.deactivating) {
      phase = NodePhase.active;
    } else {
      missing = tracked
          ? [
              for (final key in node.declaredRequires)
                if (node.resolve(key) == null) key,
              for (final key in node.collectionKeys)
                if (node.witnesses.containsKey(key)) key,
            ]
          : node.unmet;
      phase = _phaseOf(node, waits: missing.isNotEmpty);
    }
    return createNodeState(
      id: node.id,
      label: node.label,
      key: node.publicKey,
      phase: phase,
      missing: missing,
      activationException: phase == NodePhase.activationFailed
          ? node.activationException
          : null,
      commits: node.commits,
    );
  }

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
  List<_RuntimeScope> subtreeOf(_RuntimeScope scope) {
    final subtree = <_RuntimeScope>[];
    void collect(_RuntimeScope current) {
      subtree.add(current);
      current.children.forEach(collect);
    }

    collect(scope);
    return subtree;
  }

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

  Future<void> activate(_RuntimeNode node) async {
    if (node.removed || node.active || node.scope.disposing) return;
    // Setup never starts for an owner whose disposal was requested.
    if (node.disposalRequested) throw ActivationCanceledException();
    // A component never runs against an unsatisfied environment, so
    // `Dependency.require` inside it cannot fail and no partial effect is ever
    // staged.
    if (!node.satisfied) return;
    // A node whose reads a pending withdrawal removes waits for it.
    if (node.awaiting.isNotEmpty) return;
    final activation = _RuntimeContext(this, node);
    node
      ..inFlight = activation
      ..doomed = false
      ..activationException = null;
    nodeTransition(node);
    try {
      node.value = await node.run(activation);
      // A canceled activation never commits, even when its last step settled
      // after the cancellation.
      activation.checkpoint();
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
        ..cleanups = List<DisposeFunction>.of(activation.cleanups)
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
    } on Object catch (error, stackTrace) {
      // A step failure is local to this region: cancel its token before the
      // first dispose function, so a worker of a completed step can stop.
      final canceledBy = activation.token.reason;
      if (canceledBy == null) activation.token.cancel(CancelReason.failure);
      for (final dependency in activation.dependencies) {
        dependency.dependents.remove(node);
      }
      final rollbackFailures = <DisposeFailure>[
        ...activation.rollbackFailures,
        // The defect `DropLease` skips the release of the journal.
        if (!RuntimeFaults.injects(RuntimeDefect.dropLease))
          ...await runCleanups(
            activation.cleanups.reversed,
            '${node.label} activation rollback',
            episode: activation,
          ),
      ];
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
        rollbackFailures.clear();
      }
      // The activation ended without a commit. A member of a running
      // `initialize` whose activation failed keeps the phase `activating`:
      // the rollback of that call disposes it.
      void end({required bool failed}) {
        if (identical(node.inFlight, activation)) node.inFlight = null;
        if (failed && !node.scope.initialized) node.doomed = true;
        nodeTransition(node);
      }

      if (canceledBy == CancelReason.withdrawal && !node.disposalRequested) {
        // Not a failure: the node stays inactive and waits for the
        // withdrawal. Releases that failed during the rollback still count.
        end(failed: false);
        if (rollbackFailures.isNotEmpty) {
          changes.report(DisposeException(rollbackFailures));
        }
        return;
      }
      if (canceledBy != null) {
        end(failed: true);
        final cause = error is ActivationCanceledException
            ? error.cause
            : error;
        throw ActivationCanceledException(
          cause: cause,
          stackTrace: cause == null ? null : stackTrace,
          rollbackFailures: rollbackFailures,
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
        end(failed: true);
        Error.throwWithStackTrace(error, stackTrace);
      }
      final failure = ActivationException(error, stackTrace, rollbackFailures);
      node.activationException = failure;
      end(failed: true);
      throw failure;
    } finally {
      if (identical(node.inFlight, activation)) node.inFlight = null;
    }
  }

  /// Cancels the activations in flight in [scope] and its descendants, at
  /// the `dispose` call and before its mutation reaches the queue.
  void requestScopeDisposal(_RuntimeScope scope) {
    scope.disposeRequested = true;
    for (final node in nodes) {
      if (node.scope.disposalRequested) {
        node.inFlight?.token.cancel(CancelReason.owner);
      }
    }
  }

  /// The open holds of [scope] and of its descendants.
  int subtreeHolds(_RuntimeScope scope) {
    var count = scope.holds.length;
    for (final child in scope.children) {
      count += subtreeHolds(child);
    }
    return count;
  }

  /// The state of each open hold of [scope] and of its descendants.
  List<HoldState> holdStatesOf(_RuntimeScope scope) => [
    for (final current in subtreeOf(scope))
      for (final hold in current.holds) hold.stateIn(pathOf(current)),
  ];

  /// [scope] as `describe` of its root names it.
  String pathOf(_RuntimeScope scope) {
    final indexes = <int>[];
    for (
      var current = scope;
      current.parent != null;
      current = current.parent!
    ) {
      indexes.add(current.parent!.children.toList().indexOf(current) + 1);
    }
    if (indexes.isEmpty) return 'scope';
    return 'child scope ${indexes.reversed.join('.')}';
  }

  /// A hold of [scope] closed. Queues each waiting disposal of [scope] or of
  /// an ancestor whose subtree has no open hold any more.
  void holdClosed(_RuntimeScope scope) {
    for (
      _RuntimeScope? current = scope;
      current != null;
      current = current.parent
    ) {
      final queue = current.queueDisposal;
      if (queue != null && subtreeHolds(current) == 0) queue();
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
  final List<({_RuntimeNode root, Set<_RuntimeNode> reach})>
  pendingWithdrawals = [];

  /// Records the withdrawal of [root] and cancels the activations in flight
  /// that read a value it withdraws, at the `dispose` call.
  void _requestWithdrawal(_RuntimeNode root) {
    final reach = <_RuntimeNode>{root};
    final queue = <_RuntimeNode>[root];
    while (queue.isNotEmpty) {
      final next = queue.removeLast();
      for (final publisher in next.publishers) {
        for (final dependent in publisher.dependents) {
          if (dependent.active && reach.add(dependent)) queue.add(dependent);
        }
      }
    }
    pendingWithdrawals.add((root: root, reach: reach));
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
    _RuntimeContext activation,
    Set<_RuntimeNode> reach,
  ) {
    for (final publisher in activation.dependencies) {
      if (reach.contains(publisher.owner)) return true;
    }
    for (final key in node.plainReads) {
      final publisher = node.resolve(key);
      if (publisher != null && reach.contains(publisher.owner)) return true;
    }
    return false;
  }

  /// The pending withdrawals that withdraw [publisher], or none.
  Iterable<_RuntimeNode> withdrawalsOf(_RuntimePublisher publisher) => [
    for (final pending in pendingWithdrawals)
      if (pending.reach.contains(publisher.owner)) pending.root,
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
  /// disposed node would leak its bindings. It then throws the failure of
  /// the failed member that is first in creation order.
  Future<void> activateMembers(List<_RuntimeNode> nodes) async {
    final count = nodes.length;
    // `initialize` has rejected duplicate keys, so each key has one member.
    final publisherOf = <DiKeyBase, int>{
      for (var i = 0; i < count; i++)
        for (final key in nodes[i].declaredPublishes) key: i,
    };
    final waitingFor = List<int>.filled(count, 0);
    final dependents = List<List<int>>.generate(count, (_) => <int>[]);
    for (var i = 0; i < count; i++) {
      final prerequisites = <int>{
        for (final key in nodes[i].plainReads)
          if (publisherOf[key] case final publisher? when publisher != i)
            publisher,
      };
      waitingFor[i] = prerequisites.length;
      for (final prerequisite in prerequisites) {
        dependents[prerequisite].add(i);
      }
    }

    final started = List<bool>.filled(count, false);
    final ready = SplayTreeSet<int>()
      ..addAll([
        for (var i = 0; i < count; i++)
          if (waitingFor[i] == 0) i,
      ]);
    final failures = <int, (Object, StackTrace)>{};
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
          await activate(nodes[index]);
        } on Object catch (error, stackTrace) {
          failures[index] = (error, stackTrace);
        }
        inFlight--;
        settle(index);
        pump();
      }());
    }

    pump = () {
      if (failures.isEmpty) {
        while (ready.isNotEmpty) {
          final index = ready.first;
          ready.remove(index);
          start(index);
        }
        if (inFlight == 0 && unstarted > 0) {
          start(started.indexOf(false));
        }
      }
      if (inFlight == 0 && (failures.isNotEmpty || unstarted == 0)) {
        if (!finished.isCompleted) finished.complete();
      }
    };

    pump();
    await finished.future;
    if (failures.isEmpty) return;
    // The first failure in declaration order is the error; the rollback
    // failures of every other failed member stay attached to it.
    final first = failures.keys.reduce((a, b) => a < b ? a : b);
    final (error, stackTrace) = failures[first]!;
    final extra = <DisposeFailure>[
      // The defect `DropLater` drops the rollback failures of the other
      // failed members.
      if (!RuntimeFaults.injects(RuntimeDefect.dropLater))
        for (final MapEntry(:key, value: (other, _)) in failures.entries)
          if (key != first) ...disposeFailuresOf(other),
    ];
    Error.throwWithStackTrace(
      withDisposeFailures(error, stackTrace, extra),
      stackTrace,
    );
  }

  Future<List<DisposeFailure>> deactivate(
    _RuntimeNode node, {
    required bool permanent,
  }) async {
    if (node.removed) return const <DisposeFailure>[];
    if (!node.active || node.deactivating) {
      if (permanent && !node.deactivating) {
        removeNode(node);
        // A removed contributor leaves its collection.
        nodeTransition(node, keys: node.declaredPublishes);
      }
      return const <DisposeFailure>[];
    }

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

    final dependents = <_RuntimeNode>{};
    for (final publisher in node.publishers) {
      dependents.addAll(publisher.dependents);
    }
    final orderedDependents = dependents.toList()
      ..sort((left, right) => right.id.compareTo(left.id));

    // Dependent failures are reported to the caller but must not be charged
    // to this node: only its own dispose functions can leave *its* effects
    // half released, and only that justifies blocking its reactivation.
    final dependentDisposeFailures = <DisposeFailure>[];
    // The fault skips the release of the dependents.
    if (!RuntimeFaults.breaks(RuntimeSelfCheckFault.dependentFirst)) {
      for (final dependent in orderedDependents) {
        dependentDisposeFailures.addAll(
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
          if (_path(node, dependent, <_RuntimeNode>{}) != null) continue;
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
    final ownDisposeFailures = await runCleanups(
      node.cleanups.reversed,
      node.label,
      episode: node.activationContext,
    );
    final disposeFailures = <DisposeFailure>[
      ...dependentDisposeFailures,
      ...ownDisposeFailures,
    ];

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
      ..reactivationBlocked = ownDisposeFailures.isNotEmpty
      ..deactivating = false
      ..activationContext = null;
    // One transition for the end of the release, also when it removes the
    // node. A removed contributor leaves its collection.
    if (permanent) removeNode(node);
    nodeTransition(
      node,
      keys: permanent ? node.declaredPublishes : const <DiKeyBase>[],
    );
    return disposeFailures;
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
          sink!.failures[own.first] = (error, StackTrace.current);
        } else {
          changes.report(ActivationException(error, StackTrace.current));
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
        final disposeFailures = await deactivate(node, permanent: false);
        if (disposeFailures.isNotEmpty) {
          changes.report(DisposeException(disposeFailures));
        }
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
                    !node.disposalRequested &&
                    node.awaiting.isEmpty &&
                    !failed.contains(node) &&
                    node.satisfied,
              )
              .toList()
            ..sort((left, right) => left.id.compareTo(right.id));
      for (final node in dormant) {
        try {
          await activate(node);
          progressed = true;
        } on Object catch (error, stackTrace) {
          if (error is! DiError && error is! DiException) rethrow;
          failed.add(node);
          if (sink != null && sink.members.contains(node)) {
            sink.failures[node] = (error, stackTrace);
          } else if (error is ActivationCanceledException) {
            // A canceled activation is not a failure; its owner is going
            // away. Releases that failed during its rollback still count.
            if (error.rollbackFailures.isNotEmpty) {
              changes.report(DisposeException(error.rollbackFailures));
            }
          } else {
            // A wiring error that no caller receives is reported as the
            // failed activation that it caused.
            changes.report(
              error is DiException
                  ? error
                  : ActivationException(error, stackTrace),
            );
          }
        }
      }
    }
  }

  bool _targetChanged(_RuntimeNode node) {
    for (final key in node.declaredPlainReads) {
      final next = node.resolve(key);
      if (!identical(next, node.committed[key])) return true;
    }
    for (final collection in node.collectionKeys.followedBy(
      node.optionalCollectionKeys,
    )) {
      final keys = node.contributionKeysOf(collection);
      final previous = node.committedMembership[collection];
      if (previous == null || !_sameKeys(previous, keys)) return true;
      for (final key in keys) {
        final next = node.resolve(key);
        if (!identical(next, node.committed[key])) return true;
      }
    }
    return false;
  }

  static bool _sameKeys(List<DiKeyBase> a, List<DiKeyBase> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

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
  Future<List<DisposeFailure>> _releaseOwned(List<_RuntimeNode> owned) =>
      RuntimeTeardownScheduler<_RuntimeNode, DisposeFailure>(
        // A dependent is done when it is neither active nor releasing. A
        // finished dependent also leaves the publisher's dependents.
        ready: (node) {
          for (final publisher in node.publishers) {
            for (final dependent in publisher.dependents) {
              if (!identical(dependent, node) &&
                  (dependent.active || dependent.deactivating)) {
                return false;
              }
            }
          }
          return true;
        },
        release: (node) => deactivate(node, permanent: true),
      ).releaseAlongReads(owned);

  /// [started] runs after the transition that starts the disposal, while
  /// the error stream of the root is still open.
  Future<List<DisposeFailure>> disposeScope(
    _RuntimeScope scope, {
    void Function()? started,
  }) async {
    final subtree = <_RuntimeScope>[];
    void collect(_RuntimeScope current) {
      current.disposing = true;
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
    final disposeFailures = await _releaseOwned(ownedNodes);

    for (final current in subtree.reversed) {
      current.bindings.clear();
      current
        ..disposed = true
        ..disposing = false;
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
    return disposeFailures;
  }

  /// The owners whose cleanups run now, in the order they started, for a
  /// slow-mutation report. Members roll back concurrently, so more than one
  /// owner can release at a time.
  final List<String> _releasing = [];

  /// Releases the journal [cleanups] of [owner], last entry first. [episode]
  /// is the activation that owns the journal, or null.
  Future<List<DisposeFailure>> runCleanups(
    Iterable<DisposeFunction> cleanups,
    String owner, {
    _RuntimeContext? episode,
  }) async {
    final disposeFailures = <DisposeFailure>[];
    // The fault runs the journal a second time.
    final passes = RuntimeFaults.breaks(RuntimeSelfCheckFault.releaseAtMostOnce)
        ? 2
        : 1;
    // The defect `AcqOrder` releases the journal first entry first.
    final ordered = RuntimeFaults.injects(RuntimeDefect.acqOrder)
        ? cleanups.toList().reversed
        : cleanups;
    Future<void> release(DisposeFunction cleanup) async {
      try {
        await cleanup();
      } on DisposeException catch (failure) {
        disposeFailures.addAll(failure.disposeFailures);
      } on Object catch (error, stackTrace) {
        disposeFailures.add(DisposeFailure(owner, error, stackTrace));
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
          } on DisposeException catch (failure) {
            disposeFailures.addAll(failure.disposeFailures);
          } on Object catch (error, stackTrace) {
            disposeFailures.add(DisposeFailure(owner, error, stackTrace));
          }
        }
        if (started.isNotEmpty) await Future.wait(started);
      }
    } finally {
      _releasing.removeAt(_releasing.lastIndexOf(owner));
    }
    return disposeFailures;
  }

  void addDependency(
    _RuntimeNode node,
    _RuntimePublisher publisher,
    _RuntimeContext activation,
  ) {
    final owner = publisher.owner;
    if (identical(owner, node)) {
      throw DependencyCycleError([node.label, node.label]);
    }
    // The walk reaches [node] only through a committed dependency that
    // [node] owns, so it cannot find a cycle while no node reads a value of
    // [node] (R-UC-RT-LC-023).
    if (node.committedReaders > 0) {
      final path = _path(owner, node, <_RuntimeNode>{});
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

  List<_RuntimeNode>? _path(
    _RuntimeNode from,
    _RuntimeNode target,
    Set<_RuntimeNode> seen,
  ) {
    if (!seen.add(from)) return null;
    if (identical(from, target)) return [from];
    for (final dependency in from.dependencies) {
      final suffix = _path(dependency.owner, target, seen);
      if (suffix != null) return [from, ...suffix];
    }
    return null;
  }
}

/// Collects the reconciliation failures of selected nodes.
///
/// `initialize` uses it to fail for its own members while other
/// nodes keep the reporting rules of reconciliation.
final class _RuntimeFailureSink {
  _RuntimeFailureSink(this.members);

  final Set<_RuntimeNode> members;
  final Map<_RuntimeNode, (Object, StackTrace)> failures = {};
}
