// A later call does not depend on the zone of an earlier, finished call
// (R-UC-RT-LC-027). The harness emulates the fake-async zone of a Flutter
// `testWidgets` body: the binding drains the microtasks of the zone while the
// body runs, and never again after the body completes.
import 'dart:async';
import 'dart:collection';

import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

final class Repo {
  Repo(this.id);

  final int id;
}

final class Session {
  Session(this.id);

  final int id;
}

const limit = Duration(seconds: 2);

/// A zone whose microtasks go to a manual queue. [run] drains the queue while
/// the body runs and stops at the moment the body completes, so the
/// microtasks that are still queued then never run: the zone is dead.
final class ManualZone {
  ManualZone() {
    zone = Zone.current.fork(
      specification: ZoneSpecification(
        scheduleMicrotask: (self, parent, zone, callback) {
          _queue.add(callback);
        },
      ),
    );
  }

  late final Zone zone;
  final Queue<void Function()> _queue = Queue<void Function()>();

  /// The number of microtasks that are queued and have not run.
  int get queued => _queue.length;

  /// Runs [body] in the zone. Waits on the real event loop when the zone has
  /// nothing queued, so the body can wait for an event of another zone.
  Future<T> run<T>(Future<T> Function() body) =>
      _run(body, realEventLoop: true);

  /// Runs [body] in the zone with the drain of the zone as the only help. The
  /// body fails when the queue is empty and the body has not completed.
  Future<T> runStrict<T>(Future<T> Function() body) =>
      _run(body, realEventLoop: false);

