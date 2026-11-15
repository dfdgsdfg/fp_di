import 'dart:async';

import 'package:fp_di/fp_di.dart';
import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

final _intKey = DiKey<int>(name: 'count');
final _textKey = DiKey<String>(name: 'text');

Module _value(
  int value, {
  void Function(int)? onDispose,
  Object? failDispose,
}) => Module(
  components: [
    Component<int>(
      key: _intKey,
      dependency: Dependency<int>(
        create: () => value,
        dispose: (v) {
          onDispose?.call(v);
          if (failDispose != null) throw failDispose;
        },
      ),
    ),
  ],
);

void main() {
  group('Scope lifecycle', () {
    test('initializeTask is lazy and runs initialize once per run', () async {
      final scope = Scope(module: _value(1));
      final task = scope.initializeTask();
      expect(scope.isInitialized, isFalse);
      expect((await task.run()).isRight(), isTrue);
      final second = (await task.run()).getLeft().toNullable();
      expect(second?.error, isA<StateError>());
      await scope.dispose();
    });

    test(
      'a setup failure keeps the cause, stack, and rollback failures',
      () async {
        final scope = Scope(
          module: Module(
            components: [
              Component<int>(
                key: _intKey,
                dependency: Dependency<int>(
                  create: () => 1,
                  dispose: (_) => throw StateError('rollback failed'),
                ).map<int>((_) => throw ArgumentError('bad')),
              ),
            ],
          ),
        );
        final failure = (await scope.initializeTask().run())
            .getLeft()
            .toNullable()!;
        expect(failure.error, isA<ActivationException>());
        expect(failure.cause, isA<ArgumentError>());
        expect(failure.disposeFailures.single.error, isA<StateError>());
        expect(failure.stackTrace.toString(), isNotEmpty);
        expect(failure.isCanceled, isFalse);
        await scope.dispose();
      },
    );

    test('disposeTask carries the DisposeException and its failures', () async {
      final scope = Scope(module: _value(1, failDispose: StateError('x')));
      await scope.initialize();
      final failure = (await scope.disposeTask().run()).getLeft().toNullable()!;
      expect(failure.error, isA<DisposeException>());
      expect(failure.disposeFailures.single.error, isA<StateError>());
    });
  });

  group('Scope.use', () {
    test('disposes after a Right', () async {
      final disposed = <int>[];
      final result = await Scope(module: _value(7, onDispose: disposed.add))
          .use(
            ReaderTaskEither<Scope, Never, int>.asks(
              (s) => s.get(key: _intKey),
            ),
          )
          .run();
      expect(result, const Right<ScopeFailure<Never>, int>(7));
      expect(disposed, [7]);
    });

    test('disposes after a Left of the use', () async {
      final disposed = <int>[];
      final result = await Scope(
        module: _value(7, onDispose: disposed.add),
      ).use(ReaderTaskEither<Scope, String, int>.left('no')).run();
      expect(
        result.getLeft().toNullable(),
        isA<UseFailed<String>>().having((e) => e.error, 'error', 'no'),
      );
      expect(disposed, [7]);
    });

    test('a setup failure runs nothing', () async {
      var ran = false;
      final result =
          await Scope(
                module: Module(
                  components: [
                    Component<int>(
                      key: _intKey,
                      dependency: Dependency<int>(
                        create: () => throw StateError('x'),
                      ),
                    ),
                  ],
                ),
              )
              .use(
                ReaderTaskEither<Scope, Never, Unit>.asks((_) {
                  ran = true;
                  return unit;
                }),
              )
              .run();
      expect(
        result.getLeft().toNullable(),
        isA<InitializeFailed<Never>>().having(
          (e) => e.failure.cause,
          'cause',
          isA<StateError>(),
        ),
      );
      expect(ran, isFalse);
    });

    test('a dispose failure keeps the use result too', () async {
      final result = await Scope(
        module: _value(1, failDispose: 'release'),
      ).use(ReaderTaskEither<Scope, String, int>.left('use failed')).run();
      expect(
        result.getLeft().toNullable(),
        isA<DisposeFailed<String>>()
            .having((e) => e.failure.error, 'error', isA<DisposeException>())
            .having((e) => e.useError, 'useError', const Some('use failed')),
      );
    });

    test('a throwing use disposes and rethrows', () async {
      final disposed = <int>[];
      final scope = Scope(module: _value(1, onDispose: disposed.add));
      await expectLater(
        scope
            .use(
              ReaderTaskEither<Scope, Never, Unit>(
                (_) async => throw StateError('bug'),
              ),
            )
            .run(),
        throwsStateError,
      );
      expect(disposed, [1]);
    });
  });

  group('lookups', () {
    test('getEither and getOption', () async {
      final scope = await Scope(module: _value(3)).initialize();
      expect(scope.getEither(key: _intKey), const Right<DiFailure, int>(3));
      expect(scope.getEither(key: _textKey).isLeft(), isTrue);
      expect(scope.getOption(key: _intKey), const Some(3));
      expect(scope.getOption(key: _textKey), const None());
      await scope.dispose();
    });

    test('whenActiveTask waits for a dormant member', () async {
      final parent = Scope(module: _value(2));
      final child = parent.child(
        module: Module(
          components: [
            Component<String>(
              key: _textKey,
              dependency: Dependency1<int, String>(
                key1: _intKey,
                create: (v) => 'v$v',
              ),
            ),
          ],
        ),
      );
      await child.initialize();
      final active = child.node(key: _textKey).whenActiveTask().run();
      await parent.initialize();
      expect(await active, const Right<DiFailure, String>('v2'));
      await parent.dispose();
    });

    test(
      'whenActiveTask is a Left when the member is disposed first',
      () async {
        final parent = Scope(module: _value(2));
        final child = parent.child(
          module: Module(
            components: [
              Component<String>(
                key: _textKey,
                dependency: Dependency1<int, String>(
                  key1: _intKey,
                  create: (v) => 'v$v',
                ),
              ),
            ],
          ),
        );
        await child.initialize(); // dormant: the parent is not initialized
        final active = child.node(key: _textKey).whenActiveTask().run();
        await child.dispose();
        expect((await active).isLeft(), isTrue);
        await parent.dispose();
      },
    );
  });

  group('Dependency steps', () {
    Future<Scope> scopeOf(Dependency<String> dependency) => Scope(
      module: Module(
        components: [
          ..._value(4).components,
          Component<String>(key: _textKey, dependency: dependency),
        ],
      ),
    ).initialize();

    test('mapTaskEither publishes a Right and disposes it', () async {
      final disposed = <String>[];
      final scope = await scopeOf(
        Dependency.require<int>(key: _intKey).mapTaskEither(
          (v) => TaskEither<String, String>.right('r$v'),
          dispose: disposed.add,
        ),
      );
      expect(scope.get(key: _textKey), 'r4');
      await scope.dispose();
      expect(disposed, ['r4']);
    });

    test('mapTaskEither fails the setup on a Left and rolls back', () async {
      final released = <String>[];
      final scope = Scope(
        module: Module(
          components: [
            Component<String>(
              key: _textKey,
              dependency: Dependency<String>(
                create: () => 'first',
                dispose: released.add,
              ).mapTaskEither((_) => TaskEither<int, String>.left(42)),
            ),
          ],
        ),
      );
      final failure = (await scope.initializeTask().run())
          .getLeft()
          .toNullable()!;
      expect(
        failure.cause,
        isA<DependencyLeft<int>>().having((e) => e.left, 'left', 42),
      );
      expect(released, ['first'], reason: 'the completed step is disposed');
      await scope.dispose();
    });

    test('mapTaskEitherAsData keeps a Left as the value', () async {
      final disposed = <String>[];
      final scope = await Scope(
        module: Module(
          components: [
            Component<Either<int, String>>(
              key: DiKey<Either<int, String>>(),
              dependency: Dependency<Unit>(create: () => unit)
                  .mapTaskEitherAsData(
                    (_) => TaskEither<int, String>.left(5),
                    dispose: disposed.add,
                  ),
            ),
          ],
        ),
      ).initialize();
      expect(scope.get<Either<int, String>>(), const Left<int, String>(5));
      await scope.dispose();
      expect(disposed, isEmpty, reason: 'a Left needs no dispose');
    });

    test('mapTaskEitherAsData disposes a Right', () async {
      final disposed = <String>[];
      final scope = await Scope(
        module: Module(
          components: [
            Component<Either<int, String>>(
              key: DiKey<Either<int, String>>(),
              dependency: Dependency<Unit>(create: () => unit)
                  .mapTaskEitherAsData(
                    (_) => TaskEither<int, String>.right('ok'),
                    dispose: disposed.add,
                  ),
            ),
          ],
        ),
      ).initialize();
      await scope.dispose();
      expect(disposed, ['ok']);
    });

    test('mapTask runs a Task', () async {
      final scope = await scopeOf(
        Dependency.require<int>(
          key: _intKey,
        ).mapTask((v) => Task(() async => 't$v')),
      );
      expect(scope.get(key: _textKey), 't4');
      await scope.dispose();
    });

    test('a step keeps the shape of the dependency', () {
      final dependency = Dependency.require<int>(
        key: _intKey,
      ).mapTaskEither((v) => TaskEither<String, String>.right('$v'));
      final module = Module(
        components: [Component<String>(key: _textKey, dependency: dependency)],
      );
      expect(module.requires, {_intKey});
    });

    test('toOption makes an optional read an Option', () async {
      Future<Option<int>> read(Module extra) async {
        final key = DiKey<Option<int>>();
        final scope = await Scope(
          module: Module(
            components: [
              ...extra.components,
              Component<Option<int>>(
                key: key,
                dependency: Dependency.maybe<int>(key: _intKey).toOption(),
              ),
            ],
          ),
        ).initialize();
        final value = scope.get(key: key);
        await scope.dispose();
        return value;
      }

      expect(await read(_value(9)), const Some(9));
      expect(await read(Module(components: const [])), const None());
    });
  });

  test('toTaskEither forces a Lazy as a task', () async {
    var creations = 0;
    var fail = true;
    final key = DiKey<Lazy<int>>(name: 'lazy');
    final scope = await Scope(
      module: Module(
        components: [
          Component<Lazy<int>>(
            key: key,
            dependency: Dependency<int>(
              create: () {
                creations++;
                if (fail) throw StateError('not yet');
                return 42;
              },
            ).lazy(),
          ),
        ],
      ),
    ).initialize();

    final lazy = scope.get(key: key);
    final task = lazy.toTaskEither();
    expect(creations, 0, reason: 'building the task creates nothing');

    final failed = await task.run();
    expect(failed.getLeft().toNullable()?.cause, isA<StateError>());
    expect(lazy.isCreated, isFalse);

    fail = false;
    expect((await task.run()).getRight().toNullable(), 42);
    expect((await task.run()).getRight().toNullable(), 42);
    expect(creations, 2, reason: 'a failure is not cached; a value is');

    await scope.dispose();
    final disposed = await task.run();
    expect(
      disposed.getLeft().toNullable()?.error,
      isA<DisposedLazyException>(),
    );
  });

  test('canceledTask completes when the token is canceled', () async {
    final controller = CancellationController();
    var done = false;
    unawaited(controller.token.canceledTask.run().then((_) => done = true));
    await Future<void>.delayed(Duration.zero);
    expect(done, isFalse);
    controller.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(done, isTrue);
  });
}
