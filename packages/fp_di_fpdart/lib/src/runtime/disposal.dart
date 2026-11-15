part of 'runtime.dart';

// The disposal of a scope (inventory 4.3, 5.1) and of a node (inventory 4.3).

/// The disposal of a scope and of a node.
extension RuntimeDisposal on Runtime {
  /// The task that disposes the scope [id] and its descendants, in the body
  /// of the disposal mutation, and gives the cause of the dispose failures.
  ///
  /// The task marks the subtree as disposing, releases the nodes along their
  /// reads, and marks each scope as disposed, the deepest first. The failures
  /// follow descending node id. The task does not reconcile: a reader of a
  /// disposed node lives in the same scope or in a descendant, so it dies with
  /// the node.
  ///
  /// The holds in [ignored] are the open holds that the call ignored. The task
  /// reports them to `errors` after the transition that starts the disposal.
  Task<Cause<DiFailure>> disposeScope(
    ScopeId id, {
    List<HoldState> ignored = const [],
  }) => Task(() async {
    final tree = subtree(state, id);
    apply((s) => markDisposing(s, tree));
    // The defect `DropIgnoredReport` skips the report.
    if (ignored.isNotEmpty &&
        !RuntimeFaults.injects(Defect.dropIgnoredReport)) {
      report(Fail<DiFailure>(IgnoredHoldsFailure(ignored), StackTrace.current));
    }
    final included = tree.toSet();
    final owned = [
      for (final node in liveNodes(state))
        if (included.contains(node.scope)) node.id,
    ]..sort((a, b) => b.value - a.value);
    final failures = await releaseAlongReads(owned).run();
    for (final scope in tree.reversed) {
      apply((s) => markDisposed(s, scope), disposed: Some(scope));
    }
    if (scopeRecord(state, id).parent.isNone()) {
      assert(() {
        Inspector.rootDisposed(this);
        return true;
      }());
      await closeErrors();
    }
    return failures;
  });

  /// The nearest scope, from [id] to the root, that accepted a disposal.
  Option<ScopeId> disposalOwnerId(ScopeId id) {
    ScopeId? at = id;
    while (at != null) {
      if (_scopeDisposals.now.containsKey(at)) return Some(at);
      at = scopeRecord(state, at).parent.toNullable();
    }
    return const None();
  }

  /// The disposal of the nearest scope, from [id] to the root, that accepted
  /// a disposal.
  Option<Disposal> disposalOwner(ScopeId id) =>
      disposalOwnerId(id).map((owner) => _scopeDisposals.now[owner]!);

  /// Disposes the scope [id], as `Scope.dispose` does.
  ///
  /// The call joins the disposal that the scope or an ancestor accepted. The
  /// call that accepts a disposal cancels the activations in flight in the
  /// subtree at once, before the disposal mutation reaches the queue.
  Future<Exit<DiFailure, Unit>> disposeScopeCall(
    ScopeId id, {
    required bool ignoreHolds,
  }) {
    final owner = disposalOwner(id);
    if (owner.match(() => false, (disposal) => disposal.finished.now)) {
      // The defect `ReplayAfterEnd` gives the result of the finished disposal.
      if (RuntimeFaults.injects(Defect.replayAfterEnd)) {
        return owner.toNullable()!.result;
      }
      return Future.value(const Right<Cause<DiFailure>, Unit>(unit));
    }
    if (owner.isNone() && scopeRecord(state, id).disposed) {
      return Future.value(const Right<Cause<DiFailure>, Unit>(unit));
    }
    if (inMutation) {
      // The defect `LateReentrancyCheck` records the request before the
      // rejection.
      if (owner.isNone() && RuntimeFaults.injects(Defect.lateReentrancyCheck)) {
        if (write((s) => requestScopeDisposal(s, id))) transition();
      }
      return Future.value(
        Left<Cause<DiFailure>, Unit>(
          Fail<DiFailure>(
            ReentrantMutationFailure('Scope.dispose'),
            StackTrace.current,
          ),
        ),
      );
    }
    final joined = owner.toNullable();
    if (joined != null) {
      // A call that ignores the holds ends the wait of the disposal that it
      // joins.
      final at = disposalOwnerId(id).toNullable();
      if (ignoreHolds && at != null) unpark(at, holdStatesOf(at));
      // The defect `SecondCallerOk` hides the result from a joining call.
      if (RuntimeFaults.injects(Defect.secondCallerOk)) {
        return joined.result.then(
          (_) => const Right<Cause<DiFailure>, Unit>(unit),
          onError: (Object _) => const Right<Cause<DiFailure>, Unit>(unit),
        );
      }
      return joined.result;
    }

    // The call runs outside a lifecycle operation, so its zone can queue the
    // disposal when a hold closes inside one.
    final callerZone = Zone.current;
    final changed = write((s) => requestScopeDisposal(s, id));
    final included = subtree(state, id).toSet();
    for (final node in liveNodes(state)) {
      if (included.contains(node.scope)) {
        cancelNode(node.id, CancelReason.owner);
      }
    }
    final completer = Completer<Exit<DiFailure, Unit>>();
    final disposal = Disposal(completer.future);
    _scopeDisposals.update((all) => {...all, id: disposal});
    // The one decision point: queue the disposal now, or park it while a hold
    // of the subtree is open. A call with `ignoreHolds` never parks.
    // The defect `QueueWithHolds` queues the disposal while a hold is open.
    if (ignoreHolds ||
        RuntimeFaults.injects(Defect.queueWithHolds) ||
        subtreeHolds(id) == 0) {
      _queueNow(
        id,
        disposal,
        completer,
        ignoreHolds ? holdStatesOf(id) : const [],
        callerZone,
      );
    } else {
      park(id, disposal, completer, callerZone);
    }
    // The disposal is recorded before the listeners run, so a `dispose` call
    // from a listener joins it.
    if (changed) transition();
    return disposal.result;
  }

