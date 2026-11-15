part of 'runtime.dart';

// The reconciliation (inventory 3.3) and the activation of the members of one
// initialization (inventory 1.3).

/// The first failure by id, with the dispose failures of the other failures
/// attached after it. The map must not be empty.
Cause<DiFailure> _firstFailure(Map<NodeId, Cause<DiFailure>> failures) {
  final ordered = failures.keys.toList()
    ..sort((a, b) => a.value.compareTo(b.value));
  return ordered
      .skip(1)
      .fold<Cause<DiFailure>>(
        failures[ordered.first]!,
        (all, next) => all + failures[next]!.onlyDefects,
      );
}

/// The reconciliation and the activation of the members.
extension RuntimeReconcile on Runtime {
  /// The task that brings every node to its target.
  ///
  /// A pass rebuilds the active nodes whose target changed, and activates the
  /// eligible dormant nodes. The reconciliation repeats while an active node
  /// is stale, at most as many passes as the runtime has live nodes plus one.
  ///
  /// The failure of a node in [members] goes to the result, which maps the
  /// node to the cause. Another failure goes to `errors`, and the
  /// reconciliation goes on. A canceled activation is not a failure.
  Task<Map<NodeId, Cause<DiFailure>>> reconcile({
    Set<NodeId> members = const {},
  }) => Task(() async {
    final limit = liveNodes(state).length + 1;
    var failed = const <NodeId>{};
    var sink = const <NodeId, Cause<DiFailure>>{};
    for (var pass = 1; ; pass++) {
      await _rebuildChanged().run();
      final dormant = await _activateDormant(failed, members).run();
      failed = dormant.$1;
      sink = {...sink, ...dormant.$2};
      final stale = staleActives(state)..sort((a, b) => a.value - b.value);
      if (stale.isEmpty) return sink;
      if (pass >= limit) {
        final cause = Fail<DiFailure>(
          UnsettledFailure([for (final n in stale) labelOf(state, n)], pass),
          StackTrace.current,
        );
        final own = stale.where(members.contains);
        if (own.isNotEmpty) {
          return {...sink, own.first: cause};
        }
        report(cause);
        return sink;
      }
    }
  });

  /// The task that releases the active nodes whose target changed, from the
  /// highest id to the lowest. A release releases the dependents first.
  Task<Unit> _rebuildChanged() => Task(() async {
    final active = [
      for (final node in liveNodes(state))
        if (node.active) node.id,
    ]..sort((a, b) => b.value - a.value);
    for (final n in active) {
      if (!targetChanged(state, n)) continue;
      final failures = await deactivate(n, permanent: false).run();
      if (!failures.isEmpty) report(failures);
    }
    return unit;
  });

  /// The task that activates the dormant nodes, in ascending id, until none
  /// makes progress.
  ///
  /// The result holds the nodes that threw, which the reconciliation does not
  /// attempt again, and the cause of each node of [members] that threw.
  Task<(Set<NodeId>, Map<NodeId, Cause<DiFailure>>)> _activateDormant(
    Set<NodeId> failed,
    Set<NodeId> members,
  ) => Task(() async {
    var skip = failed;
    var sink = const <NodeId, Cause<DiFailure>>{};
    var progressed = true;
    while (progressed) {
      progressed = false;
      for (final n in dormantCandidates(state, skip)) {
        final attempt = await activate(n).run();
        attempt.match((cause) {
          skip = {...skip, n};
          if (members.contains(n)) {
            sink = {...sink, n: cause};
          } else if (cause.isInterrupted) {
            // A canceled activation is not a failure. The releases that
            // failed during its rollback still count.
            final dies = cause.onlyDefects;
            if (!dies.isEmpty) report(dies);
          } else {
            report(cause);
          }
        }, (ran) => progressed = progressed || ran);
      }
    }
    return (skip, sink);
  });

  /// The task that activates the nodes [ids] of one scope by dependency.
  ///
  /// A node waits for the nodes of the list that publish a key that it reads.
  /// A prerequisite is settled when its activation returns: committed or
  /// dormant. A dormant publisher does not block a dependent. A cycle leaves
  /// no node ready, so the first node that did not start in declaration order
  /// starts. After a failure no node starts, and the task waits for every
  /// node in flight. The result maps each failed node to its cause.
  Task<Map<NodeId, Cause<DiFailure>>> activateMembers(List<NodeId> ids) => Task(
    () async {
      final s = state;
      final count = ids.length;
      final publisherOf = <DiKey<Object?>, int>{
        for (var i = 0; i < count; i++)
          for (final key in declaredPublishes(s, nodeRecord(s, ids[i]))) key: i,
      };
      final waitingFor = List<int>.filled(count, 0);
      final dependents = List<List<int>>.generate(count, (_) => <int>[]);
      for (var i = 0; i < count; i++) {
        final prerequisites = <int>{
          for (final key in plainReads(s, nodeRecord(s, ids[i])))
            if (publisherOf[key] case final publisher? when publisher != i)
              publisher,
        };
        waitingFor[i] = prerequisites.length;
        for (final prerequisite in prerequisites) {
          dependents[prerequisite].add(i);
        }
      }
      final started = <int>{};
      final ready = <int>[
        for (var i = 0; i < count; i++)
          if (waitingFor[i] == 0) i,
      ];
      final finished = Completions<(int, Attempt)>();
      var inFlight = 0;
      final failures = <NodeId, Cause<DiFailure>>{};

      void start(int i) {
        started.add(i);
        inFlight++;
        unawaited(
          activate(ids[i]).run().then(
            (outcome) => finished.add((i, outcome)),
            onError: finished.addError,
          ),
        );
      }

      while (true) {
        if (failures.isEmpty) {
          // A start adds no node to `ready`, so one sort gives the order.
          ready.sort();
          final batch = [...ready];
          ready.clear();
          batch.forEach(start);
          if (inFlight == 0 && started.length < count) {
            start(
              [
                for (var i = 0; i < count; i++) i,
              ].firstWhere((i) => !started.contains(i)),
            );
          }
        }
        if (inFlight == 0 && (failures.isNotEmpty || started.length == count)) {
          return failures;
        }
        final (i, outcome) = await finished.next();
        inFlight--;
        outcome.match((cause) {
          failures[ids[i]] = cause;
        }, (_) {});
        for (final dependent in dependents[i]) {
          if (started.contains(dependent)) continue;
          waitingFor[dependent]--;
          if (waitingFor[dependent] == 0) ready.add(dependent);
        }
      }
    },
  );
}
