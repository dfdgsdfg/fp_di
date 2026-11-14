// Cancellation on owner disposal (R-UC-RT-LC-008, phase A). Each test names
// the Cancellation.tla property whose counterexample it bridges.
import 'dart:async';

import 'package:fp_di/fp_di.dart';
import 'package:test/test.dart';

final _session = DiKey<String>(name: 'session');

/// Collects the node changes that a listener of [scope] sees. Each call of the
/// listener compares `scope.state` with the value that the last call kept.
final class _Changes {
  _Changes(this.scope) : _last = scope.state {
    scope.addListener(_onChange);
  }

  final Scope scope;
  ScopeState _last;

  /// The (earlier, later) pairs of every changed node, in call order.
  final pairs = <(NodeState?, NodeState?)>[];

  void _onChange() {
    final now = scope.state;
    pairs.addAll(now.changedSince(_last));
    _last = now;
  }

  /// The states in which a node committed an activation.
  List<NodeState> get commits => [
    for (final (earlier, later) in pairs)
      if (later != null && later.commits > (earlier?.commits ?? 0)) later,
  ];
}

/// A session whose creation waits for [gate] or for the token.
Component<String> _sessionComponent({
  required Future<void> gate,
  required List<String> log,
  bool cooperative = true,
}) => Component<String>(
  key: _session,
  dependency: Dependency.cancellation().map((token) async {
    log.add('create');
    log.add(
      await Future.any([
        gate.then((_) => 'finished'),
        if (cooperative) token.whenCanceled.then((_) => 'stopped'),
      ]),
    );
    return 'me';
  }, dispose: (_) => log.add('dispose')),
);

