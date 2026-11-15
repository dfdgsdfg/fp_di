part of 'runtime.dart';

// The notification kernel and the mutation queue: the state cell, the
// transitions, the listener rounds, the `errors` reports, and the serial
// queue of the lifecycle mutations.

/// The notification kernel and the mutation queue.
extension RuntimeKernel on Runtime {
  /// Replaces the state with `change(state)`. Gives whether the revision
  /// rose. The caller then runs [transition] for a rise.
  ///
  /// The method tells nothing to the listeners. A caller that must record
  /// something before the listeners run uses it, and calls [transition] after.
  bool write(RuntimeState Function(RuntimeState state) change) {
    final before = _state.now;
    final after = change(before);
    _state.set(after);
    return after.revision != before.revision;
  }

  /// Replaces the state with `change(state)`, and runs the listeners when the
  /// revision rose. [disposed] is the scope that the transition disposed.
  void apply(
    RuntimeState Function(RuntimeState state) change, {
    Option<ScopeId> disposed = const None(),
  }) {
    if (write(change)) transition(disposed);
  }

  /// Ends one transition: runs the round of the listener calls.
  ///
  /// A transition that a listener starts replaces the state at once. Its
  /// round waits until the round in progress ends, so rounds run one after
  /// the other.
  void transition([Option<ScopeId> disposed = const None()]) {
    _rounds.update((rounds) => [...rounds, disposed]);
    if (_inRound.now) return;
    _inRound.set(true);
    try {
      while (_rounds.now.isNotEmpty) {
        final next = _rounds.now.first;
        _rounds.update((rounds) => rounds.sublist(1));
        _round(next);
      }
    } finally {
      _inRound.set(false);
    }
  }

  /// One round: calls a copy of the listeners of every scope.
  ///
  /// A listener that left meanwhile is skipped. A listener that throws leaves,
  /// and its failure is reported after the round. The listeners of the
  /// [disposed] scope leave after their call.
  void _round(Option<ScopeId> disposed) {
    final failures = <Cause<DiFailure>>[];
    for (final listener in _listeners.now) {
      if (!_listeners.now.contains(listener)) continue;
      Either.tryCatch(
        listener.call,
        (error, stackTrace) => (error, stackTrace),
      ).match((thrown) {
        removeListener(listener.scope, listener.call);
        failures.add(Fail<DiFailure>(ListenerFailure(thrown.$1), thrown.$2));
      }, (_) {});
    }
    disposed.match(
      () {},
      (scope) => _listeners.update(
        (all) => [
          for (final listener in all)
            if (listener.scope != scope) listener,
        ],
      ),
    );
    failures.forEach(report);
  }

  /// Adds [call] as a listener of [scope]. A function that the scope holds
  /// already is not added again.
  void addListener(ScopeId scope, void Function() call) {
    final listener = (scope: scope, call: call);
    if (_listeners.now.contains(listener)) return;
    _listeners.update((all) => [...all, listener]);
  }

  /// Removes [call] from the listeners of [scope].
  void removeListener(ScopeId scope, void Function() call) {
    _listeners.update(
      (all) => [
        for (final listener in all)
          if (!(listener.scope == scope && listener.call == call)) listener,
      ],
    );
  }

  /// Reports [cause] to `errors`.
  ///
  /// Reports wait for each other, so one subscriber call ends before the next
  /// report starts. The runtime drops a report after the root closed the
  /// stream.
  void report(Cause<DiFailure> cause) {
    if (_closed.now) return;
    _reports.update((all) => [...all, cause]);
    if (_delivering.now) return;
    _delivering.set(true);
    try {
      while (_reports.now.isNotEmpty) {
        final next = _reports.now.first;
        _reports.update((all) => all.sublist(1));
        if (!_closed.now) _errors.add(next);
      }
    } finally {
      _delivering.set(false);
    }
  }

  /// Closes the `errors` stream. The root calls it after its disposal.
  Future<void> closeErrors() {
    _closed.set(true);
    return _errors.close();
  }

  /// Whether a mutation of this runtime runs in the current zone.
  bool get inMutation {
    final marker = Zone.current[_zoneKey];
    return marker is _Mutation && marker.running.now;
  }

  /// Runs [action] as one mutation, after every earlier mutation ended.
  ///
  /// The queue is first in, first out. A mutation that a running mutation
  /// requests is rejected with a [ReentrantMutationFailure]. The action runs
  /// in a zone that marks it. A callback that the action created keeps the
  /// mark. After the mutation ended, the mark is off, so such a callback may
  /// start a mutation.
  Future<Exit<DiFailure, A>> mutate<A>(
    String operation,
    Future<Exit<DiFailure, A>> Function() action,
  ) {
    if (inMutation) {
      return Future.value(
        Left<Cause<DiFailure>, A>(
          Fail<DiFailure>(
            ReentrantMutationFailure(operation),
            StackTrace.current,
          ),
        ),
      );
    }
    // Wait on the gate only while its mutation is open. A gate that was
    // released is a future of the zone that created it, and a listener on a
    // completed future runs in that zone. That zone can be dead by now, and
    // then the waiting mutation never starts.
    final previous = _open.now > 0 ? _queueTail.now : null;
    final gate = Completer<void>();
    _queueTail.set(gate.future);
    _open.update((open) => open + 1);
    _queued.update((queued) => queued + 1);
    // The closure runs in the zone of the caller, so each wait below resumes
    // there. The caller's zone is never a running mutation of this runtime.
    final callerZone = Zone.current;
    return () async {
      try {
        // One asynchronous hop in either branch: the action never starts
        // inside this call. The fresh future is complete and belongs to the
        // zone of the caller.
        await (previous ?? Future<void>.sync(() {}));
      } on Object {
        // Each mutation reports through its own result. The queue stays live.
      }
      _queued.update((queued) => queued - 1);
      final marker = _Mutation();
      // The timer runs in the zone of the caller, outside the mutation, so a
      // listener of a slow report can request a mutation, which queues.
      final slow = _watchSlow(operation, callerZone);
      try {
        return await Zone.current
            .fork(zoneValues: {_zoneKey: marker})
            .run<Future<Exit<DiFailure, A>>>(action);
      } finally {
        slow?.cancel();
        marker.running.set(false);
        _open.update((open) => open - 1);
        gate.complete();
      }
    }();
  }

  /// The state of the scope [id], which shares its objects with the states
  /// that earlier reads returned.
  ScopeState scopeStateOf(ScopeId id) {
    final (value, next) = scopeStateShared(state, id, _snapshots.now);
    _snapshots.set(next);
    return value;
  }

  /// The state of the node [n], which is the object that `scopeStateOf` gives
  /// for the scope of the node.
  NodeState nodeStateOf(NodeId n) {
    final (value, next) = nodeStateShared(state, n, _snapshots.now);
    _snapshots.set(next);
    return value;
  }

  /// Cancels the activation with [ticket], when it runs. The first reason
  /// stays.
  void cancel(int ticket, CancelReason reason) {
    _activations.now[ticket]?.token.cancel(reason);
  }

  /// Cancels the running activation of [node], when it exists.
  void cancelNode(NodeId node, CancelReason reason) {
    nodeRecord(state, node).inFlight.match(() {}, (ticket) {
      cancel(ticket, reason);
    });
  }
}
