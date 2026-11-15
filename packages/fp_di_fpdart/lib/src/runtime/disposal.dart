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
  Task<Cause<DiFailure>> disposeScope(ScopeId id) => Task(() async {
    final tree = subtree(state, id);
    apply((s) => markDisposing(s, tree));
    final included = tree.toSet();
    final owned = [
      for (final node in liveNodes(state))
        if (included.contains(node.scope)) node.id,
    ]..sort((a, b) => b.value - a.value);
    final failures = await releaseAlongReads(owned).run();
    for (final scope in tree.reversed) {
      apply((s) => markDisposed(s, scope), disposed: Some(scope));
    }
    if (scopeRecord(state, id).parent.isNone()) await closeErrors();
    return failures;
  });

  /// The nearest scope, from [id] to the root, that accepted a disposal.
  Option<Disposal> disposalOwner(ScopeId id) {
    ScopeId? at = id;
    while (at != null) {
      final found = _scopeDisposals.now[at];
      if (found != null) return Some(found);
      at = scopeRecord(state, at).parent.toNullable();
    }
    return const None();
  }

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
      return Future.value(const Right<Cause<DiFailure>, Unit>(unit));
    }
    if (owner.isNone() && scopeRecord(state, id).disposed) {
      return Future.value(const Right<Cause<DiFailure>, Unit>(unit));
    }
    if (inMutation) {
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
    if (joined != null) return joined.result;

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
    // The one decision point: queue the disposal now, or park it. A later
    // phase parks it while a hold of the subtree is open.
    _queueDisposal(id, disposal, completer);
    // The disposal is recorded before the listeners run, so a `dispose` call
    // from a listener joins it.
    if (changed) transition();
    return disposal.result;
  }

  /// Queues the disposal mutation of the scope [id].
  void _queueDisposal(
    ScopeId id,
    Disposal disposal,
    Completer<Exit<DiFailure, Unit>> completer,
  ) {
    mutate<Unit>('Scope.dispose', () async {
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
      final failures = await disposeScope(id).run();
      return failures.isEmpty
          ? const Right<Cause<DiFailure>, Unit>(unit)
          : Left<Cause<DiFailure>, Unit>(failures);
    }).then((exit) {
      completer.complete(exit);
      disposal.finished.set(true);
    });
  }

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
    _nodeDisposals.update((all) => {...all, n: disposal});
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
    }).then((exit) {
      completer.complete(exit);
      disposal.finished.set(true);
    });
    return disposal.result;
  }
}