void main() {
  test('dispose cancels the token at the call and nothing commits '
      '(CancelPrompt, NoCommitAfterCancel)', () async {
    final log = <String>[];
    final gate = Completer<void>();
    final app = Scope();
    final changes = _Changes(app);
    final session = app.child(
      module: Module(
        components: [_sessionComponent(gate: gate.future, log: log)],
      ),
    );
    final setup = session.initialize();
    final outcome = expectLater(
      setup,
      throwsA(isA<ActivationCanceledException>()),
    );
    await Future<void>.delayed(Duration.zero);
    expect(log, ['create']);

    final disposal = session.dispose();
    await outcome;
    await disposal;
    expect(log, ['create', 'stopped', 'dispose']);
    expect(changes.commits, isEmpty, reason: 'no node activated');
    expect(
      changes.commits.where((node) => node.key != null),
      isEmpty,
      reason: 'no key became available',
    );
    expect(app.maybeGet<String>(key: _session), isNull);
    gate.complete();
    await app.dispose();
  });

  test('the token is canceled before dispose() returns', () async {
    final tokens = <CancellationToken>[];
    final gate = Completer<void>();
    final scope = Scope(
      module: Module(
        components: [
          Component<int>.effect(
            dependency: Dependency.cancellation().map((token) async {
              tokens.add(token);
              await gate.future;
              return 1;
            }),
          ),
        ],
      ),
    );
    final setup = scope.initialize().then<Object?>(
      (_) => null,
      onError: (Object e) => e,
    );
    await Future<void>.delayed(Duration.zero);
    expect(tokens.single.isCanceled, isFalse);
    final disposal = scope.dispose();
    expect(tokens.single.isCanceled, isTrue, reason: 'synchronous at the call');
    gate.complete();
    expect(await setup, isA<ActivationCanceledException>());
    await disposal;
  });

  test('an uncooperative creation settles, is disposed once, and does not '
      'commit (LeaseAccounted)', () async {
    final log = <String>[];
    final gate = Completer<void>();
    final session = Scope(
      module: Module(
        components: [
          _sessionComponent(gate: gate.future, log: log, cooperative: false),
        ],
      ),
    );
    final setup = session.initialize().then<Object?>(
      (_) => null,
      onError: (Object e) => e,
    );
    await Future<void>.delayed(Duration.zero);
    final disposal = session.dispose();
    gate.complete(); // the creation ignores the token and finishes late
    expect(await setup, isA<ActivationCanceledException>());
    await disposal;
    expect(log, ['create', 'finished', 'dispose']);
  });

  test(
    'a setup queued behind the disposal never runs (NoSetupAfterCancel)',
    () async {
      final log = <String>[];
      final hold = Completer<void>();
      final app = Scope(
        module: Module(
          components: [
            Component<int>.effect(
              dependency: Dependency(
                create: () async {
                  await hold.future;
                  return 0;
                },
              ),
            ),
          ],
        ),
      );
      final busy = app.initialize(); // occupies the queue
      final session = app.child(
        module: Module(
          components: [
            _sessionComponent(gate: Completer<void>().future, log: log),
          ],
        ),
      );
      final setup = session.initialize().then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      final disposal = session.dispose(); // requested before the setup starts
      hold.complete();
      await busy;
      expect(await setup, isA<ActivationCanceledException>());
      await disposal;
      expect(log, isEmpty, reason: 'the setup never ran');
      expect(
        session.initialize,
        throwsA(isA<DisposedScopeError>()),
        reason: 'a new call after the disposal is rejected',
      );
      await app.dispose();
    },
  );

  test(
    'no step starts after the token is canceled (NoStepAfterCancel)',
    () async {
      final log = <String>[];
      final gate = Completer<void>();
      final scope = Scope(
        module: Module(
          components: [
            Component<int>.effect(
              dependency:
                  Dependency<int>(
                    create: () async {
                      log.add('first');
                      await gate.future;
                      return 1;
                    },
                    dispose: (_) => log.add('dispose first'),
                  ).map((v) {
                    log.add('second');
                    return v + 1;
                  }, dispose: (_) => log.add('dispose second')),
            ),
          ],
        ),
      );
      final setup = scope.initialize().then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      await Future<void>.delayed(Duration.zero);
      final disposal = scope.dispose();
      gate.complete();
      expect(await setup, isA<ActivationCanceledException>());
      await disposal;
      expect(log, ['first', 'dispose first']);
    },
  );

  test('the next setup starts after the canceled rollback finishes '
      '(CleanupBeforeNextSetup)', () async {
    final log = <String>[];
    final gate = Completer<void>();
    final app = Scope();
    await app.initialize();
    final first = app.child(
      module: Module(
        components: [_sessionComponent(gate: gate.future, log: log)],
      ),
    );
    final firstSetup = first.initialize().then<Object?>(
      (_) => null,
      onError: (Object e) => e,
    );
    await Future<void>.delayed(Duration.zero);
    final logout = first.dispose();
    final second = app.child(
      module: Module(
        components: [
          Component<String>(
            key: _session,
            dependency: Dependency(
              create: () {
                log.add('create second');
                return 'you';
              },
            ),
          ),
        ],
      ),
    );
    await second.initialize();
    expect(await firstSetup, isA<ActivationCanceledException>());
    await logout;
    expect(log, ['create', 'stopped', 'dispose', 'create second']);
    expect(second.get<String>(key: _session), 'you');
    await app.dispose();
  });

  test(
    'the token of an active component is canceled when it deactivates',
    () async {
      final tokens = <CancellationToken>[];
      final scope = await Scope(
        module: Module(
          components: [
            Component<int>.effect(
              dependency: Dependency.cancellation().map((token) {
                tokens.add(token);
                return 1;
              }),
            ),
          ],
        ),
      ).initialize();
      expect(tokens.single.isCanceled, isFalse);
      await scope.dispose();
      expect(tokens.single.isCanceled, isTrue);
      await tokens.single.whenCanceled;
    },
  );

  test(
    'a canceled automatic activation is not reported as a failure',
    () async {
      final key = DiKey<int>(name: 'value');
      final gate = Completer<void>();
      final root = Scope(
        module: Module(components: [Component.value(value: 1, key: key)]),
      );
      final consumers = root.child(
        module: Module(
          components: [
            Component<int>(
              key: DiKey<int>(name: 'consumer'),
              dependency: Dependency.require<int>(key: key).map((v) async {
                await gate.future;
                return v;
              }),
            ),
          ],
        ),
      );
      final errors = <DiException>[];
      final subscription = root.errors.listen(errors.add);
      await consumers.initialize(); // waits for the parent's key
      final wake = root.initialize(); // activates the consumer automatically
      await Future<void>.delayed(Duration.zero);
      final disposal = consumers.dispose();
      gate.complete();
      await wake;
      await disposal;
      await Future<void>.delayed(Duration.zero);
      expect(root.isInitialized, isTrue);
      expect(errors, isEmpty);
      await subscription.cancel();
      await root.dispose();
    },
  );

  group('withdrawal', () {
    final value = DiKey<int>(name: 'value');
    final reader = DiKey<int>(name: 'reader');

    test('disposing a publisher cancels an in-flight reader, which waits for '
        'the withdrawal and then reads the fallback '
        '(CancelPropagatesToDependents, NoCancelLivelock)', () async {
      final gate = Completer<void>();
      final seen = <int>[];
      final root = Scope(
        module: Module(components: [Component.value(value: 2, key: value)]),
      );
      final mid = root.child(
        module: Module(components: [Component.value(value: 1, key: value)]),
      );
      final child = mid.child(
        module: Module(
          components: [
            Component<int>(
              key: reader,
              dependency:
                  (
                    Dependency.require<int>(key: value),
                    Dependency.cancellation(),
                  ).zip.mapN((v, token) async {
                    seen.add(v);
                    await Future.any([gate.future, token.whenCanceled]);
                    return v;
                  }),
            ),
          ],
        ),
      );
      await root.initialize();
      await mid.initialize();
      final setup = child.initialize();
      await Future<void>.delayed(Duration.zero);
      expect(seen, [1], reason: 'the reader started with the nearer value');

      final withdrawal = mid.node(key: value).dispose();
      // The reader is canceled, rolls back, and stays inactive: initialize
      // succeeds without committing the departing value.
      await setup;
      expect(child.nodes.single.isActive, isFalse);
      expect(seen, [1], reason: 'no reactivation before the withdrawal');

      // The withdrawal reconciles: the reader activates with the fallback.
      gate.complete();
      await withdrawal;
      expect(child.get<int>(key: reader), 2, reason: 'the fallback');
      expect(seen, [1, 2]);
      await root.dispose();
    });

    test(
      'a reader of an active dependent of the publisher is canceled too',
      () async {
        final gate = Completer<void>();
        final root = Scope(
          module: Module(components: [Component.value(value: 1, key: value)]),
        );
        final doubled = DiKey<int>(name: 'doubled');
        final mid = root.child(
          module: Module(
            components: [
              Component<int>(
                key: doubled,
                dependency: Dependency.require<int>(
                  key: value,
                ).map((v) => v * 2),
              ),
            ],
          ),
        );
        var runs = 0;
        final child = mid.child(
          module: Module(
            components: [
              Component<int>(
                key: reader,
                dependency:
                    (
                      Dependency.require<int>(key: doubled),
                      Dependency.cancellation(),
                    ).zip.mapN((v, token) async {
                      runs++;
                      await Future.any([gate.future, token.whenCanceled]);
                      return v;
                    }),
              ),
            ],
          ),
        );
        await root.initialize();
        await mid.initialize();
        final setup = child.initialize();
        await Future<void>.delayed(Duration.zero);
        final withdrawal = root.node(key: value).dispose();
        await setup;
        await withdrawal;
        expect(runs, 1, reason: 'canceled, and waiting without a value');
        expect(child.nodes.single.missing, [doubled]);
        gate.complete();
        await root.dispose();
      },
    );
  });

  group('failure regions', () {
    test('a failed step cancels the token before the first inverse '
        '(SignalBeforeInverse)', () async {
      final seenAtDispose = <bool>[];
      final scope = Scope(
        module: Module(
          components: [
            Component<int>.effect(
              dependency: Dependency.cancellation()
                  .map(
                    (token) => token,
                    dispose: (token) => seenAtDispose.add(token.isCanceled),
                  )
                  .map((_) => throw StateError('second step failed')),
            ),
          ],
        ),
      );
      await expectLater(
        scope.initialize(),
        throwsA(
          isA<ActivationException>().having(
            (e) => e.cause,
            'cause',
            isA<StateError>(),
          ),
        ),
        reason: 'a failure stays an activation failure',
      );
      expect(seenAtDispose, [true]);
      await scope.dispose();
    });

    test('a failed Lazy creation cancels only its own region and leaves the '
        'owner active (CaughtFailureIsolated)', () async {
      final ownerTokens = <CancellationToken>[];
      final seenAtDispose = <bool>[];
      var attempts = 0;
      final lazyKey = DiKey<Lazy<int>>();
      final scope = await Scope(
        module: Module(
          components: [
            Component<Lazy<int>>(
              key: lazyKey,
              dependency: Dependency.cancellation()
                  .map((token) {
                    ownerTokens.add(token);
                    return token;
                  }, dispose: (token) => seenAtDispose.add(token.isCanceled))
                  .map((_) {
                    if (++attempts == 1) throw StateError('first force');
                    return 7;
                  })
                  .lazy(),
            ),
          ],
        ),
      ).initialize();
      final lazy = scope.get(key: lazyKey);
      await expectLater(lazy.force(), throwsA(isA<StateError>()));
      expect(seenAtDispose, [true], reason: 'the region token, before dispose');
      expect(ownerTokens.single.isCanceled, isTrue);
      expect(scope.nodes.single.isActive, isTrue, reason: 'owner stays');
      expect(await lazy.force(), 7, reason: 'a failure is not cached');
      expect(ownerTokens.last.isCanceled, isFalse);
      await scope.dispose();
    });

    test('disposing the owner stops a Lazy creation in flight', () async {
      final gate = Completer<void>();
      final lazyKey = DiKey<Lazy<String>>();
      final log = <String>[];
      final scope = await Scope(
        module: Module(
          components: [
            Component<Lazy<String>>(
              key: lazyKey,
              dependency: Dependency.cancellation().map((token) async {
                log.add('create');
                await Future.any([gate.future, token.whenCanceled]);
                log.add(token.isCanceled ? 'stopped' : 'finished');
                return 'value';
              }).lazy(),
            ),
          ],
        ),
      ).initialize();
      final forced = scope.get(key: lazyKey).force();
      final outcome = expectLater(
        forced,
        throwsA(isA<DisposedLazyException>()),
      );
      await Future<void>.delayed(Duration.zero);
      await scope.dispose();
      await outcome;
      expect(log, ['create', 'stopped']);
      gate.complete();
    });
  });

  group('integration histories', () {
    // Bridges Integration.tla: a canceled activation, the failure of its
    // late release, and the callers that share one disposal.
    test('owner cancel: the late release failure reaches initialize, and two '
        'dispose callers share one result '
        '(RecipientsExact, CallersAgree, ReleaseAtMostOnce)', () async {
      final gate = Completer<void>();
      var releases = 0;
      final lateError = StateError('late release failed');
      final scope = Scope(
        module: Module(
          components: [
            Component<int>.effect(
              dependency: Dependency<int>(
                create: () async {
                  await gate.future; // ignores the cancellation token
                  return 1;
                },
                dispose: (_) {
                  releases++;
                  throw lateError;
                },
              ),
            ),
          ],
        ),
      );
      final changes = _Changes(scope);
      final setup = scope.initialize().then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      await Future<void>.delayed(Duration.zero);
      expect(releases, 0);

      final first = scope.dispose().then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      final second = scope.dispose().then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      gate.complete();

      final canceled = await setup;
      expect(canceled, isA<ActivationCanceledException>());
      expect(
        (canceled as ActivationCanceledException).rollbackFailures.map(
          (failure) => failure.error,
        ),
        [lateError],
        reason: 'the late release failure goes to the initialize caller',
      );
      expect(await first, isNull);
      expect(await second, isNull, reason: 'both callers share one result');
      expect(releases, 1, reason: 'the late lease is released once');
      expect(changes.commits, isEmpty, reason: 'no node activated');
      expect(scope.nodes.where((m) => m.isActive), isEmpty);
    });

    test('withdrawal cancel: the late release failure of the reader goes to '
        'errors, the release failure of the publisher to both dispose '
        'callers, and the reader activates again after the withdrawal '
        '(RecipientsExact, NoReactivateBeforeWithdrawal)', () async {
      final value = DiKey<int>(name: 'value');
      final reader = DiKey<int>(name: 'reader');
      final gate = Completer<void>();
      final log = <String>[];
      final pubError = StateError('publisher release failed');
      final lateError = StateError('late release failed');
      final root = Scope(
        module: Module(
          components: [
            Component<int>(
              key: value,
              dependency: Dependency<int>(
                create: () => 1,
                dispose: (_) {
                  log.add('release publisher');
                  throw pubError;
                },
              ),
            ),
          ],
        ),
      );
      final child = root.child(
        module: Module(
          components: [
            Component<int>(
              key: reader,
              dependency: Dependency.maybe<int>(key: value).map(
                (v) async {
                  log.add('create reader ${v ?? 'fallback'}');
                  await gate.future; // ignores the cancellation token
                  return v ?? -1;
                },
                dispose: (_) {
                  log.add('release reader');
                  throw lateError;
                },
              ),
            ),
          ],
        ),
      );
      await root.initialize();
      final errors = <DiException>[];
      final subscription = root.errors.listen(errors.add);
      final setup = child.initialize();
      await Future<void>.delayed(Duration.zero);
      expect(log, ['create reader 1']);

      final publisher = root.node(key: value);
      final first = publisher.dispose().then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      final second = publisher.dispose().then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      gate.complete();

      await setup; // the withdrawn reader stays inactive: initialize succeeds
      final one = await first;
      final two = await second;
      await Future<void>.delayed(Duration.zero);

      expect(one, isA<DisposeException>());
      expect(identical(one, two), isTrue, reason: 'one shared result');
      expect(
        (one as DisposeException).disposeFailures.map(
          (failure) => failure.error,
        ),
        [pubError],
        reason: 'only the publisher release; not the late one of the reader',
      );
      expect(errors, hasLength(1));
      expect(errors.single, isA<DisposeException>());
      expect(
        (errors.single as DisposeException).disposeFailures.map(
          (failure) => failure.error,
        ),
        [lateError],
        reason: 'the late release of the reader reaches errors',
      );
      expect(log, [
        'create reader 1',
        'release reader',
        'release publisher',
        'create reader fallback',
      ], reason: 'the reader reactivates only after the publisher released');
      expect(child.get<int>(key: reader), -1, reason: 'the fallback');
      await subscription.cancel();
      try {
        await root.dispose();
      } on DisposeException {
        // the reactivated reader release fails again; not under test
      }
    });
  });

  group('tokens outside the runtime', () {
    /// A cancelable function, written once and called by a component and by
    /// a test.
    Future<String> login(CancellationToken token) async {
      await Future.any([
        Future<void>.delayed(const Duration(seconds: 5)),
        token.whenCanceled,
      ]);
      return token.isCanceled ? 'aborted' : 'me';
    }

    test('a controller cancels its token once', () async {
      final controller = CancellationController();
      final result = login(controller.token);
      expect(controller.token.isCanceled, isFalse);
      controller
        ..cancel()
        ..cancel();
      expect(controller.isCanceled, isTrue);
      expect(controller.token.isCanceled, isTrue);
      expect(await result, 'aborted');
    });

    test('CancellationToken.none is never canceled', () async {
      final none = CancellationToken.none;
      expect(none.isCanceled, isFalse);
      var completed = false;
      unawaited(none.whenCanceled.then((_) => completed = true));
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      expect(identical(CancellationToken.none, none), isTrue);
    });
  });
}
