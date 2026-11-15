part of 'runtime.dart';

// The activation of one node (inventory 3.4) and the release of one node
// (inventory 3.5). Each program is a task that runs against the state.

/// The cause of a cancellation: an interruption, with the cause that the
/// steps gave after it.
Cause<DiFailure> _canceled(Cause<DiFailure> reason, Cause<DiFailure> rollback) {
  final trace = reason.interruptions.firstOrNull ?? StackTrace.current;
  final others = reason.fold<Cause<DiFailure>>(
    empty: Empty<DiFailure>.new,
    fail: Fail<DiFailure>.new,
    die: Die<DiFailure>.new,
    interrupt: (_) => const Empty<DiFailure>(),
    then: (first, second) => first + second,
    both: (left, right) => left & right,
  );
  return Interrupt<DiFailure>(trace) + others + rollback;
}

/// The activation and the release of one node.
extension RuntimeActivation on Runtime {
  /// The task that activates [n].
  ///
  /// The result is `Right(false)` when the attempt did nothing, `Right(true)`
  /// when the activation ran to a commit or to a cancel by a withdrawal, and
  /// `Left` with the cause when the activation threw. A canceled activation
  /// never commits.
  Task<Attempt> activate(NodeId n) => Task(() async {
    final before = state;
    final node = nodeRecord(before, n);
    if (node.removed ||
        node.active ||
        scopeRecord(before, node.scope).disposing) {
      return const Right<Cause<DiFailure>, bool>(false);
    }
    // The setup never starts for an owner whose disposal was requested.
    if (setupRefused(before, n)) {
      return Left<Cause<DiFailure>, bool>(
        Interrupt<DiFailure>(StackTrace.current),
      );
    }
    // A component never runs against an unsatisfied environment.
    if (!satisfied(before, n) || node.awaiting.isNotEmpty) {
      return const Right<Cause<DiFailure>, bool>(false);
    }

    final ticket = before.nextTicket;
    final activation = Activation.create();
    final owned = IORef.create<Finalizers>(Finalizers.empty).run();
    final label = labelOf(before, n);
    final changed = write((s) => beginActivation(s, n).$1);
    _activations.update((all) => all.put(ticket, activation));
    if (changed) transition();

    final context = StepContext(
      owner: label,
      finalizers: owned,
      read: (key) => _read(n, ticket, activation, key),
      readOption: (key) => _readOption(n, ticket, activation, key),
      readCollection: (key, {required strict}) =>
          _readCollection(n, ticket, activation, key, strict: strict),
      checkpoint: () =>
          // The defect `SkipCheckpoint` does not stop a canceled activation.
          activation.token.isCanceled &&
              !RuntimeFaults.injects(Defect.skipCheckpoint)
          ? Left<Cause<DiFailure>, Unit>(
              Interrupt<DiFailure>(StackTrace.current),
            )
          : const Right<Cause<DiFailure>, Unit>(unit),
      cancellation: activation.token,
      ownerClosed: () => setupRefused(state, n),
    );
    final component = componentOf(before, node);
    final ran = await runComponent(component, context).run();
    final outcome = ran.flatMap((value) => _guardCommit(n, activation, value));
    return outcome.match(
      (cause) => _endFailed(n, ticket, activation, owned, cause),
      (value) async {
        _commit(n, ticket, activation, owned, value);
        return const Right<Cause<DiFailure>, bool>(true);
      },
    );
  });

  /// The checks between the last step and the commit: a canceled activation
  /// never commits, and a key that the scope binds already is a duplicate.
  Either<Cause<DiFailure>, Object?> _guardCommit(
    NodeId n,
    Activation activation,
    Object? value,
  ) {
    // The fault `NoCommitAfterCancel` lets a canceled activation commit.
    if (activation.token.isCanceled &&
        !RuntimeFaults.breaks(SelfCheckFault.noCommitAfterCancel)) {
      return Left(Interrupt<DiFailure>(StackTrace.current));
    }
    final s = state;
    return conflictingPublication(s, n).match(
      () => Right(value),
      (key) => Left(
        Fail<DiFailure>(
          DuplicateKeyFailure(key, [labelOf(s, n)]),
          StackTrace.current,
        ),
      ),
    );
  }

