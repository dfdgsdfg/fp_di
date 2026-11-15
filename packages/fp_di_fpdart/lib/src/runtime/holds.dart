part of 'runtime.dart';

// The holds of a disposal: the policy that parks a requested disposal while a
// consumer from outside the runtime still reads the scope, and the reports of
// slow operations.

/// The holds of a disposal, and the reports of slow operations.
extension RuntimeHolds on Runtime {
  /// Opens a hold on the scope [id].
  ///
  /// The result is a `Left` when the scope or an ancestor accepted a disposal.
  /// The call is valid inside a lifecycle operation.
  Either<DiFailure, DisposeHold> disposeHold(ScopeId id, String? debugLabel) {
    if (disposalRequested(state, id)) {
      return Left(const DisposedScopeFailure('disposeHold'));
    }
    StackTrace? trace;
    assert(() {
      trace = StackTrace.current;
      return true;
    }());
    final entry = HoldEntry(debugLabel, trace);
    _holds.update(
      (all) => {
        ...all,
        id: [...?all[id], entry],
      },
    );
    return Right(createDisposeHold(() => _closeHold(id, entry)));
  }

  /// The number of open holds of the scope [id] and of its descendants.
  int subtreeHolds(ScopeId id) => [
    for (final scope in subtree(state, id)) (_holds.now[scope] ?? const []),
  ].fold(0, (count, holds) => count + holds.length);

  /// The state of each open hold of the scope [id] and of its descendants, in
  /// the order of the tree and then of the calls.
  List<HoldState> holdStatesOf(ScopeId id) => [
    for (final scope in subtree(state, id))
      for (final hold in _holds.now[scope] ?? const <HoldEntry>[])
        hold.stateIn(scopePath(state, scope)),
  ];

  /// Gives the scope [id] the [label] that tools show. A `null` label leaves
  /// the scope unnamed.
  void labelScope(ScopeId id, String? label) {
    if (label == null) return;
    _labels.update((all) => {...all, id: label});
  }

  /// The label that a caller gave to the scope [id], or `null`.
  String? scopeLabel(ScopeId id) => _labels.now[id];

  /// The labels of the open holds of the scope [id], without its descendants.
  /// A hold without a label has the label `hold`.
  List<String> holdLabelsOf(ScopeId id) => [
    for (final hold in _holds.now[id] ?? const <HoldEntry>[])
      hold.debugLabel ?? 'hold',
  ];

  /// The labels of the holds that each parked disposal waits for.
  Map<ScopeId, List<String>> waitingLabels() => {
    for (final id in _parked.now.keys)
      id: [for (final hold in holdStatesOf(id)) hold.name],
  };

  /// Ends the hold [entry] of the scope [id]. Each parked disposal of the
  /// scope or of an ancestor whose tree has no open hold any more starts.
  void _closeHold(ScopeId id, HoldEntry entry) {
    _holds.update((all) {
      final rest = [...?all[id]]..remove(entry);
      return {...all, id: rest};
    });
    final chain = <ScopeId>[];
    for (
      ScopeId? at = id;
      at != null;
      at = scopeRecord(state, at).parent.toNullable()
    ) {
      chain.add(at);
    }
    for (final at in chain) {
      if (_parked.now.containsKey(at) && subtreeHolds(at) == 0) {
        unpark(at, const []);
      }
    }
  }

  /// Parks the disposal [disposal] of the scope [id] until its holds close.
  void park(
    ScopeId id,
    Disposal disposal,
    Completer<Exit<DiFailure, Unit>> completer,
    Zone callerZone,
  ) {
    final timer = _watchHolds(id, callerZone);
    _parked.update(
      (all) => {...all, id: Parked(disposal, completer, callerZone, timer)},
    );
  }

  /// Ends the wait of the parked disposal of the scope [id]. The disposal
  /// queues now, and reports the holds in [ignored] after its start.
  ///
  /// The call does nothing when the scope has no parked disposal. A close
  /// from inside a lifecycle operation queues the disposal from the zone of
  /// the call that accepted it, so the queue does not reject it.
  void unpark(ScopeId id, List<HoldState> ignored) {
    final parked = _parked.now[id];
    if (parked == null) return;
    parked.timer?.cancel();
    _parked.update((all) => {...all}..remove(id));
    _queueNow(
      id,
      parked.disposal,
      parked.completer,
      ignored,
      inMutation ? parked.callerZone : Zone.current,
    );
  }

