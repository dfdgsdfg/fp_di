import 'dart:async';

import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

const count = DiKey<int>(name: 'count');
const text = DiKey<String>(name: 'text');

DiKey<int> k(String name) => DiKey<int>(name: name);

/// A member that publishes `k(name)`, reads [reads], and logs its release.
/// The release waits for [gate] or [delay], and throws [fail] when it is set.
Component<int> member(
  String name,
  List<String> log, {
  List<String> reads = const [],
  Future<void>? gate,
  Duration delay = Duration.zero,
  Object? fail,
}) {
  Future<void> release(int _) async {
    log.add('start $name');
    await (gate ?? Future<void>.delayed(delay));
    log.add('end $name');
    if (fail != null) throw fail;
  }

  final Dependency<int> dependency = switch (reads) {
    [] => Dependency<int>(create: () => 0, dispose: release),
    [final only] => Dependency.require<int>(
      key: k(only),
    ).map<int>((v) => v + 1, dispose: release),
    [final a, final b] => (
      Dependency.require<int>(key: k(a)),
      Dependency.require<int>(key: k(b)),
    ).zip.mapN<int>((x, y) => x + y, dispose: release),
    _ => throw ArgumentError('at most two reads'),
  };
  return Component<int>(key: k(name), debugLabel: name, dependency: dependency);
}

/// A component that fails its dispose function with the cause that a
/// lifecycle call of [action] returned. It turns a `Left` into a throw.
FutureOr<void> Function(Object?) releaseWith(
  Future<Exit<DiFailure, Object?>> Function() action,
) => (_) async {
  final exit = await action();
  exit.match((cause) => throw cause, (_) {});
};