  Future<T> _run<T>(
    Future<T> Function() body, {
    required bool realEventLoop,
  }) async {
    final future = zone.run(body);
    var done = false;
    late T value;
    Object? error;
    StackTrace? stackTrace;
    unawaited(
      future.then<void>(
        (v) {
          value = v;
          done = true;
        },
        onError: (Object e, StackTrace s) {
          error = e;
          stackTrace = s;
          done = true;
        },
      ),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!done) {
      while (_queue.isNotEmpty && !done) {
        _queue.removeFirst()();
      }
      if (done) break;
      if (!realEventLoop) {
        throw StateError(
          'The body did not complete with the drain of the zone alone.',
        );
      }
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('The body did not complete in 5 seconds.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    // The zone is dead now. The queue keeps what is left, and nothing runs it.
    if (error != null) Error.throwWithStackTrace(error!, stackTrace!);
    return value;
  }
}

Component<Repo> repoComponent() {
  var made = 0;
  return Component<Repo>(
    dependency: Dependency<Repo>(create: () => Repo(++made)),
  );
}

void main() {
  late ManualZone fake;

  setUp(() {
    fake = ManualZone();
  });

  test('the harness leaves microtasks of a dead zone unrun', () async {
    // from: dead_zone_test.dart: the harness leaves microtasks of a dead zone
    // unrun
    await fake.run(() async {
      scheduleMicrotask(() {});
      scheduleMicrotask(() {});
    });
    // The body completes while a microtask is still queued: it never runs.
    var ran = false;
    fake.zone.scheduleMicrotask(() => ran = true);
    await pause(20);
    expect(ran, isFalse);
    expect(fake.queued, greaterThan(0));
  });

  group('operation A in the dead zone, operation B outside', () {
    test('run inside, dispose outside', () async {
      // from: dead_zone_test.dart: initialize inside, dispose outside
      final scope = Scope(components: [repoComponent()]);
      rightOf(await fake.run(scope.run));
      rightOf(await scope.dispose().timeout(limit));
      expect(leftOf(scope.get<Repo>()), isA<DisposedScopeFailure>());
    });

    test('create and run inside, dispose outside', () async {
      // from: dead_zone_test.dart: create and initialize inside, dispose
      // outside
      late Scope scope;
      await fake.run(() async {
        scope = Scope(components: [repoComponent()]);
        rightOf(await scope.run());
      });
      rightOf(await scope.dispose().timeout(limit));
    });

    test('run and dispose inside, a second dispose outside', () async {
      // from: dead_zone_test.dart: initialize and dispose inside, a second
      // dispose outside
      final scope = Scope(components: [repoComponent()]);
      await fake.run(() async {
        rightOf(await scope.run());
        rightOf(await scope.dispose());
      });
      rightOf(await scope.dispose().timeout(limit));
    });

    test('run inside, a child scope run outside', () async {
      // from: dead_zone_test.dart: initialize inside, a child scope
      // initialized outside
      var released = 0;
      final root = Scope(components: [repoComponent()]);
      rightOf(await fake.run(root.run));
      final child = root.kid(
        components: [
          Component<Session>(
            dependency: Dependency.require<Repo>().map<Session>(
              (repo) => Session(repo.id),
              dispose: (_) => released++,
            ),
          ),
        ],
      );
      rightOf(await child.run().timeout(limit));
      expect(rightOf(child.get<Session>()).id, 1);
      rightOf(await child.dispose().timeout(limit));
      expect(released, 1);
      rightOf(await root.dispose().timeout(limit));
    });

    test('run inside, a node read and disposed outside', () async {
      // from: dead_zone_test.dart: initialize inside, a node read and
      // disposed outside
      final scope = Scope(components: [repoComponent()]);
      rightOf(await fake.run(scope.run));
      final node = rightOf(scope.node<Repo>());
      expect(rightOf(await node.whenActive.run().timeout(limit)).id, 1);
      rightOf(await node.dispose().timeout(limit));
      expect(node.isActive, isFalse);
      rightOf(await node.dispose().timeout(limit));
      rightOf(await scope.dispose().timeout(limit));
    });

    test('a node disposed inside, disposed again outside', () async {
      // from: dead_zone_test.dart: a node disposed inside, disposed again
      // outside
      final scope = Scope(components: [repoComponent()]);
      await fake.run(() async {
        rightOf(await scope.run());
        rightOf(await rightOf(scope.node<Repo>()).dispose());
      });
      rightOf(await rightOf(scope.node<Repo>()).dispose().timeout(limit));
      rightOf(await scope.dispose().timeout(limit));
    });

    test('an errors subscriber of the dead zone, dispose outside', () async {
      // from: dead_zone_test.dart: an errors subscriber of the dead zone,
      // dispose outside
      final scope = Scope(components: [repoComponent()]);
      var done = false;
      await fake.run(() async {
        scope.errors.listen((_) {}, onDone: () => done = true);
        rightOf(await scope.run());
      });
      rightOf(await scope.dispose().timeout(limit));
      expect(done, isTrue, reason: 'the stream of errors closes');
    });

    test('a lazy value created inside, read and released outside', () async {
      // from: dead_zone_test.dart: a lazy value created inside, read and
      // released outside
      var made = 0;
      var released = 0;
      const key = DiKey<Lazy<Repo>>();
      final scope = Scope(
        components: [
          Component<Lazy<Repo>>(
            key: key,
            dependency: Dependency<Repo>(
              create: () => Repo(++made),
              dispose: (_) => released++,
            ).lazy(),
          ),
        ],
      );
      late Repo inside;
      await fake.run(() async {
        rightOf(await scope.run());
        inside = rightOf(
          await rightOf(scope.get<Lazy<Repo>>(key: key)).force().run(),
        );
      });
      final holder = rightOf(scope.get<Lazy<Repo>>(key: key));
      final outside = rightOf(await holder.force().run().timeout(limit));
      expect(identical(outside, inside), isTrue);
      expect(made, 1);
      rightOf(await scope.dispose().timeout(limit));
      expect(released, 1);
      expect(
        leftOf(await holder.force().run()).only,
        isA<DisposedLazyFailure>(),
      );
    });

    test('a lazy value forced outside, created in an earlier zone', () async {
      // from: dead_zone_test.dart: a lazy value forced outside, created in an
      // earlier zone
      var made = 0;
      const key = DiKey<Lazy<Repo>>();
      final scope = Scope(
        components: [
          Component<Lazy<Repo>>(
            key: key,
            dependency: Dependency<Repo>(create: () => Repo(++made)).lazy(),
          ),
        ],
      );
      rightOf(await fake.run(scope.run));
      final holder = rightOf(scope.get<Lazy<Repo>>(key: key));
      expect(rightOf(await holder.force().run().timeout(limit)).id, 1);
      rightOf(await scope.dispose().timeout(limit));
    });

    test('a lazy creation outside ends by the cancellation of a dead-zone '
        'activation', () async {
      // from: dead_zone_test.dart: a lazy creation outside ends by the
      // cancellation of a dead-zone activation
      const key = DiKey<Lazy<int>>();
      final scope = Scope(
        components: [
          Component<Lazy<int>>(
            key: key,
            dependency: Dependency.cancellation()
                .mapTask<int>((token) => token.whenCanceled.map((_) => 1))
                .lazy(),
          ),
        ],
      );
      rightOf(await fake.run(scope.run));
      final holder = rightOf(scope.get<Lazy<int>>(key: key));
      final forced = holder.force().run()..ignore();
      rightOf(await scope.dispose().timeout(limit));
      expect(leftOf(await forced).only, isA<DisposedLazyFailure>());
    });

    test('a controller of the dead zone, canceled outside', () async {
      // from: dead_zone_test.dart: a controller of the dead zone, canceled
      // outside
      late CancellationController controller;
      await fake.run(() async {
        controller = CancellationController();
      });
      final waiting = controller.token.whenCanceled.run();
      expect(controller.isCanceled, isFalse);
      controller.cancel();
      expect(controller.isCanceled, isTrue);
      await waiting.timeout(limit);
      await controller.token.whenCanceled.run().timeout(limit);
    });

    test('a waiter for activation, requested inside and outside', () async {
      // from: dead_zone_test.dart: a waiter for activation, requested inside
      // and outside
      const key = DiKey<Repo>();
      final root = Scope(
        components: [
          Component<Repo>(
            key: key,
            dependency: Dependency<Repo>(create: () => Repo(7)),
          ),
        ],
      );
      final child = root.kid(
        components: [
          Component<Session>(
            dependency: Dependency.require<Repo>(
              key: key,
            ).map<Session>((repo) => Session(repo.id)),
          ),
        ],
      );
      late ComponentNode<Session> node;
      await fake.run(() async {
        rightOf(await child.run());
        node = rightOf(child.node<Session>());
        expect(node.isActive, isFalse, reason: 'waits for the root');
        // A waiter that the body never awaits.
        unawaited(node.whenActive.run());
      });
      final waiting = node.whenActive.run();
      rightOf(await root.run().timeout(limit));
      expect(rightOf(await waiting.timeout(limit)).id, 7);
      rightOf(await root.dispose().timeout(limit));
    });

    test('a mutation that fails inside, run again outside', () async {
      // from: dead_zone_test.dart: a mutation that fails inside, initialize
      // again outside
      var attempts = 0;
      final scope = Scope(
        components: [
          Component<Repo>(
            dependency: Dependency<Repo>(
              create: () {
                if (++attempts == 1) throw StateError('first attempt');
                return Repo(attempts);
              },
            ),
          ),
        ],
      );
      Cause<DiFailure>? caught;
      await fake.run(() async {
        caught = leftOf(await scope.run());
      });
      expect(caught!.only, isA<ActivationFailure>());
      rightOf(await scope.run().timeout(limit));
      expect(rightOf(scope.get<Repo>()).id, 2);
      rightOf(await scope.dispose().timeout(limit));
    });

    test('a mutation that fails inside, dispose outside', () async {
      // from: dead_zone_test.dart: a mutation that fails inside, dispose
      // outside
      final scope = Scope(
        components: [
          Component<Repo>(
            dependency: Dependency<Repo>(
              create: () => throw StateError('never'),
            ),
          ),
        ],
      );
      await fake.run(() async {
        leftOf(await scope.run());
      });
      rightOf(await scope.dispose().timeout(limit));
    });

    test('a rejected reentrant call inside, run outside', () async {
      // from: dead_zone_test.dart: a rejected reentrant call inside,
      // initialize outside
      late Scope scope;
      scope = Scope(
        components: [
          Component<Repo>(
            dependency: Dependency<Repo>(
              create: () async {
                final rejected = await scope.dispose();
                return rejected.match((cause) => throw cause, (_) => Repo(1));
              },
            ),
          ),
        ],
      );
      await fake.run(() async {
        // The reentrant dispose fails the activation.
        leftOf(await scope.run());
      });
      rightOf(await scope.dispose().timeout(limit));
    });

    test('mutations queue in order after the zone is dead', () async {
      // from: dead_zone_test.dart: mutations queue in order after the zone is
      // dead
      final events = <String>[];
      final root = Scope(components: [repoComponent()]);
      rightOf(await fake.run(root.run));
      Scope child(String name) => root.kid(
        components: [
          Component<Session>(
            dependency: Dependency.require<Repo>().mapTask<Session>(
              (repo) => Task(() async {
                events.add('$name start');
                await pause(1);
                events.add('$name end');
                return Session(repo.id);
              }),
            ),
          ),
        ],
      );
      final a = child('a');
      final b = child('b');
      final results = await Future.wait([a.run(), b.run()]).timeout(limit);
      for (final result in results) {
        rightOf(result);
      }
      expect(events, ['a start', 'a end', 'b start', 'b end']);
      rightOf(await root.dispose().timeout(limit));
    });

    test(
      'the action does not start inside the call, with a dead zone',
      () async {
        // from: dead_zone_test.dart: the action does not start inside the call,
        // with a dead zone
        var started = false;
        final scope = Scope(
          components: [
            Component<Repo>(
              dependency: Dependency<Repo>(
                create: () {
                  started = true;
                  return Repo(1);
                },
              ),
            ),
          ],
        );
        await fake.run(() async {
          rightOf(await Scope(components: []).run());
        });
        final future = scope.run();
        expect(
          started,
          isFalse,
          reason: 'one asynchronous hop before the start',
        );
        rightOf(await future.timeout(limit));
        expect(started, isTrue);
        rightOf(await scope.dispose());
      },
    );
  });

  group('operation A outside, operation B in the zone with its drain', () {
    test('run outside, dispose in the zone', () async {
      // from: dead_zone_test.dart: initialize outside, dispose in the zone
      final scope = Scope(components: [repoComponent()]);
      rightOf(await scope.run());
      rightOf(await fake.runStrict(scope.dispose));
    });

    test('run and dispose outside, dispose again in the zone', () async {
      // from: dead_zone_test.dart: initialize and dispose outside, dispose
      // again in the zone
      final scope = Scope(components: [repoComponent()]);
      rightOf(await scope.run());
      rightOf(await scope.dispose());
      rightOf(await fake.runStrict(scope.dispose));
    });

    test('a child scope created, run, and disposed in the zone', () async {
      // from: dead_zone_test.dart: a child scope created, initialized, and
      // disposed in the zone
      final root = Scope(components: [repoComponent()]);
      rightOf(await root.run());
      await fake.runStrict(() async {
        final child = root.kid(
          components: [
            Component<Session>(
              dependency: Dependency.require<Repo>().map<Session>(
                (repo) => Session(repo.id),
              ),
            ),
          ],
        );
        rightOf(await child.run());
        expect(rightOf(child.get<Session>()).id, 1);
        rightOf(await child.dispose());
      });
      rightOf(await root.dispose());
    });

    test('a lazy value forced and released in the zone', () async {
      // from: dead_zone_test.dart: a lazy value forced and released in the
      // zone
      const key = DiKey<Lazy<Repo>>();
      var made = 0;
      final scope = Scope(
        components: [
          Component<Lazy<Repo>>(
            key: key,
            dependency: Dependency<Repo>(create: () => Repo(++made)).lazy(),
          ),
        ],
      );
      rightOf(await scope.run());
      await fake.runStrict(() async {
        final holder = rightOf(scope.get<Lazy<Repo>>(key: key));
        expect(rightOf(await holder.force().run()).id, 1);
        expect(rightOf(await holder.force().run()).id, 1);
        rightOf(await scope.dispose());
      });
    });

    test('a controller of the real zone, canceled in the zone', () async {
      // from: dead_zone_test.dart: a controller of the real zone, canceled in
      // the zone
      final controller = CancellationController();
      await fake.runStrict(() async {
        final waiting = controller.token.whenCanceled.run();
        controller.cancel();
        await waiting;
        await controller.token.whenCanceled.run();
      });
    });

    test('a node waited for and disposed in the zone', () async {
      // from: dead_zone_test.dart: a node waited for and disposed in the zone
      final scope = Scope(components: [repoComponent()]);
      rightOf(await scope.run());
      await fake.runStrict(() async {
        final node = rightOf(scope.node<Repo>());
        expect(rightOf(await node.whenActive.run()).id, 1);
        rightOf(await node.dispose());
        rightOf(await scope.dispose());
      });
    });
  });
}
