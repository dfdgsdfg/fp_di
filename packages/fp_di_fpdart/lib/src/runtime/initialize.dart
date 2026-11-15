part of 'runtime.dart';

// The run of one scope (inventory 1.2): the mutation body of `Scope.run`.

/// The run of one scope.
extension RuntimeInitialize on Runtime {
  /// The task that runs the body of the mutation `run` for the scope [id].
  ///
  /// The task gives `Right` when the scope is initialized. It gives `Left`
  /// with an [Interrupt] when the scope accepted a disposal while the call
  /// waited in the queue, with the failures of the pre-check when the
  /// components are not valid, and with the first failure of a node, followed
  /// by the dispose failures of the rollback, when an activation failed.
  Task<Exit<DiFailure, Unit>> initialize(ScopeId id) => Task(() async {
    final s = state;
    final scope = scopeRecord(s, id);
    // The setup never starts for a scope whose disposal was requested while
    // this call waited in the queue.
    if (disposalRequested(s, id) && !scope.disposed) {
      return Left<Cause<DiFailure>, Unit>(
        Interrupt<DiFailure>(StackTrace.current),
      );
    }
    if (scope.disposed) {
      return Left<Cause<DiFailure>, Unit>(
        Fail<DiFailure>(DisposedScopeFailure('run'), StackTrace.current),
      );
    }
    if (scope.initialized) {
      return Left<Cause<DiFailure>, Unit>(
        Fail<DiFailure>(
          ScopePhaseFailure(operation: 'run', phase: ScopePhase.initialized),
          StackTrace.current,
        ),
      );
    }
    // The checks run before any state changes.
    final invalid = preCheck(s, id);
    if (!invalid.isEmpty) return Left<Cause<DiFailure>, Unit>(invalid);

    late final List<NodeId> ids;
    apply((state) {
      final (next, created) = createNodes(state, id);
      ids = created;
      return next;
    });
    final members = ids.toSet();
    var failures = await activateMembers(ids).run();
    if (failures.isEmpty) {
      // A member can first activate here, after a node that the scope woke
      // publishes a key that it needs. It fails the call like a member that
      // fails during the activation above.
      failures = await reconcile(members: members).run();
    }
    if (failures.isEmpty) {
      apply((state) => finishInitialize(state, id));
      return const Right<Cause<DiFailure>, Unit>(unit);
    }
    final failure = _firstFailure(failures);
    var rollback = const Empty<DiFailure>() as Cause<DiFailure>;
    for (final n in ids.reversed) {
      rollback += await deactivate(n, permanent: true).run();
    }
    apply((state) => rollbackInitialize(state, id));
    // Nodes that the bindings of the scope woke are dormant now. The
    // reconciliation leaves the runtime consistent for the rest.
    await reconcile().run();
    return Left<Cause<DiFailure>, Unit>(failure + rollback);
  });
}