  /// The commit of an activation: one transition, then the waiters.
  void _commit(
    NodeId n,
    int ticket,
    Activation activation,
    IORef<Finalizers> owned,
    Object? value,
  ) {
    assert(
      !RuntimeFaults.checking || !activation.token.isCanceled,
      'SelfCheck NoCommitAfterCancel: the node ${labelOf(state, n)} commits '
      'after its activation was canceled',
    );
    final changed = write(
      (s) => commit(
        s,
        n,
        value,
        activation.view.now,
        activation.reads.now,
        owned.now,
        membership: activation.membership.now,
      ),
    );
    // The token of the committed activation stays until the release ends.
    _committed.update((all) => all.put(n, activation));
    _activations.update((all) => all.without(ticket));
    if (changed) transition();
    _wake(n, Right<DiFailure, Object?>(value));
  }

  /// The end of an activation that threw or was canceled.
  Future<Attempt> _endFailed(
    NodeId n,
    int ticket,
    Activation activation,
    IORef<Finalizers> owned,
    Cause<DiFailure> cause,
  ) async {
    // A step failure is local to this region: the token is canceled before the
    // first dispose function runs.
    final reason = activation.token.reason;
    activation.token.cancel(CancelReason.failure);
    // The defect `DropLease` skips the release of the stack of a failed
    // activation.
    final rollback = RuntimeFaults.injects(Defect.dropLease)
        ? const Empty<DiFailure>()
        : await releaseFor(
            '${labelOf(state, n)} activation rollback',
            owned.now,
          ).run();
    void end({
      required Option<Cause<DiFailure>> failure,
      required Set<NodeId> awaiting,
      required bool failed,
    }) {
      final changed = write(
        (s) => endActivation(
          s,
          n,
          failure: failure,
          awaiting: awaiting,
          failed: failed,
        ),
      );
      _activations.update((all) => all.without(ticket));
      if (changed) transition();
    }

    final canceledBy = reason.toNullable();
    if (canceledBy == CancelReason.withdrawal && !setupRefused(state, n)) {
      // Not a failure: the node stays inactive and waits for the withdrawal.
      // Releases that failed during the rollback still count.
      end(
        failure: const None(),
        awaiting: activation.awaited.now,
        failed: false,
      );
      if (!rollback.isEmpty) report(rollback);
      return const Right<Cause<DiFailure>, bool>(true);
    }
    if (canceledBy != null) {
      end(failure: const None(), awaiting: const {}, failed: true);
      return Left<Cause<DiFailure>, bool>(_canceled(cause, rollback));
    }
    final failure = cause + rollback;
    end(failure: Some(failure), awaiting: const {}, failed: true);
    return Left<Cause<DiFailure>, bool>(failure);
  }

  /// A read of the collection [key] for the activation of [n]: the values of
  /// the contributions, in the order of the membership.
  ///
  /// The read keeps the membership. A strict read fails when a contribution
  /// does not resolve, and an optional read skips it. A map has the id of an
  /// entry as its key, and the nearest entry that resolves gives its value.
  Either<Cause<DiFailure>, Object> _readCollection(
    NodeId n,
    int ticket,
    Activation activation,
    DiCollectionKey<Object?> key, {
    required bool strict,
  }) {
    final s = state;
    final node = nodeRecord(s, n);
    final keys = contributionKeysOf(s, n, key);
    activation.membership.update((all) => {...all, key: keys});
    final values = <(DiKey<Object?>, Object?)>[];
    for (final contribution in keys) {
      final found = resolve(s, node.scope, contribution, exclude: Some(n));
      if (found.isNone()) {
        if (strict) {
          return Left(
            Fail<DiFailure>(UnavailableKeyFailure(key), StackTrace.current),
          );
        }
        continue;
      }
      final value = _track(
        s,
        n,
        ticket,
        activation,
        contribution,
        found.toNullable()!,
      );
      if (value.isLeft()) return value.map((_) => const <Object?>{});
      values.add((contribution, value.getOrElse((_) => null)));
    }
    return Right(switch (key) {
      DiSetKey<Object?>() => <Object?>{for (final (_, v) in values) v},
      DiMapKey<Object?>() => <String, Object?>{
        for (final (contribution, v) in values) contribution.name!: v,
      },
    });
  }

