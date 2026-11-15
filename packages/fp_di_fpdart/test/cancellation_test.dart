// Cancellation of the activation of a node (fp_di R-UC-RT-LC-008). Each test
// that names a property of Cancellation.tla bridges its counterexample.
import 'dart:async';

import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fp_di_fpdart/src/cancellation.dart'
    show CancelReason, CancellationSource;
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

const session = DiKey<String>(name: 'session');

/// Collects the node changes that a listener of [scope] sees. Each call of the
/// listener compares `scope.state` with the value that the last call kept.
final class Changes {
  Changes(this.scope) : _last = scope.state {
    rightOf(scope.addListener(_onChange));
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
Component<String> sessionComponent({
  required Future<void> gate,
  required List<String> log,
  bool cooperative = true,
}) => Component<String>(
  key: session,
  dependency: Dependency.cancellation().mapTask<String>(
    (token) => Task(() async {
      log.add('create');
      log.add(
        await Future.any([
          gate.then((_) => 'finished'),
          if (cooperative) token.whenCanceled.run().then((_) => 'stopped'),
        ]),
      );
      return 'me';
    }),
    dispose: (_) => log.add('dispose'),
  ),
);

void main() {
  test('dispose cancels the token at the call and nothing commits', () async {
    // from: cancellation_test.dart: dispose cancels the token at the call and
    // nothing commits (CancelPrompt, NoCommitAfterCancel)
    final log = <String>[];
    final gate = Completer<void>();
    final app = Scope(components: []);
    final changes = Changes(app);
    final child = app.kid(
      components: [sessionComponent(gate: gate.future, log: log)],
    );
    final setup = child.run();
    await pause(1);
    expect(log, ['create']);

    final disposal = child.dispose();
    final canceled = leftOf(await setup);
    rightOf(await disposal);
    expect(canceled.isInterrupted, isTrue);
    expect(canceled.failures, isEmpty, reason: 'a cancel is no failure');
    expect(log, ['create', 'stopped', 'dispose']);
    expect(changes.commits, isEmpty, reason: 'no node activated');
    expect(app.getOption<String>(key: session), isA<None>());
    gate.complete();
    rightOf(await app.dispose());
  });

  test('the token is canceled before dispose() returns', () async {
    // from: cancellation_test.dart: the token is canceled before dispose()
    // returns
    final tokens = <CancellationToken>[];
    final gate = Completer<void>();
    final scope = Scope(
      components: [
        Component<int>.effect(
          dependency: Dependency.cancellation().mapTask<int>(
            (token) => Task(() async {
              tokens.add(token);
              await gate.future;
              return 1;
            }),
          ),
        ),
      ],
    );
    final setup = scope.run();
    await pause(1);
    expect(tokens.single.isCanceled, isFalse);
    final disposal = scope.dispose();
    expect(tokens.single.isCanceled, isTrue, reason: 'synchronous at the call');
    gate.complete();
    expect(leftOf(await setup).isInterrupted, isTrue);
    rightOf(await disposal);
  });

  test('an uncooperative creation settles, is disposed once, and does not '
      'commit', () async {
    // from: cancellation_test.dart: an uncooperative creation settles, is
    // disposed once, and does not commit (LeaseAccounted)
    final log = <String>[];
    final gate = Completer<void>();
    final scope = Scope(
      components: [
        sessionComponent(gate: gate.future, log: log, cooperative: false),
      ],
    );
    final setup = scope.run();
    await pause(1);
    final disposal = scope.dispose();
    gate.complete(); // the creation ignores the token and finishes late
    expect(leftOf(await setup).isInterrupted, isTrue);
    rightOf(await disposal);
    expect(log, ['create', 'finished', 'dispose']);
  });

  test(
    'the token of an active component is canceled when it deactivates',
    () async {
      // from: cancellation_test.dart: the token of an active component is
      // canceled when it deactivates
      final tokens = <CancellationToken>[];
      final scope = Scope(
        components: [
          Component<int>.effect(
            dependency: Dependency.cancellation().map<int>((token) {
              tokens.add(token);
              return 1;
            }),
          ),
        ],
      );
      rightOf(await scope.run());
      expect(tokens.single.isCanceled, isFalse);
      rightOf(await scope.dispose());
      expect(tokens.single.isCanceled, isTrue);
      expect(await tokens.single.whenCanceled.run(), unit);
    },
  );

  test('the token of a committed activation is canceled before its first '
      'dispose function, on a rebuild too', () async {
    // The gap of the first shell: the committed activation cancels at the
    // start of its release, for each trigger (inventory 6.2).
    const version = DiKey<int>(name: 'version');
    final seen = <bool>[];
    final tokens = <CancellationToken>[];
    final root = Scope(
      components: [Component<int>.value(value: 1, key: version)],
    );
    final mid = root.kid(
      components: [Component<int>.value(value: 2, key: version)],
    );
    final leaf = mid.kid(
      components: [
        Component<int>.effect(
          dependency:
              (
                Dependency.cancellation(),
                Dependency.require<int>(key: version),
              ).zip.mapN<int>((token, v) {
                tokens.add(token);
                return v;
              }, dispose: (_) => seen.add(tokens.last.isCanceled)),
        ),
      ],
    );
    rightOf(await root.run());
    rightOf(await leaf.run());
    expect(tokens.single.isCanceled, isFalse);
    // The target changes: the node releases and activates again.
    rightOf(await mid.run());
    expect(seen, [true], reason: 'canceled before the dispose function');
    expect(tokens.first.isCanceled, isTrue);
    expect(tokens, hasLength(2));
    expect(tokens.last.isCanceled, isFalse, reason: 'a token for each episode');
    // A withdrawal deactivates the node, too.
    rightOf(await rightOf(mid.node<int>(key: version)).dispose());
    expect(seen, [true, true]);
    // The reader activated again against the publisher of the root.
    expect(tokens, hasLength(3));
    expect(tokens[1].isCanceled, isTrue);
    expect(tokens.last.isCanceled, isFalse);
    rightOf(await root.dispose());
  });

  test('a listener of the transition that starts a release sees the token '
      'canceled', () async {
    final tokens = <CancellationToken>[];
    final seen = <bool>[];
    final scope = Scope(
      components: [
        Component<int>.effect(
          dependency: Dependency.cancellation().map<int>((token) {
            tokens.add(token);
            return 1;
          }),
        ),
      ],
    );
    rightOf(await scope.run());
    rightOf(
      scope.addListener(() {
        if (scope.nodes.single.state.phase == NodePhase.deactivating) {
          seen.add(tokens.single.isCanceled);
        }
      }),
    );
    rightOf(await scope.nodes.single.dispose());
    expect(seen, [true]);
    rightOf(await scope.dispose());
  });

  group('failure regions', () {
    test('a failed step cancels the token before the first inverse', () async {
      // from: cancellation_test.dart: a failed step cancels the token before
      // the first inverse (SignalBeforeInverse)
      final seenAtDispose = <bool>[];
      final scope = Scope(
        components: [
          Component<int>.effect(
            dependency: Dependency.cancellation()
                .map<CancellationToken>(
                  (token) => token,
                  dispose: (token) => seenAtDispose.add(token.isCanceled),
                )
                .map<int>((_) => throw StateError('second step failed')),
          ),
        ],
      );
      final cause = leftOf(await scope.run());
      expect(
        cause.only,
        isA<ActivationFailure>(),
        reason: 'a failure stays an activation failure',
      );
      expect(cause.isInterrupted, isFalse);
      expect(seenAtDispose, [true]);
      rightOf(await scope.dispose());
    });
  });

  group('withdrawal', () {
    const value = DiKey<int>(name: 'value');
    const reader = DiKey<int>(name: 'reader');

    test('disposing a publisher cancels an in-flight reader, which waits for '
        'the withdrawal and then reads the fallback', () async {
      // from: cancellation_test.dart: disposing a publisher cancels an
      // in-flight reader, which waits for the withdrawal and then reads the
      // fallback (CancelPropagatesToDependents, NoCancelLivelock)
      final gate = Completer<void>();
      final seen = <int>[];
      final root = Scope(
        components: [Component<int>.value(value: 2, key: value)],
      );
      final mid = root.kid(
        components: [Component<int>.value(value: 1, key: value)],
      );
      final child = mid.kid(
        components: [
          Component<int>(
            key: reader,
            dependency:
                (
                  Dependency.require<int>(key: value),
                  Dependency.cancellation(),
                ).zip.mapTask<int>(
                  (pair) => Task(() async {
                    seen.add(pair.$1);
                    await Future.any([gate.future, pair.$2.whenCanceled.run()]);
                    return pair.$1;
                  }),
                ),
          ),
        ],
      );
      rightOf(await root.run());
      rightOf(await mid.run());
      final setup = child.run();
      await pause(1);
      expect(seen, [1], reason: 'the reader started with the nearer value');

      final withdrawal = rightOf(mid.node<int>(key: value)).dispose();
      // The reader is canceled, rolls back, and stays inactive: the run
      // succeeds without committing the departing value.
      rightOf(await setup);
      expect(child.nodes.single.isActive, isFalse);
      expect(seen, [1], reason: 'no reactivation before the withdrawal');

      // The withdrawal reconciles: the reader activates with the fallback.
      gate.complete();
      rightOf(await withdrawal);
      expect(rightOf(child.get<int>(key: reader)), 2, reason: 'the fallback');
      expect(seen, [1, 2]);
      rightOf(await root.dispose());
    });

    test(
      'a reader of an active dependent of the publisher is canceled too',
      () async {
        // from: cancellation_test.dart: a reader of an active dependent of the
        // publisher is canceled too
        final gate = Completer<void>();
        final root = Scope(
          components: [Component<int>.value(value: 1, key: value)],
        );
        const doubled = DiKey<int>(name: 'doubled');
        final mid = root.kid(
          components: [
            Component<int>(
              key: doubled,
              dependency: Dependency.require<int>(
                key: value,
              ).map<int>((v) => v * 2),
            ),
          ],
        );
        var runs = 0;
        final child = mid.kid(
          components: [
            Component<int>(
              key: reader,
              dependency:
                  (
                    Dependency.require<int>(key: doubled),
                    Dependency.cancellation(),
                  ).zip.mapTask<int>(
                    (pair) => Task(() async {
                      runs++;
                      await Future.any([
                        gate.future,
                        pair.$2.whenCanceled.run(),
                      ]);
                      return pair.$1;
                    }),
                  ),
            ),
          ],
        );
        rightOf(await root.run());
        rightOf(await mid.run());
        final setup = child.run();
        await pause(1);
        final withdrawal = rightOf(root.node<int>(key: value)).dispose();
        rightOf(await setup);
        rightOf(await withdrawal);
        expect(runs, 1, reason: 'canceled, and waiting without a value');
        expect(child.nodes.single.missing, [doubled]);
        gate.complete();
        rightOf(await root.dispose());
      },
    );

    test('a canceled activation is not named a failure', () async {
      // from: observation_test.dart: a canceled activation is not named a
      // failure
      final readerGate = Completer<void>();
      final rollbackGate = Completer<void>();
      final withdrawalGate = Completer<void>();
      final root = Scope(
        components: [Component<int>.value(value: 2, key: value)],
      );
      final errors = <Cause<DiFailure>>[];
      final subscription = root.errors.listen(errors.add);
      // The publisher holds its own withdrawal open.
      final mid = root.kid(
        components: [
          Component<int>(
            key: value,
            dependency: Dependency<int>(
              create: () => 1,
              dispose: (_) => withdrawalGate.future,
            ),
          ),
        ],
      );
      // The reader holds its own rollback open, and waits for the gate or the
      // cancellation.
      final child = mid.kid(
        components: [
          Component<int>.effect(
            debugLabel: 'reader',
            dependency:
                (
                  Dependency.require<int>(
                    key: value,
                  ).map<int>((v) => v, dispose: (_) => rollbackGate.future),
                  Dependency.cancellation(),
                ).zip.mapTask<int>(
                  (pair) => Task(() async {
                    await Future.any([
                      readerGate.future,
                      pair.$2.whenCanceled.run(),
                    ]);
                    return pair.$1;
                  }),
                ),
          ),
        ],
      );
      // The entry of the reader.
      String state() => rightOf(
        child.describe(),
      ).split('\n').lastWhere((line) => line.contains('- reader:'));
      var setupDone = false;

      rightOf(await root.run());
      rightOf(await mid.run());
      final setup = child.run().whenComplete(() => setupDone = true);
      await pause(1);
      expect(state(), '  - reader: activating');

      final withdrawal = rightOf(mid.node<int>(key: value)).dispose();
      await pause(1);
      // The token is canceled, and the rollback waits for its dispose
      // function.
      expect(setupDone, isFalse);
      expect(state(), '  - reader: activating');

      rollbackGate.complete();
      rightOf(await setup);
      await pause(1);
      // The node waits for the withdrawal to end. Nothing failed.
      expect(state(), '  - reader: inactive');
      expect(child.nodes.single.state.phase, NodePhase.inactive);

      readerGate.complete();
      withdrawalGate.complete();
      rightOf(await withdrawal);
      expect(state(), '  - reader: active');
      expect(child.nodes.single.state.phase, NodePhase.active);
      expect(errors, isEmpty);
      await subscription.cancel();
      rightOf(await root.dispose());
    });
  });

  group('tokens outside the runtime', () {
    /// A cancelable function, written once and called by a component and by a
    /// test.
    Future<String> login(CancellationToken token) async {
      await Future.any([
        Future<void>.delayed(const Duration(seconds: 5)),
        token.whenCanceled.run(),
      ]);
      return token.isCanceled ? 'aborted' : 'me';
    }

    test('a controller cancels its token once', () async {
      // from: cancellation_test.dart: a controller cancels its token once
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
      // from: cancellation_test.dart: CancellationToken.none is never
      // canceled
      final none = CancellationToken.none;
      expect(none.isCanceled, isFalse);
      var completed = false;
      unawaited(none.whenCanceled.run().then((_) => completed = true));
      await pause(1);
      expect(completed, isFalse);
      expect(identical(CancellationToken.none, none), isTrue);
    });

    test('whenCanceled is a lazy task that completes for each run', () async {
      final controller = CancellationController();
      final task = controller.token.whenCanceled;
      var first = false;
      var second = false;
      unawaited(task.run().then((_) => first = true));
      unawaited(task.run().then((_) => second = true));
      await pause(1);
      expect([first, second], [false, false]);
      controller.cancel();
      await pause(1);
      expect([first, second], [true, true]);
      // A task of a token that is canceled completes at once.
      expect(await task.run(), unit);
    });

    test('a child token follows its parent and can fail on its own', () async {
      final parent = CancellationController();
      final child = CancellationSource.child(parent.token);
      expect(child.isCanceled, isFalse);
      parent.cancel();
      await pause(1);
      expect(child.isCanceled, isTrue);
      expect(child.reason, const Some(CancelReason.owner));

      final alone = CancellationSource.child(CancellationToken.none)
        ..cancel(CancelReason.failure);
      expect(alone.reason, const Some(CancelReason.failure));
      alone.cancel(CancelReason.owner);
      expect(alone.reason, const Some(CancelReason.failure), reason: 'first');
      expect(CancellationSource.child(parent.token).isCanceled, isTrue);
    });
  });
}
