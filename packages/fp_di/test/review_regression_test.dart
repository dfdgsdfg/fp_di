// Regressions for the lifecycle review findings of 2026-11-09.
import 'dart:async';

import 'package:fp_di/fp_di.dart';
import 'package:test/test.dart';

void main() {
  test(
    '1. a repeated dispose() completes with the disposal in progress',
    () async {
      final gate = Completer<void>();
      final scope = await Scope(
        module: Module(
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
        ),
      ).initialize();
      final first = scope.dispose();
      await Future<void>.delayed(Duration.zero);
      var secondDone = false;
      final second = expectLater(
        scope.dispose().then((_) => secondDone = true),
        throwsA(isA<DisposeException>()),
        reason: 'the second call shares the result of the first',
      );
      await Future<void>.delayed(Duration.zero);
      expect(secondDone, isFalse, reason: 'the cleanup has not finished');
      gate.complete();
      await expectLater(first, throwsA(isA<DisposeException>()));
      await second;
    },
  );

  test(
    '2a. a failed Lazy creation keeps its cause and its rollback failure',
    () async {
      final key = DiKey<Lazy<int>>();
      final scope = await Scope(
        module: Module(
          components: [
            Component<Lazy<int>>(
              key: key,
              dependency: Dependency<int>(
                create: () => 1,
                dispose: (_) => throw StateError('release failed'),
              ).map<int>((_) => throw StateError('create failed')).lazy(),
            ),
          ],
        ),
      ).initialize();
      final error = await scope
          .get(key: key)
          .force()
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(
        error,
        isA<ActivationException>()
            .having((e) => '${e.cause}', 'cause', contains('create failed'))
            .having(
              (e) => e.rollbackFailures,
              'rollbackFailures',
              hasLength(1),
            ),
      );
      await scope.dispose();
    },
  );

  test(
    '2b. a Lazy rollback that fails during owner shutdown reaches dispose()',
    () async {
      final key = DiKey<Lazy<int>>();
      final gate = Completer<void>();
      final scope = await Scope(
        module: Module(
          components: [
            Component<Lazy<int>>(
              key: key,
              dependency:
                  Dependency<int>(
                    create: () => 1,
                    dispose: (_) => throw StateError('release failed'),
                  ).map<int>((_) async {
                    await gate.future;
                    throw StateError('create failed');
                  }).lazy(),
            ),
          ],
        ),
      ).initialize();
      final forced = scope
          .get(key: key)
          .force()
          .then<Object?>((_) => null, onError: (Object e) => e);
      await Future<void>.delayed(Duration.zero);
      final disposal = scope.dispose().then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      gate.complete();
      expect(await forced, isA<DisposedLazyException>());
      final disposeError = await disposal;
      expect(disposeError, isA<DisposeException>());
      expect(
        '${(disposeError! as DisposeException).disposeFailures}',
        contains('release failed'),
      );
    },
  );

  test(
    '3. a rejected reentrant dispose() leaves its target unchanged',
    () async {
      late final Scope target;
      Object? rejected;
      final caller = Scope(
        module: Module(
          components: [
            Component<int>.effect(
              dependency: Dependency(
                create: () async {
                  try {
                    await target.dispose();
                  } on ReentrantMutationError catch (error) {
                    rejected = error;
                  }
                  return 0;
                },
              ),
            ),
          ],
        ),
      );
      target = caller.child(); // the same runtime as the caller
      await caller.initialize();
      expect(rejected, isA<ReentrantMutationError>());
      await target.initialize(); // not disposed, so it initializes
      expect(target.isInitialized, isTrue);
      await caller.dispose();
    },
  );

  test('4. the rollback failures of every failed member are kept', () async {
    Component<int> failing(String name, {bool brokenRelease = false}) =>
        Component<int>(
          key: DiKey<int>(name: name),
          dependency:
              Dependency<int>(
                create: () => 1,
                dispose: (_) {
                  if (brokenRelease) throw StateError('$name release failed');
                },
              ).map<int>((_) async {
                await Future<void>.delayed(Duration.zero);
                throw StateError('$name failed');
              }),
        );
    final scope = Scope(
      module: Module(
        components: [failing('a'), failing('b', brokenRelease: true)],
      ),
    );
    final errors = <DiException>[];
    final subscription = scope.errors.listen(errors.add);
    final error = await scope.initialize().then<Object?>(
      (_) => null,
      onError: (Object e) => e,
    );
    await Future<void>.delayed(Duration.zero);
    expect(error, isA<ActivationException>());
    final failure = error! as ActivationException;
    expect('${failure.cause}', contains('a failed'), reason: 'first declared');
    expect('${failure.rollbackFailures}', contains('b release failed'));
    await subscription.cancel();
    await scope.dispose();
  });

  test('5. a callback registered in a finished mutation may mutate', () async {
    final events = StreamController<void>.broadcast();
    late final Scope target;
    final done = Completer<Object?>();
    final root = Scope(
      module: Module(
        components: [
          Component<StreamSubscription<void>>.effect(
            dependency: Dependency(
              create: () => events.stream.listen((_) {
                target.initialize().then(
                  (_) => done.complete(null),
                  onError: (Object e) => done.complete(e),
                );
              }),
              dispose: (subscription) => subscription.cancel(),
            ),
          ),
        ],
      ),
    );
    target = root.child(); // the same runtime as the listener
    await root.initialize();
    events.add(null); // after initialize has finished
    expect(await done.future, isNull);
    expect(target.isInitialized, isTrue);
    await root.dispose();
    await events.close();
  });

  group('6. a dispose from inside its own disposal is reentrant', () {
    test('scope', () async {
      late final Scope scope;
      scope = Scope(
        module: Module(
          components: [
            Component<int>.effect(
              dependency: Dependency<int>(
                create: () => 1,
                dispose: (_) => scope.dispose(),
              ),
            ),
          ],
        ),
      );
      await scope.initialize();
      final error = await scope
          .dispose()
          .timeout(const Duration(seconds: 2))
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<DisposeException>(), reason: 'no deadlock');
      expect(
        (error! as DisposeException).disposeFailures.single.error,
        isA<ReentrantMutationError>(),
      );
    });

    test('member', () async {
      final key = DiKey<int>(name: 'count');
      late final Scope scope;
      scope = Scope(
        module: Module(
          components: [
            Component<int>(
              key: key,
              dependency: Dependency<int>(
                create: () => 1,
                dispose: (_) => scope.node(key: key).dispose(),
              ),
            ),
          ],
        ),
      );
      await scope.initialize();
      final error = await scope
          .node(key: key)
          .dispose()
          .timeout(const Duration(seconds: 2))
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<DisposeException>(), reason: 'no deadlock');
      expect(
        (error! as DisposeException).disposeFailures.single.error,
        isA<ReentrantMutationError>(),
      );
      await scope.dispose();
    });
  });

  test('7. a second dispose shares the result while the first still runs '
      'after the scope is marked disposed', () async {
    var releases = 0;
    final scope = await Scope(
      module: Module(
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
      ),
    ).initialize();
    // A paused listener keeps errors.close() pending after the scope is
    // marked disposed, so the first dispose() has not completed yet.
    final subscription = scope.errors.listen((_) {})..pause();
    var firstDone = false;
    final first = scope.dispose().whenComplete(() => firstDone = true);
    final firstOutcome = expectLater(first, throwsA(isA<DisposeException>()));
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(firstDone, isFalse);
    final second = expectLater(
      scope.dispose(),
      throwsA(isA<DisposeException>()),
      reason: 'the second call shares the first one\'s failure',
    );
    subscription.resume();
    await firstOutcome;
    await second;
    expect(releases, 1);
    await subscription.cancel();
  });
}