  /// A required read of [key] for the activation of [n].
  Either<Cause<DiFailure>, Object?> _read(
    NodeId n,
    int ticket,
    Activation activation,
    DiKey<Object?> key,
  ) {
    final s = state;
    final node = nodeRecord(s, n);
    _checkReadWithinShape(s, node, key);
    return resolve(s, node.scope, key, exclude: Some(n)).match(
      () =>
          Left(Fail<DiFailure>(UnavailableKeyFailure(key), StackTrace.current)),
      (publisher) => _track(s, n, ticket, activation, key, publisher),
    );
  }

  /// An optional read of [key] for the activation of [n].
  Option<Object?> _readOption(
    NodeId n,
    int ticket,
    Activation activation,
    DiKey<Object?> key,
  ) {
    final s = state;
    final node = nodeRecord(s, n);
    _checkReadWithinShape(s, node, key);
    return resolve(s, node.scope, key, exclude: Some(n)).match(
      () {
        // A key that is read while it is unbound stays tracked, so the node
        // loads again when a publisher appears.
        activation.view.update((view) => {...view, key: const None()});
        return const None();
      },
      (publisher) => _track(
        s,
        n,
        ticket,
        activation,
        key,
        publisher,
      ).match((_) => const None(), Some.new),
    );
  }

  /// Records the read of [publisher] for [key]: the dependency, the view, and
  /// the cancel for a pending withdrawal. A read that closes a cycle of
  /// committed reads fails.
  Either<Cause<DiFailure>, Object?> _track(
    RuntimeState s,
    NodeId n,
    int ticket,
    Activation activation,
    DiKey<Object?> key,
    PublisherRef publisher,
  ) {
    final hasReaders = s
        .readersOf(n)
        .any((other) => !nodeRecord(s, other).removed);
    if (hasReaders) {
      final path = readsPath(s, publisher.node, n);
      if (path != null) {
        return Left(
          Fail<DiFailure>(
            DependencyCycleFailure([
              componentOf(s, nodeRecord(s, n)).key,
              for (final node in path) componentOf(s, nodeRecord(s, node)).key,
            ]),
            StackTrace.current,
          ),
        );
      }
    }
    activation.reads.update((reads) => {...reads, publisher.node});
    activation.view.update((view) => {...view, key: Some(publisher)});
    final roots = withdrawalsOf(s, publisher.node);
    if (roots.isNotEmpty) {
      cancel(ticket, CancelReason.withdrawal);
      activation.awaited.update((awaited) => {...awaited, ...roots});
    }
    return Right(nodeRecord(s, publisher.node).value.toNullable());
  }

  /// The future of the next commit of [n], for `whenActive`.
  ///
  /// The callers of one zone share one completer, so a zone that is dead
  /// cannot starve another. A node that is active gives its value now, and a
  /// node that the runtime removed gives a failure.
  Future<Wake> awaitActive(NodeId n) {
    final s = state;
    final node = nodeRecord(s, n);
    if (nodePhase(s, n) == NodePhase.active) {
      return Future.value(Right<DiFailure, Object?>(node.value.toNullable()));
    }
    if (node.removed) {
      return Future.value(
        Left<DiFailure, Object?>(const InactiveNodeFailure()),
      );
    }
    final waiting = _waiters.now[n] ?? const <Zone, Completer<Wake>>{};
    final completer = waiting[Zone.current] ?? Completer<Wake>();
    _waiters.update(
      (all) => {
        ...all,
        n: {...waiting, Zone.current: completer},
      },
    );
    return completer.future;
  }