  /// Queues the disposal mutation of the scope [id], and gives its result.
  ///
  /// The holds in [ignored] are the open holds that the call ignored.
  Future<Exit<DiFailure, Unit>> _queueDisposal(
    ScopeId id,
    List<HoldState> ignored,
  ) => mutate<Unit>('Scope.dispose', () async {
    // A scope that an ancestor disposed shares the result of the ancestor.
    if (scopeRecord(state, id).disposed) {
      final parent = scopeRecord(state, id).parent.toNullable();
      final Option<Disposal> ancestor = parent == null
          ? const None()
          : disposalOwner(parent);
      return ancestor.match(
        () async => const Right<Cause<DiFailure>, Unit>(unit),
        (shared) => shared.result,
      );
    }
    final failures = await disposeScope(id, ignored: ignored).run();
    return failures.isEmpty
        ? const Right<Cause<DiFailure>, Unit>(unit)
        : Left<Cause<DiFailure>, Unit>(failures);
  });

  /// Disposes the node [n], as `ComponentNode.dispose` does.
  ///
  /// The call cancels the activation of the node and the activations that read
  /// a value that the withdrawal takes away, and registers the withdrawal.
  /// The mutation releases the node and its dependents, ends the withdrawal,
  /// and reconciles.
  Future<Exit<DiFailure, Unit>> disposeNodeCall(NodeId n) {
    final pending = _nodeDisposals.now[n];
    if (pending != null && pending.finished.now) {
      return Future.value(const Right<Cause<DiFailure>, Unit>(unit));
    }
    if (pending == null && nodeRecord(state, n).removed) {
      return Future.value(const Right<Cause<DiFailure>, Unit>(unit));
    }
    // A reentrant call is rejected before it joins a pending disposal.
    if (inMutation) {
      return Future.value(
        Left<Cause<DiFailure>, Unit>(
          Fail<DiFailure>(
            ReentrantMutationFailure('ComponentNode.dispose'),
            StackTrace.current,
          ),
        ),
      );
    }
    if (pending != null) return pending.result;

    write((s) => requestNodeDisposal(s, n));
    cancelNode(n, CancelReason.owner);
    final reach = withdrawalReach(state, n);
    final reads = {
      for (final node in liveNodes(state))
        if (node.inFlight.toNullable() case final ticket?)
          if (_activations.now[ticket] case final activation?)
            node.id: activation.reads.now,
    };
    final canceled = withdrawalCancels(state, reach, reads: reads);
    for (final node in canceled) {
      cancelNode(node, CancelReason.withdrawal);
    }
    write((s) => addWithdrawal(s, n, canceled));

    final completer = Completer<Exit<DiFailure, Unit>>();
    final disposal = Disposal(completer.future);
    _nodeDisposals.update((all) => all.put(n, disposal));
    mutate<Unit>('ComponentNode.dispose', () async {
      if (nodeRecord(state, n).removed) {
        write((s) => finishWithdrawal(s, n));
        return const Right<Cause<DiFailure>, Unit>(unit);
      }
      final failures = await deactivate(n, permanent: true).run();
      // The readers that this withdrawal canceled may activate again now.
      write((s) => finishWithdrawal(s, n));
      await reconcile().run();
      return failures.isEmpty
          ? const Right<Cause<DiFailure>, Unit>(unit)
          : Left<Cause<DiFailure>, Unit>(failures);
    }).then(
      (exit) {
        completer.complete(exit);
        disposal.finished.set(true);
      },
      // Only a failed self-check or a bug of the runtime throws here. The
      // callers of the disposal get the error.
      onError: (Object error, StackTrace stackTrace) {
        completer.completeError(error, stackTrace);
        disposal.finished.set(true);
      },
    );
    return disposal.result;
  }
}
