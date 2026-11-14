// A later call does not depend on the zone of an earlier, finished call
// (R-UC-RT-LC-027). The harness emulates the fake-async zone of a Flutter
// `testWidgets` body: the binding drains the microtasks of the zone while the
// body runs, and never again after the body completes.
import 'dart:async';
import 'dart:collection';

import 'package:fp_di/fp_di.dart';
import 'package:test/test.dart';

final class Repo {
  Repo(this.id);
  final int id;
}

final class Session {
  Session(this.id);
  final int id;
}

const _limit = Duration(seconds: 2);

/// A zone whose microtasks go to a manual queue. [run] drains the queue while
/// the body runs and stops at the moment the body completes, so the microtasks
/// that are still queued then never run: the zone is dead.
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

Component<Repo> repoComponent({
  int Function()? count,
  void Function()? onDispose,
}) {
  var made = 0;
  return Component<Repo>(
    dependency: Dependency<Repo>(
      create: () => Repo(count == null ? ++made : count()),
      dispose: (_) => onDispose?.call(),
    ),
  );
}

void main() {
  late ManualZone fake;

  setUp(() {
    fake = ManualZone();
  });

  test('the harness leaves microtasks of a dead zone unrun', () async {
    await fake.run(() async {
      scheduleMicrotask(() {});
      scheduleMicrotask(() {});
    });
    // The body completes while a microtask is still queued: it never runs.
    var ran = false;
    fake.zone.scheduleMicrotask(() => ran = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(ran, isFalse);
    expect(fake.queued, greaterThan(0));
  });

  group('operation A in the dead zone, operation B outside', () {
    test('initialize inside, dispose outside', () async {
      final scope = Scope(module: Module(components: [repoComponent()]));
      await fake.run(() => scope.initialize());
      await scope.dispose().timeout(_limit);
      expect(() => scope.get<Repo>(), throwsA(isA<DisposedScopeError>()));
    });

    test('create and initialize inside, dispose outside', () async {
      late Scope scope;
      await fake.run(() async {
        scope = Scope(module: Module(components: [repoComponent()]));
        await scope.initialize();
      });
      await scope.dispose().timeout(_limit);
    });

    test('initialize and dispose inside, a second dispose outside', () async {
      final scope = Scope(module: Module(components: [repoComponent()]));
      await fake.run(() async {
        await scope.initialize();
        await scope.dispose();
      });
      await scope.dispose().timeout(_limit);
    });

    test('initialize inside, a child scope initialized outside', () async {
      var released = 0;
      final root = Scope(module: Module(components: [repoComponent()]));
      await fake.run(() => root.initialize());
      final child = root.child(
        module: Module(
          components: [
            Component<Session>(
              dependency: Dependency.require<Repo>().map(
                (repo) => Session(repo.id),
                dispose: (_) => released++,
              ),
            ),
          ],
        ),
      );
      await child.initialize().timeout(_limit);
      expect(child.get<Session>().id, 1);
      await child.dispose().timeout(_limit);
      expect(released, 1);
      await root.dispose().timeout(_limit);
    });

    test('initialize inside, a node read and disposed outside', () async {
      final scope = Scope(module: Module(components: [repoComponent()]));
      await fake.run(() => scope.initialize());
      final node = scope.node<Repo>(key: DiKey<Repo>());
      expect((await node.whenActive.timeout(_limit)).id, 1);
      await node.dispose().timeout(_limit);
      expect(node.isActive, isFalse);
      await node.dispose().timeout(_limit);
      await scope.dispose().timeout(_limit);
    });

    test('a node disposed inside, disposed again outside', () async {
      final scope = Scope(module: Module(components: [repoComponent()]));
      await fake.run(() async {
        await scope.initialize();
        await scope.node<Repo>(key: DiKey<Repo>()).dispose();
      });
      await scope.node<Repo>(key: DiKey<Repo>()).dispose().timeout(_limit);
      await scope.dispose().timeout(_limit);
    });

    test('a lazy value created inside, read and released outside', () async {
      var made = 0;
      var released = 0;
      final key = DiKey<Lazy<Repo>>();
      final scope = Scope(
        module: Module(
          components: [
            Component<Lazy<Repo>>(
              key: key,
              dependency: Dependency<Repo>(
                create: () => Repo(++made),
                dispose: (_) => released++,
              ).lazy(),
            ),
          ],
        ),
      );
      late Repo inside;
      await fake.run(() async {
        await scope.initialize();
        inside = await scope.get<Lazy<Repo>>(key: key).force();
      });
      final holder = scope.get<Lazy<Repo>>(key: key);
      final outside = await holder.force().timeout(_limit);
      expect(identical(outside, inside), isTrue);
      expect(made, 1);
      await scope.dispose().timeout(_limit);
      expect(released, 1);
      await expectLater(holder.force(), throwsA(isA<DisposedLazyException>()));
    });

    test('a lazy value forced outside, created in an earlier zone', () async {
      var made = 0;
      final key = DiKey<Lazy<Repo>>();
      final scope = Scope(
        module: Module(
          components: [
            Component<Lazy<Repo>>(
              key: key,
              dependency: Dependency<Repo>(create: () => Repo(++made)).lazy(),
            ),
          ],
        ),
      );
      await fake.run(() => scope.initialize());
      final holder = scope.get<Lazy<Repo>>(key: key);
      expect((await holder.force().timeout(_limit)).id, 1);
      await scope.dispose().timeout(_limit);
    });

    test('a lazy creation outside ends by the cancellation of a dead-zone '
        'activation', () async {
      final key = DiKey<Lazy<int>>();
      final scope = Scope(
        module: Module(
          components: [
            Component<Lazy<int>>(
              key: key,
              dependency: Dependency.cancellation()
                  .map((token) => token.whenCanceled.then((_) => 1))
                  .lazy(),
            ),
          ],
        ),
      );
      await fake.run(() => scope.initialize());
      final holder = scope.get<Lazy<int>>(key: key);
      final forced = holder.force()..ignore();
      await scope.dispose().timeout(_limit);
      await expectLater(forced, throwsA(isA<DisposedLazyException>()));
    });

    test('an errors subscriber of the dead zone, dispose outside', () async {
      final scope = Scope(module: Module(components: [repoComponent()]));
      var done = false;
      await fake.run(() async {
        scope.errors.listen((_) {}, onDone: () => done = true);
        await scope.initialize();
      });
      await scope.dispose().timeout(_limit);
      expect(done, isTrue, reason: 'the stream of errors closes');
    });

    test('a controller of the dead zone, canceled outside', () async {
      late CancellationController controller;
      await fake.run(() async {
        controller = CancellationController();
      });
      final waiting = controller.token.whenCanceled;
      expect(controller.isCanceled, isFalse);
      controller.cancel();
      expect(controller.isCanceled, isTrue);
      await waiting.timeout(_limit);
      await controller.token.whenCanceled.timeout(_limit);
    });

    test('a waiter for activation, requested inside and outside', () async {
      final key = DiKey<Repo>();
      final root = Scope(
        module: Module(
          components: [
            Component<Repo>(
              key: key,
              dependency: Dependency(create: () => Repo(7)),
            ),
          ],
        ),
      );
      final child = root.child(
        module: Module(
          components: [
            Component<Session>(
              dependency: Dependency.require<Repo>(
                key: key,
              ).map((repo) => Session(repo.id)),
            ),
          ],
        ),
      );
      late ComponentNode<Session> node;
      await fake.run(() async {
        await child.initialize();
        node = child.node<Session>(key: DiKey<Session>());
        expect(node.isActive, isFalse, reason: 'waits for the root');
        // A waiter that the body never awaits.
        unawaited(node.whenActive.then<void>((_) {}, onError: (Object _) {}));
      });
      final waiting = node.whenActive;
      await root.initialize().timeout(_limit);
      expect((await waiting.timeout(_limit)).id, 7);
      await root.dispose().timeout(_limit);
    });

    test('a mutation that fails inside, initialize again outside', () async {
      var attempts = 0;
      final scope = Scope(
        module: Module(
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
        ),
      );
      Object? caught;
      await fake.run(() async {
        try {
          await scope.initialize();
        } on Object catch (error) {
          caught = error;
        }
      });
      expect(caught, isA<ActivationException>());
      await scope.initialize().timeout(_limit);
      expect(scope.get<Repo>().id, 2);
      await scope.dispose().timeout(_limit);
    });

    test('a mutation that fails inside, dispose outside', () async {
      final scope = Scope(
        module: Module(
          components: [
            Component<Repo>(
              dependency: Dependency<Repo>(
                create: () => throw StateError('never'),
              ),
            ),
          ],
        ),
      );
      await fake.run(() async {
        try {
          await scope.initialize();
        } on Object {
          // Handled inside.
        }
      });
      await scope.dispose().timeout(_limit);
    });

    test('a rejected reentrant call inside, initialize outside', () async {
      late Scope scope;
      scope = Scope(
        module: Module(
          components: [
            Component<Repo>(
              dependency: Dependency<Repo>(
                create: () async {
                  await scope.dispose();
                  return Repo(1);
                },
              ),
            ),
          ],
        ),
      );
      await fake.run(() async {
        try {
          await scope.initialize();
        } on Object {
          // The reentrant dispose fails the activation.
        }
      });
      await scope.dispose().timeout(_limit);
    });

    test('mutations queue in order after the zone is dead', () async {
      final events = <String>[];
      final root = Scope(module: Module(components: [repoComponent()]));
      await fake.run(() => root.initialize());
      Scope child(String name) => root.child(
        module: Module(
          components: [
            Component<Session>(
              dependency: Dependency.require<Repo>().map((repo) async {
                events.add('$name start');
                await Future<void>.delayed(Duration.zero);
                events.add('$name end');
                return Session(repo.id);
              }),
            ),
          ],
        ),
      );
      final a = child('a');
      final b = child('b');
      await Future.wait([a.initialize(), b.initialize()]).timeout(_limit);
      expect(events, ['a start', 'a end', 'b start', 'b end']);
      await root.dispose().timeout(_limit);
    });

    test(
      'the action does not start inside the call, with a dead zone',
      () async {
        var started = false;
        final scope = Scope(
          module: Module(
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
          ),
        );
        await fake.run(() async {
          await Scope().initialize();
        });
        final future = scope.initialize();
        expect(
          started,
          isFalse,
          reason: 'one asynchronous hop before the start',
        );
        await future.timeout(_limit);
        expect(started, isTrue);
        await scope.dispose();
      },
    );
  });

  group('operation A outside, operation B in the zone with its drain', () {
    test('initialize outside, dispose in the zone', () async {
      final scope = Scope(module: Module(components: [repoComponent()]));
      await scope.initialize();
      await fake.runStrict(() => scope.dispose());
    });

    test('initialize and dispose outside, dispose again in the zone', () async {
      final scope = Scope(module: Module(components: [repoComponent()]));
      await scope.initialize();
      await scope.dispose();
      await fake.runStrict(() => scope.dispose());
    });

    test(
      'a child scope created, initialized, and disposed in the zone',
      () async {
        final root = Scope(module: Module(components: [repoComponent()]));
        await root.initialize();
        await fake.runStrict(() async {
          final child = root.child(
            module: Module(
              components: [
                Component<Session>(
                  dependency: Dependency.require<Repo>().map(
                    (repo) => Session(repo.id),
                  ),
                ),
              ],
            ),
          );
          await child.initialize();
          expect(child.get<Session>().id, 1);
          await child.dispose();
        });
        await root.dispose();
      },
    );

    test('a lazy value forced and released in the zone', () async {
      final key = DiKey<Lazy<Repo>>();
      var made = 0;
      final scope = Scope(
        module: Module(
          components: [
            Component<Lazy<Repo>>(
              key: key,
              dependency: Dependency<Repo>(create: () => Repo(++made)).lazy(),
            ),
          ],
        ),
      );
      await scope.initialize();
      await fake.runStrict(() async {
        final holder = scope.get<Lazy<Repo>>(key: key);
        expect((await holder.force()).id, 1);
        expect((await holder.force()).id, 1);
        await scope.dispose();
      });
    });

    test('a controller of the real zone, canceled in the zone', () async {
      final controller = CancellationController();
      await fake.runStrict(() async {
        final waiting = controller.token.whenCanceled;
        controller.cancel();
        await waiting;
        await controller.token.whenCanceled;
      });
    });

    test('a node waited for and disposed in the zone', () async {
      final scope = Scope(module: Module(components: [repoComponent()]));
      await scope.initialize();
      await fake.runStrict(() async {
        final node = scope.node<Repo>(key: DiKey<Repo>());
        expect((await node.whenActive).id, 1);
        await node.dispose();
        await scope.dispose();
      });
    });
  });
}