  /// Completes the callers of `whenActive` that wait for [n] with [wake].
  void _wake(NodeId n, Wake wake) {
    final waiting = _waiters.now[n];
    if (waiting == null) return;
    _waiters.update((all) => {...all}..remove(n));
    for (final completer in waiting.values) {
      completer.complete(wake);
    }
  }

  /// The task that releases [n] and gives the cause of the dispose failures.
  ///
  /// The release withdraws the keys, releases the dependents first, and runs
  /// the dispose functions of the node last. A [permanent] release removes the
  /// node. The task never throws.
  Task<Cause<DiFailure>> deactivate(NodeId n, {required bool permanent}) =>
      Task(() async {
        final before = state;
        final node = nodeRecord(before, n);
        if (node.removed) return const Empty<DiFailure>();
        if (!node.active || node.deactivating) {
          if (permanent && !node.deactivating) {
            apply((s) => removeNode(s, n));
            _wake(n, Left<DiFailure, Object?>(const InactiveNodeFailure()));
          }
          return const Empty<DiFailure>();
        }
        // The keys leave in the transition that starts the release.
        // The token of the committed activation is canceled before the
        // transition that starts the release, so a listener of that transition
        // sees it canceled. The keys leave in the same transition.
        _committed.now[n]?.token.cancel(CancelReason.deactivation);
        // The defect `SilentReleaseStart` replaces the state without a call of
        // the listeners.
        if (RuntimeFaults.injects(Defect.silentReleaseStart)) {
          write((s) => beginRelease(s, n));
        } else {
          apply((s) => beginRelease(s, n));
        }
        var failures = const Empty<DiFailure>() as Cause<DiFailure>;
        // The fault `DependentFirst` starts the release without the release of
        // the dependents.
        if (!RuntimeFaults.breaks(SelfCheckFault.dependentFirst)) {
          for (final dependent in dependentsOf(state, n)) {
            failures += await deactivate(dependent, permanent: false).run();
          }
        }
        assert(
          !RuntimeFaults.checking || _dependentsReleasing(n),
          'SelfCheck DependentFirst: the node ${labelOf(state, n)} releases '
          'while a dependent is active',
        );
        final own = await releaseFor(
          labelOf(state, n),
          nodeRecord(state, n).finalizers,
        ).run();
        apply(
          (s) =>
              endRelease(s, n, ownFailed: !own.isEmpty, permanent: permanent),
        );
        _committed.update((all) => all.without(n));
        if (permanent) {
          _wake(n, Left<DiFailure, Object?>(const InactiveNodeFailure()));
        }
        return failures + own;
      });
}

/// The helpers of the self-checks of the activation and of the release.
extension RuntimeActivationChecks on Runtime {
  /// Whether each dependent of [n] is releasing, so that [n] releases after
  /// them. A dependent that waits for the release of [n] in a read cycle
  /// counts as releasing.
  bool _dependentsReleasing(NodeId n) => dependentsOf(
    state,
    n,
  ).every((dependent) => nodeRecord(state, dependent).deactivating);

  /// Checks inside an `assert` that the node reads a key of its shape. The
  /// fault `ReadsWithinShape` compares with an empty shape.
  void _checkReadWithinShape(
    RuntimeState s,
    NodeRecord node,
    DiKey<Object?> key,
  ) {
    assert(() {
      if (!RuntimeFaults.checking) return true;
      final component = componentOf(s, node);
      final within =
          !RuntimeFaults.breaks(SelfCheckFault.readsWithinShape) &&
          (component.requires.contains(key) ||
              component.optional.contains(key));
      if (!within) {
        throw AssertionError(
          'SelfCheck ReadsWithinShape: ${component.label} reads $key, which '
          'its dependency does not state',
        );
      }
      return true;
    }());
  }
}