void main() {
  group('mutation queue', () {
    test('concurrent lifecycle mutations are serialized', () async {
      // from: core_test.dart: concurrent lifecycle mutations are serialized
      final started = Completer<void>();
      final release = Completer<void>();
      final events = <String>[];
      final root = Scope(
        components: [
          Component<int>(
            key: k('first'),
            dependency: Dependency<int>(
              create: () async {
                events.add('first start');
                started.complete();
                await release.future;
                events.add('first end');
                return 1;
              },
            ),
          ),
        ],
      );
      final other = root.kid(
        components: [
          Component<int>(
            key: k('second'),
            dependency: Dependency<int>(
              create: () {
                events.add('second');
                return 2;
              },
            ),
          ),
        ],
      );
      final first = root.run();
      await started.future;
      final second = other.run();
      await pause(1);
      expect(events, ['first start']);
      release.complete();
      await Future.wait([first, second]);
      expect(events, ['first start', 'first end', 'second']);
      rightOf(await root.dispose());
    });

    test(
      'an unrelated caller may queue while a mutation is in flight',
      () async {
        // from: regression_test.dart: an unrelated caller may queue while a
        // mutation is in flight
        final release = Completer<void>();
        final root = Scope(
          components: [
            Component<int>(
              key: k('slow'),
              dependency: Dependency<int>(
                create: () async {
                  await release.future;
                  return 1;
                },
              ),
            ),
          ],
        );
        final other = root.kid(
          components: [Component<int>.value(value: 2, key: k('queued'))],
        );
        final slow = root.run();
        // Issued from outside the mutation: it must queue, not fail.
        final queued = other.run();
        release.complete();
        rightOf(await slow);
        rightOf(await queued);
        expect(rightOf(other.get<int>(key: k('queued'))), 2);
        rightOf(await root.dispose());
      },
    );

    test('a nested mutation reports instead of deadlocking', () async {
      // from: regression_test.dart: a nested mutation reports instead of
      // deadlocking
      final root = Scope(components: []);
      final other = root.kid(
        components: [Component<int>.value(value: 1, key: count)],
      );
      final outer = root.kid(
        components: [
          Component<int>.effect(
            dependency: Dependency<int>(
              create: () async {
                final nested = await other.run();
                // The failure of the nested call is a value: the member fails
                // with it.
                return nested.match((cause) => throw cause, (_) => 2);
              },
            ),
          ),
        ],
      );
      final cause = leftOf(
        await outer.run().timeout(const Duration(seconds: 5)),
      );
      final failure = cause.failures.single as ActivationFailure;
      expect(
        (failure.error! as Cause<DiFailure>).only,
        isA<ReentrantMutationFailure>().having(
          (f) => f.operation,
          'operation',
          'run',
        ),
      );
      expect(other.phase, ScopePhase.declared, reason: 'nothing changed');
      rightOf(await root.dispose());
    });

    test(
      'a nested mutation from a release reports instead of deadlocking',
      () async {
        // from: regression_test.dart: a nested mutation from a release reports
        // instead of deadlocking
        final root = Scope(components: []);
        final other = root.kid(
          components: [Component<int>.value(value: 9, key: count)],
        );
        final scope = root.kid(
          components: [
            Component<int>.effect(
              dependency: Dependency<int>(
                create: () => 0,
                dispose: releaseWith(other.run),
              ),
            ),
          ],
        );
        rightOf(await scope.run());
        final node = scope.nodes.single;
        final cause = leftOf(
          await node.dispose().timeout(const Duration(seconds: 5)),
        );
        final failure = cause.defects.single as DisposeFailure;
        expect(
          (failure.error as Cause<DiFailure>).only,
          isA<ReentrantMutationFailure>(),
        );
        rightOf(await root.dispose());
      },
    );

    test('a rejected reentrant dispose leaves its target unchanged', () async {
      // from: review_regression_test.dart: 3. a rejected reentrant dispose()
      // leaves its target unchanged
      late final Scope target;
      Object? rejected;
      final caller = Scope(
        components: [
          Component<int>.effect(
            dependency: Dependency<int>(
              create: () async {
                rejected = (await target.dispose()).match(
                  (cause) => cause.only,
                  (_) => null,
                );
                return 0;
              },
            ),
          ),
        ],
      );
      target = caller.kid(); // the same runtime as the caller
      rightOf(await caller.run());
      expect(rejected, isA<ReentrantMutationFailure>());
      rightOf(await target.run()); // not disposed, so it runs
      expect(target.isInitialized, isTrue);
      rightOf(await caller.dispose());
    });

    test('a callback registered in a finished mutation may mutate', () async {
      // from: review_regression_test.dart: 5. a callback registered in a
      // finished mutation may mutate
      final events = StreamController<void>.broadcast();
      late final Scope target;
      final done = Completer<Object?>();
      final root = Scope(
        components: [
          Component<StreamSubscription<void>>.effect(
            dependency: Dependency<StreamSubscription<void>>(
              create: () => events.stream.listen((_) {
                target.run().then(
                  (exit) => done.complete(exit.match((c) => c, (_) => null)),
                );
              }),
              dispose: (subscription) => subscription.cancel(),
            ),
          ),
        ],
      );
      target = root.kid(); // the same runtime as the listener
      rightOf(await root.run());
      events.add(null); // after the run has finished
      expect(await done.future, isNull);
      expect(target.isInitialized, isTrue);
      rightOf(await root.dispose());
      await events.close();
    });

    test(
      'a dispose from inside its own disposal is reentrant: scope',
      () async {
        // from: review_regression_test.dart: scope
        late final Scope scope;
        scope = Scope(
          components: [
            Component<int>.effect(
              dependency: Dependency<int>(
                create: () => 1,
                dispose: releaseWith(() => scope.dispose()),
              ),
            ),
          ],
        );
        rightOf(await scope.run());
        final cause = leftOf(
          await scope.dispose().timeout(const Duration(seconds: 2)),
        );
        final failure = cause.defects.single as DisposeFailure;
        expect(
          (failure.error as Cause<DiFailure>).only,
          isA<ReentrantMutationFailure>().having(
            (f) => f.operation,
            'operation',
            'Scope.dispose',
          ),
        );
      },
    );

    test(
      'a dispose from inside its own disposal is reentrant: member',
      () async {
        // from: review_regression_test.dart: member
        late final Scope scope;
        scope = Scope(
          components: [
            Component<int>(
              key: count,
              dependency: Dependency<int>(
                create: () => 1,
                dispose: releaseWith(
                  () => rightOf(scope.node<int>(key: count)).dispose(),
                ),
              ),
            ),
          ],
        );
        rightOf(await scope.run());
        final cause = leftOf(
          await rightOf(
            scope.node<int>(key: count),
          ).dispose().timeout(const Duration(seconds: 2)),
        );
        final failure = cause.defects.single as DisposeFailure;
        expect(
          (failure.error as Cause<DiFailure>).only,
          isA<ReentrantMutationFailure>().having(
            (f) => f.operation,
            'operation',
            'ComponentNode.dispose',
          ),
        );
        rightOf(await scope.dispose());
      },
    );

    test(
      'a repeated dispose completes with the disposal in progress',
      () async {
        // from: review_regression_test.dart: 1. a repeated dispose() completes
        // with the disposal in progress
        final gate = Completer<void>();
        final scope = Scope(
          components: [
            Component<int>.effect(
              dependency: Dependency<int>(
                create: () => 1,
                dispose: (_) async {
                  await gate.future;
                  throw StateError('cleanup failed');
                },
              ),
            ),
          ],
        );
        rightOf(await scope.run());
        final first = scope.dispose();
        await pause(1);
        var secondDone = false;
        final second = scope.dispose().then((exit) {
          secondDone = true;
          return exit;
        });
        await pause(1);
        expect(secondDone, isFalse, reason: 'the cleanup has not finished');
        gate.complete();
        expect(leftOf(await first).defects, hasLength(1));
        expect(
          leftOf(await second).defects,
          hasLength(1),
          reason: 'the second call shares the result of the first',
        );
      },
    );

    test('a second dispose shares the result while the first still runs '
        'after the scope is marked disposed', () async {
      // from: review_regression_test.dart: 7. a second dispose shares the
      // result while the first still runs after the scope is marked disposed
      var releases = 0;
      final scope = Scope(
        components: [
          Component<int>.effect(
            dependency: Dependency<int>(
              create: () => 1,
              dispose: (_) {
                releases++;
                throw StateError('cleanup failed');
              },
            ),
          ),
        ],
      );
      rightOf(await scope.run());
      // A paused subscriber keeps the end of `errors` pending after the scope
      // is marked disposed, so the first dispose has not completed yet.
      final subscription = scope.errors.listen((_) {})..pause();
      var firstDone = false;
      final first = scope.dispose().whenComplete(() => firstDone = true);
      for (var i = 0; i < 5; i++) {
        await pause(1);
      }
      expect(scope.phase, ScopePhase.disposed);
      expect(firstDone, isFalse);
      final second = scope.dispose();
      subscription.resume();
      expect(leftOf(await first).defects, hasLength(1));
      expect(leftOf(await second).defects, hasLength(1));
      expect(releases, 1);
      await subscription.cancel();
    });

    test(
      'a call from a descendant joins the disposal of an ancestor',
      () async {
        final gate = Completer<void>();
        final root = Scope(
          components: [
            Component<int>.effect(
              dependency: Dependency<int>(
                create: () => 1,
                dispose: (_) async {
                  await gate.future;
                  throw StateError('failed');
                },
              ),
            ),
          ],
        );
        final child = root.kid();
        rightOf(await root.run());
        rightOf(await child.run());
        final first = root.dispose();
        final joined = child.dispose();
        expect(identical(first, joined), isTrue);
        expect(child.phase, ScopePhase.disposeRequested);
        gate.complete();
        expect(leftOf(await joined).defects, hasLength(1));
        expect(child.phase, ScopePhase.disposed);
        rightOf(await child.dispose());
      },
    );

    test('the disposals of a child and of its parent queue in the order of '
        'the calls', () async {
      final gate = Completer<void>();
      final root = Scope(components: [member('p', [], gate: gate.future)]);
      final child = root.kid();
      rightOf(await root.run());
      rightOf(await child.run());
      final childDisposal = child.dispose();
      final rootDisposal = root.dispose();
      gate.complete();
      rightOf(await childDisposal);
      rightOf(await rootDisposal);
      expect(root.phase, ScopePhase.disposed);
    });
  });

  group('cancellation', () {
    test('a setup queued behind the disposal never runs', () async {
      // from: cancellation_test.dart: a setup queued behind the disposal
      // never runs (NoSetupAfterCancel)
      final log = <String>[];
      final hold = Completer<void>();
      final app = Scope(
        components: [
          Component<int>.effect(
            dependency: Dependency<int>(
              create: () async {
                await hold.future;
                return 0;
              },
            ),
          ),
        ],
      );
      final busy = app.run(); // occupies the queue
      final session = app.kid(
        components: [
          Component<int>.effect(
            dependency: Dependency<int>(
              create: () {
                log.add('setup');
                return 1;
              },
            ),
          ),
        ],
      );
      final setup = session.run();
      final disposal = session.dispose(); // requested before the setup starts
      hold.complete();
      rightOf(await busy);
      expect(leftOf(await setup).isInterrupted, isTrue);
      rightOf(await disposal);
      expect(log, isEmpty, reason: 'the setup never ran');
      expect(
        leftOf(await session.run()).only,
        isA<DisposedScopeFailure>(),
        reason: 'a new call after the disposal is rejected',
      );
      rightOf(await app.dispose());
    });

    test('no step starts after the token is canceled', () async {
      // from: cancellation_test.dart: no step starts after the token is
      // canceled (NoStepAfterCancel)
      final log = <String>[];
      final gate = Completer<void>();
      final scope = Scope(
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
                ).map<int>((v) {
                  log.add('second');
                  return v + 1;
                }, dispose: (_) => log.add('dispose second')),
          ),
        ],
      );
      final setup = scope.run();
      await pause(1);
      final disposal = scope.dispose();
      gate.complete();
      expect(leftOf(await setup).isInterrupted, isTrue);
      rightOf(await disposal);
      expect(log, ['first', 'dispose first']);
    });

    test(
      'the next setup starts after the canceled rollback finishes',
      () async {
        // from: cancellation_test.dart: the next setup starts after the
        // canceled rollback finishes (CleanupBeforeNextSetup)
        final log = <String>[];
        final gate = Completer<void>();
        final app = Scope(components: []);
        rightOf(await app.run());
        final first = app.kid(
          components: [
            Component<int>.effect(
              dependency: Dependency<int>(
                create: () async {
                  log.add('create');
                  await gate.future;
                  return 1;
                },
                dispose: (_) => log.add('dispose'),
              ),
            ),
          ],
        );
        final firstSetup = first.run();
        await pause(1);
        final logout = first.dispose();
        final second = app.kid(
          components: [
            Component<String>(
              key: text,
              dependency: Dependency<String>(
                create: () {
                  log.add('create second');
                  return 'you';
                },
              ),
            ),
          ],
        );
        final secondSetup = second.run();
        gate.complete();
        rightOf(await secondSetup);
        expect(leftOf(await firstSetup).isInterrupted, isTrue);
        rightOf(await logout);
        expect(log, ['create', 'dispose', 'create second']);
        expect(rightOf(second.get<String>(key: text)), 'you');
        rightOf(await app.dispose());
      },
    );

    test(
      'a canceled automatic activation is not reported as a failure',
      () async {
        // from: cancellation_test.dart: a canceled automatic activation is not
        // reported as a failure
        final gate = Completer<void>();
        final root = Scope(
          components: [Component<int>.value(value: 1, key: count)],
        );
        final consumers = root.kid(
          components: [
            Component<int>(
              key: k('consumer'),
              dependency: Dependency.require<int>(key: count).mapTask<int>(
                (v) => Task(() async {
                  await gate.future;
                  return v;
                }),
              ),
            ),
          ],
        );
        final errors = <Cause<DiFailure>>[];
        final subscription = root.errors.listen(errors.add);
        rightOf(await consumers.run()); // waits for the key of the parent
        final wake = root.run(); // activates the consumer automatically
        await pause(1);
        final disposal = consumers.dispose();
        gate.complete();
        rightOf(await wake);
        rightOf(await disposal);
        await pause(1);
        expect(root.isInitialized, isTrue);
        expect(errors, isEmpty);
        await subscription.cancel();
        rightOf(await root.dispose());
      },
    );

    test('owner cancel: the late release failure reaches the run, and two '
        'dispose callers share one result', () async {
      // from: cancellation_test.dart: owner cancel: the late release failure
      // reaches initialize, and two dispose callers share one result
      // (RecipientsExact, CallersAgree, ReleaseAtMostOnce)
      final gate = Completer<void>();
      var releases = 0;
      final lateError = StateError('late release failed');
      final scope = Scope(
        components: [
          Component<int>.effect(
            dependency: Dependency<int>(
              create: () async {
                await gate.future; // ignores the cancellation
                return 1;
              },
              dispose: (_) {
                releases++;
                throw lateError;
              },
            ),
          ),
        ],
      );
      final setup = scope.run();
      await pause(1);
      expect(releases, 0);
      final first = scope.dispose();
      final second = scope.dispose();
      gate.complete();

      final canceled = leftOf(await setup);
      expect(canceled.isInterrupted, isTrue);
      expect(canceled.defects.map((d) => (d as DisposeFailure).error), [
        lateError,
      ], reason: 'the late release failure goes to the caller of the run');
      rightOf(await first);
      rightOf(await second);
      expect(releases, 1, reason: 'the late value is released once');
      expect(scope.nodes, isEmpty);
    });

    test(
      'the disposal of the owner is reported before a node commits',
      () async {
        // from: cancellation_test.dart: the token is canceled before dispose()
        // returns
        final gate = Completer<void>();
        final scope = Scope(
          components: [
            Component<int>(
              key: count,
              dependency: Dependency<int>(
                create: () async {
                  await gate.future;
                  return 1;
                },
              ),
            ),
          ],
        );
        final setup = scope.run();
        await pause(1);
        final disposal = scope.dispose();
        // The cancellation took effect at the call, not at the mutation.
        expect(scope.phase, ScopePhase.disposeRequested);
        final node = scope.findNode<int>(key: count).toNullable()!;
        gate.complete();
        leftOf(await setup);
        rightOf(await disposal);
        expect(node.state.phase, NodePhase.disposed);
        expect(leftOf(scope.get<int>(key: count)), isA<DisposedScopeFailure>());
      },
    );
  });

  group('teardown', () {
    test('independent members release at the same time', () async {
      // from: concurrent_teardown_test.dart: independent members release at
      // the same time
      final log = <String>[];
      const delay = Duration(milliseconds: 100);
      final di = Scope(
        components: [
          for (var i = 0; i < 5; i++) member('m$i', log, delay: delay),
        ],
      );
      rightOf(await di.run());
      final watch = Stopwatch()..start();
      rightOf(await di.dispose());
      watch.stop();
      // Five sequential releases would take 500 ms or more.
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 350)));
      final firstEnd = log.indexWhere((e) => e.startsWith('end'));
      expect(
        log.take(firstEnd).where((e) => e.startsWith('start')),
        hasLength(5),
      );
    });

    test('a publisher waits for every dependent to finish', () async {
      // from: concurrent_teardown_test.dart: a publisher waits for every
      // dependent to finish
      final log = <String>[];
      final gate = Completer<void>();
      final di = Scope(
        components: [
          member('p1', log),
          member('p2', log),
          member('d', log, reads: ['p1', 'p2'], gate: gate.future),
        ],
      );
      rightOf(await di.run());
      final teardown = di.dispose();
      await pause(20);
      expect(log, ['start d'], reason: 'no publisher starts while d releases');
      gate.complete();
      rightOf(await teardown);
      expect(log.sublist(0, 2), ['start d', 'end d']);
      expect(
        log.sublist(2),
        unorderedEquals(['start p1', 'end p1', 'start p2', 'end p2']),
      );
    });

    test('a chain releases dependents first', () async {
      // from: concurrent_teardown_test.dart: a chain releases dependents
      // first
      final log = <String>[];
      final di = Scope(
        components: [
          member('a', log),
          member('b', log, reads: ['a']),
          member('c', log, reads: ['b']),
        ],
      );
      rightOf(await di.run());
      rightOf(await di.dispose());
      expect(log, ['start c', 'end c', 'start b', 'end b', 'start a', 'end a']);
    });

    test('the read graph orders the release, not the creation order', () async {
      // from: concurrent_teardown_test.dart: the read graph orders the
      // release, not the creation order
      final log = <String>[];
      final di = Scope(
        components: [
          // Created first, but reads the publisher created last.
          member(
            'reader',
            log,
            reads: ['publisher'],
            delay: const Duration(milliseconds: 20),
          ),
          member('publisher', log),
        ],
      );
      rightOf(await di.run());
      rightOf(await di.dispose());
      expect(log, [
        'start reader',
        'end reader',
        'start publisher',
        'end publisher',
      ]);
    });

    test('a child scope releases before the parent values it read', () async {
      // from: concurrent_teardown_test.dart: a child scope releases before
      // the parent values it read
      final log = <String>[];
      final root = Scope(components: [member('api', log)]);
      final child = root.kid(
        components: [
          member(
            'screen',
            log,
            reads: ['api'],
            delay: const Duration(milliseconds: 20),
          ),
        ],
      );
      rightOf(await root.run());
      rightOf(await child.run());
      expect(child.nodes.single.isActive, isTrue);
      rightOf(await root.dispose());
      expect(log.indexOf('end screen'), lessThan(log.indexOf('start api')));
    });

    test('the dispose failures follow descending node id', () async {
      // from: concurrent_teardown_test.dart: the dispose failures follow node
      // order
      Future<List<String>> owners({required bool lateFirst}) async {
        final log = <String>[];
        final di = Scope(
          components: [
            member(
              'first',
              log,
              delay: Duration(milliseconds: lateFirst ? 40 : 0),
              fail: StateError('first'),
            ),
            member(
              'second',
              log,
              delay: Duration(milliseconds: lateFirst ? 0 : 40),
              fail: StateError('second'),
            ),
          ],
        );
        rightOf(await di.run());
        return [
          for (final d in leftOf(await di.dispose()).defects)
            (d as DisposeFailure).owner,
        ];
      }

      final one = await owners(lateFirst: true);
      final other = await owners(lateFirst: false);
      expect(one, ['second', 'first']);
      expect(other, one);
    });

    test('an optional feedback pair releases each node once', () async {
      // from: concurrent_teardown_test.dart: an optional feedback pair
      // releases each node once
      final released = <String>[];
      const outside = DiKey<int>(name: 'outside');
      final root = Scope(
        components: [Component<int>.value(value: 0, key: outside)],
      );
      final child = root.kid(
        components: [
          Component<int>(
            key: k('L'),
            debugLabel: 'x',
            dependency:
                (
                  Dependency.require<int>(key: outside),
                  Dependency.option<int>(key: k('K')),
                ).zip.mapN<int>(
                  (_, v) => v.getOrElse(() => 0) + 1,
                  dispose: (_) => released.add('x'),
                ),
          ),
          Component<int>(
            key: k('K'),
            debugLabel: 'y',
            dependency: Dependency.require<int>(
              key: k('L'),
            ).map<int>((v) => v + 1, dispose: (_) => released.add('y')),
          ),
        ],
      );
      final errors = root.errors.listen((_) {}); // the feedback is reported
      rightOf(await child.run());
      rightOf(await root.run()); // wakes x and y, which read each other
      await pause(1);
      final active = child.nodes.where((node) => node.isActive).length;
      released.clear(); // the rebuilds released earlier values
      rightOf(await root.dispose().timeout(const Duration(seconds: 5)));
      expect(released, hasLength(active));
      expect(released.toSet(), hasLength(active), reason: 'each node once');
      await errors.cancel();
    });

    test('a disposal does not reconcile', () async {
      // The failure of an automatic activation stays in its node when an
      // unrelated scope is disposed (inventory 10.2.1).
      final root = Scope(
        components: [Component<int>.value(value: 1, key: count)],
      );
      var attempts = 0;
      final consumers = root.kid(
        components: [
          Component<String>(
            key: text,
            dependency: Dependency.require<int>(key: count).map<String>((_) {
              if (++attempts == 1) throw StateError('first');
              return 'ok';
            }),
          ),
        ],
      );
      final other = root.kid();
      final subscription = root.errors.listen((_) {});
      rightOf(await consumers.run());
      rightOf(await other.run());
      rightOf(await root.run());
      expect(attempts, 1);
      rightOf(await other.dispose());
      expect(attempts, 1, reason: 'the disposal did not retry the node');
      expect(consumers.nodes.single.state.phase, NodePhase.activationFailed);
      await subscription.cancel();
      rightOf(await root.dispose());
    });
  });

  group('whenActive', () {
    Component<int> number(int value) =>
        Component<int>.value(value: value, debugLabel: 'number', key: count);
    Component<String> label() => Component<String>(
      key: text,
      debugLabel: 'text',
      dependency: Dependency.require<int>(
        key: count,
      ).map<String>((value) => 'v$value'),
    );

    test('completes when a dormant component activates', () async {
      // from: observation_test.dart: completes when a dormant component
      // activates
      final di = Scope(components: [number(1)]);
      final child = di.kid(components: [label()]);
      rightOf(await child.run());
      final node = child.nodes.single;
      String? value;
      final waiting = node.whenActive.run().then(
        (v) => value = rightOf(v) as String?,
      );
      await pause(1);
      expect(value, isNull);

      rightOf(await di.run());
      await waiting;
      expect(value, 'v1');
      rightOf(await di.dispose());
    });

    test('completes for a dormant member of a child scope', () async {
      // from: observation_test.dart: completes for a dormant member of a
      // child scope
      final di = Scope(components: [number(3)]);
      final child = di.kid(components: [label()]);
      rightOf(await child.run());
      final member = child.nodes.single;
      final waiting = member.whenActive.run();
      expect(member.missing, [count]);
      rightOf(await di.run());
      expect(rightOf(await waiting), 'v3');
      rightOf(await di.dispose());
    });

    test('completes at once for an active component', () async {
      // from: observation_test.dart: completes at once for an active
      // component
      final di = Scope(components: [number(7)]);
      rightOf(await di.run());
      expect(rightOf(await di.nodes.single.whenActive.run()), 7);
      rightOf(await di.dispose());
    });

    test('is lazy: nothing registers before the task runs', () async {
      final di = Scope(components: [number(1)]);
      final child = di.kid(components: [label()]);
      rightOf(await child.run());
      final task = child.nodes.single.whenActive;
      rightOf(await di.run());
      // The node is active when the task runs, so the task answers at once.
      expect(rightOf(await task.run()), 'v1');
      rightOf(await di.dispose());
    });

    test('fails with InactiveNodeFailure when disposed first', () async {
      // The parent declares the int key but never runs, so the text waits.
      // from: observation_test.dart: fails with InactiveNodeException when
      // disposed first
      final pending = Scope(components: [number(1)]);
      final di = pending.kid(components: [label()]);
      rightOf(await di.run());
      final node = di.nodes.single;
      final waiting = node.whenActive.run();
      rightOf(await node.dispose());
      expect(leftOf(await waiting), isA<InactiveNodeFailure>());
      expect(leftOf(await node.whenActive.run()), isA<InactiveNodeFailure>());
      rightOf(await pending.dispose());
    });

    test('fails for every waiter when its scope is disposed', () async {
      // from: observation_test.dart: fails for every waiter when its scope is
      // disposed
      final di = Scope(components: [number(1)]);
      final child = di.kid(components: [label()]);
      rightOf(await child.run());
      final node = child.nodes.single;
      final first = node.whenActive.run();
      final second = node.whenActive.run();
      rightOf(await child.dispose());
      expect(leftOf(await first), isA<InactiveNodeFailure>());
      expect(leftOf(await second), isA<InactiveNodeFailure>());
      rightOf(await di.dispose());
    });

    test('stays pending after a failed automatic activation', () async {
      // from: observation_test.dart: stays pending after a failed automatic
      // activation
      final di = Scope(components: [number(1)]);
      final errors = <Cause<DiFailure>>[];
      final subscription = di.errors.listen(errors.add);
      final child = di.kid(
        components: [
          Component<String>.effect(
            debugLabel: 'failing',
            dependency: Dependency.require<int>(
              key: count,
            ).map<String>((_) => throw StateError('boom')),
          ),
        ],
      );
      rightOf(await child.run());
      final failing = child.nodes.single;
      var completed = false;
      unawaited(failing.whenActive.run().then((_) => completed = true));

      rightOf(await di.run());
      await pause(1);
      expect(errors, hasLength(1));
      expect(errors.single.only, isA<ActivationFailure>());
      expect(completed, isFalse);
      expect(failing.missing, isEmpty);
      await subscription.cancel();
      rightOf(await di.dispose());
    });

    test('a waiter of each zone completes in its own zone', () async {
      final di = Scope(components: [number(1)]);
      final child = di.kid(components: [label()]);
      rightOf(await child.run());
      final node = child.nodes.single;
      final zones = <Zone>[];
      final other = Zone.current.fork();
      final one = node.whenActive.run().then((_) => zones.add(Zone.current));
      final two = other.run(
        () => node.whenActive.run().then((_) => zones.add(Zone.current)),
      );
      rightOf(await di.run());
      await Future.wait([one, two]);
      expect(zones, hasLength(2));
      expect(zones, contains(other));
      expect(zones.toSet(), hasLength(2));
      rightOf(await di.dispose());
    });
  });

  group('getWhenAvailable', () {
    test('completes at once with a value that get returns', () async {
      // from: get_when_available_test.dart: completes at once with a value
      // that get returns
      final scope = Scope(
        components: [Component<String>.value(key: text, value: 'x')],
      );
      rightOf(await scope.run());
      expect(
        rightOf(await scope.getWhenAvailable<String>(key: text).run()),
        'x',
      );
      rightOf(await scope.dispose());
    });

    test('waits for the run of its own scope', () async {
      // from: get_when_available_test.dart: waits for the initialize of its
      // own scope
      final scope = Scope(
        components: [Component<String>.value(key: text, value: 'x')],
      );
      final result = scope.getWhenAvailable<String>(key: text).run();
      await pause(1);
      rightOf(await scope.run());
      expect(rightOf(await result), 'x');
      rightOf(await scope.dispose());
    });

    test('waits in a child for a parent that is not run yet', () async {
      // from: get_when_available_test.dart: waits in a child for a parent that
      // is not initialized yet
      const b = DiKey<String>(name: 'b');
      final parent = Scope(
        components: [Component<String>.value(key: text, value: 'x')],
      );
      final child = parent.kid(
        components: [
          Component<String>(
            key: b,
            dependency: Dependency.require<String>(
              key: text,
            ).map<String>((v) => '$v!'),
          ),
        ],
      );
      rightOf(await child.run());
      final fromParent = child.getWhenAvailable<String>(key: text).run();
      final fromChild = child.getWhenAvailable<String>(key: b).run();
      await pause(1);
      expect(child.getOption<String>(key: b), isA<None>());
      rightOf(await parent.run());
      expect(rightOf(await fromParent), 'x');
      expect(rightOf(await fromChild), 'x!');
      rightOf(await parent.dispose());
    });

    test(
      'fails at once for a key that no scope of the chain declares',
      () async {
        // from: get_when_available_test.dart: fails at once for a key that no
        // scope of the chain declares
        final scope = Scope(
          components: [Component<String>.value(key: text, value: 'x')],
        );
        rightOf(await scope.run());
        const gone = DiKey<String>(name: 'gone');
        expect(
          leftOf(await scope.getWhenAvailable<String>(key: gone).run()),
          isA<UnavailableKeyFailure>().having((f) => f.key, 'key', gone),
        );
        rightOf(await scope.dispose());
      },
    );

    test(
      'keeps waiting through a failed run, and completes on a retry',
      () async {
        // from: get_when_available_test.dart: keeps waiting through a failed
        // initialize, and completes on a retry
        var attempt = 0;
        const b = DiKey<String>(name: 'b');
        final scope = Scope(
          components: [
            Component<String>.value(key: text, value: 'x'),
            Component<String>(
              key: b,
              dependency: Dependency.require<String>(key: text).map<String>((
                v,
              ) {
                if (attempt++ == 0) throw StateError('first');
                return '$v!';
              }),
            ),
          ],
        );
        final result = scope.getWhenAvailable<String>(key: b).run();
        expect(leftOf(await scope.run()).only, isA<ActivationFailure>());
        await pause(1);
        var done = false;
        unawaited(result.then((_) => done = true));
        await pause(1);
        expect(done, isFalse);
        rightOf(await scope.run());
        expect(rightOf(await result), 'x!');
        rightOf(await scope.dispose());
      },
    );

    test('fails when the disposal of the scope is requested first', () async {
      // from: get_when_available_test.dart: fails when the disposal of the
      // scope is requested first
      final parent = Scope(
        components: [Component<String>.value(key: text, value: 'x')],
      );
      final child = parent.kid();
      final result = child.getWhenAvailable<String>(key: text).run();
      await pause(1);
      rightOf(await child.dispose());
      expect(leftOf(await result), isA<DisposedScopeFailure>());
      final late = await child.getWhenAvailable<String>(key: text).run();
      expect(leftOf(late), isA<DisposedScopeFailure>());
      rightOf(await parent.dispose());
    });

    test('each run of the task reads the scope again', () async {
      final scope = Scope(
        components: [Component<String>.value(key: text, value: 'x')],
      );
      final task = scope.getWhenAvailable<String>(key: text);
      rightOf(await scope.run());
      expect(rightOf(await task.run()), 'x');
      expect(rightOf(await task.run()), 'x');
      rightOf(await scope.dispose());
    });
  });
}