  /// Queues the disposal of the scope [id], and completes the parked
  /// disposals of its descendants with the result of this one.
  void _queueNow(
    ScopeId id,
    Disposal disposal,
    Completer<Exit<DiFailure, Unit>> completer,
    List<HoldState> ignored,
    Zone zone,
  ) {
    final waiting = [
      for (final scope in subtree(state, id))
        if (scope != id) ?_parked.now[scope],
    ];
    for (final parked in waiting) {
      parked.timer?.cancel();
    }
    _parked.update(
      (all) => {
        for (final MapEntry(:key, :value) in all.entries)
          if (!waiting.contains(value)) key: value,
      },
    );
    zone.run(() {
      final exit = _queueDisposal(id, ignored);
      void settle(Disposal d, Completer<Exit<DiFailure, Unit>> c) =>
          exit.then((result) {
            c.complete(result);
            d.finished.set(true);
          });
      settle(disposal, completer);
      for (final parked in waiting) {
        settle(parked.disposal, parked.completer);
      }
    });
  }

  /// A timer that reports the wait of the disposal of [id] for its holds
  /// after each threshold. The timer runs in [zone], outside any lifecycle
  /// operation. The result is `null` without a listener.
  Timer? _watchHolds(ScopeId id, Zone zone) {
    if (_onSlow == null) return null;
    final clock = Stopwatch()..start();
    return zone.run(
      () => Timer.periodic(
        _threshold,
        (_) => _notifySlow(
          SlowMutation(
            operation: 'Scope.dispose (waiting for holds)',
            elapsed: clock.elapsed,
            running: const [],
            ignoringCancellation: const [],
            queued: 0,
            holds: holdStatesOf(id),
          ),
        ),
      ),
    );
  }

  /// A timer that reports the lifecycle operation [operation] after each
  /// threshold. The timer runs in [zone], outside the operation, so the
  /// listener can request an operation, which queues. The result is `null`
  /// without a listener.
  Timer? _watchSlow(String operation, Zone zone) {
    if (_onSlow == null) return null;
    final clock = Stopwatch()..start();
    return zone.run(
      () => Timer.periodic(
        _threshold,
        (_) => _notifySlow(_slowReport(operation, clock.elapsed)),
      ),
    );
  }

  /// The report of [operation], which runs for [elapsed] now.
  SlowMutation _slowReport(String operation, Duration elapsed) {
    final s = state;
    final inFlight = [
      for (final node in liveNodes(s))
        if (node.inFlight.isSome()) node,
    ];
    return SlowMutation(
      operation: operation,
      elapsed: elapsed,
      running: [for (final node in inFlight) labelOf(s, node.id)],
      ignoringCancellation: [
        for (final node in inFlight)
          if (_activations.now[node.inFlight.toNullable()]?.token.isCanceled ??
              false)
            labelOf(s, node.id),
      ],
      disposing: _releasing.now,
      queued: _queued.now,
    );
  }

  /// Gives [slow] to the listener. A listener that throws leaves its failure
  /// to `errors`.
  void _notifySlow(SlowMutation slow) {
    final listener = _onSlow;
    if (listener == null) return;
    Either.tryCatch(
      () => listener(slow),
      (error, stackTrace) => (error, stackTrace),
    ).match(
      (thrown) =>
          report(Fail<DiFailure>(ListenerFailure(thrown.$1), thrown.$2)),
      (_) {},
    );
  }

  /// The task that releases [finalizers] for [owner], and gives the cause of
  /// the dispose failures. A slow report names the owner while it releases.
  Task<Cause<DiFailure>> releaseFor(String owner, Finalizers finalizers) =>
      Task(() async {
        _releasing.update((all) => [...all, owner]);
        try {
          return await finalizers.release().run();
        } finally {
          _releasing.update(
            (all) => [...all]..removeAt(all.lastIndexOf(owner)),
          );
        }
      });
}
