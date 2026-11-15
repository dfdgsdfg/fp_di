import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  Scope scopeOf(List<String> log, {Object? failDispose}) => Scope(
    components: [
      logged<int>('a', 7, log, key: intKey, failDispose: failDispose),
    ],
  );

  test('use is lazy', () async {
    final log = <String>[];
    final scope = scopeOf(log);
    final task = scope.use(ReaderTaskEither<Scope, Never, int>.of(1));
    expect(log, isEmpty);
    expect(scope.phase, ScopePhase.declared);
    expect(
      await task.run(),
      isA<Right<Cause<Either<DiFailure, Never>>, int>>(),
    );
    expect(log, ['create a', 'dispose a']);
  });

  test('a Right result disposes the scope', () async {
    final log = <String>[];
    final scope = scopeOf(log);
    final result = await scope
        .use(
          ReaderTaskEither<Scope, Never, int>(
            (scope) async => Right(rightOf(scope.get<int>(key: intKey))),
          ),
        )
        .run();
    expect(rightOf(result), 7);
    expect(log, ['create a', 'dispose a']);
    expect(scope.phase, ScopePhase.disposed);
  });

  test(
    'a Left of the program is a Fail of Right, and the scope disposes',
    () async {
      final log = <String>[];
      final result = await scopeOf(
        log,
      ).use(ReaderTaskEither<Scope, String, int>.left('no')).run();
      final cause = leftOf(result);
      expect(cause, isA<Fail<Either<DiFailure, String>>>());
      expect(cause.only, const Right<DiFailure, String>('no'));
      expect(cause.defects, isEmpty);
      expect(log, ['create a', 'dispose a']);
    },
  );

  test(
    'a failed run is a Fail of Left, and the program does not run',
    () async {
      var ran = false;
      final scope = Scope(
        components: [
          Component<int>(
            key: intKey,
            dependency: Dependency<int>(create: () => throw StateError('x')),
          ),
        ],
      );
      final result = await scope
          .use(
            ReaderTaskEither<Scope, Never, Unit>.asks((_) {
              ran = true;
              return unit;
            }),
          )
          .run();
      final failure = leftOf(result).only;
      expect(failure.isLeft(), isTrue);
      expect(
        failure.getLeft().toNullable(),
        isA<ActivationFailure>().having(
          (f) => f.error,
          'error',
          isA<StateError>(),
        ),
      );
      expect(ran, isFalse);
      expect(scope.phase, ScopePhase.disposed);
    },
  );

  test(
    'a failed disposal keeps the program failure: Then(Fail, Die)',
    () async {
      final result = await scopeOf(
        <String>[],
        failDispose: 'release',
      ).use(ReaderTaskEither<Scope, String, int>.left('use failed')).run();
      final cause = leftOf(result);
      expect(cause, isA<Then<Either<DiFailure, String>>>());
      expect(cause.failures, [const Right<DiFailure, String>('use failed')]);
      expect(cause.defects.single, const DisposeFailure('a', 'release'));
    },
  );

  test('a failed disposal after a Right is the disposal cause', () async {
    final result = await scopeOf(
      <String>[],
      failDispose: 'release',
    ).use(ReaderTaskEither<Scope, String, int>.of(1)).run();
    final cause = leftOf(result);
    expect(cause.failures, isEmpty);
    expect(cause.defects, [const DisposeFailure('a', 'release')]);
  });

  test(
    'a throwing program is a Die, disposes the scope, and does not rethrow',
    () async {
      final log = <String>[];
      final scope = scopeOf(log);
      final bug = StateError('bug');
      final result = await scope
          .use(ReaderTaskEither<Scope, Never, int>((_) async => throw bug))
          .run();
      final cause = leftOf(result);
      expect(cause, isA<Die<Either<DiFailure, Never>>>());
      expect(cause.defects.single, same(bug));
      expect(cause.failures, isEmpty);
      expect(log, ['create a', 'dispose a']);
      expect(scope.phase, ScopePhase.disposed);
    },
  );

  test('a throwing program and a failed disposal keep both', () async {
    final bug = StateError('bug');
    final result = await scopeOf(
      <String>[],
      failDispose: 'release',
    ).use(ReaderTaskEither<Scope, Never, int>((_) async => throw bug)).run();
    final cause = leftOf(result);
    expect(cause, isA<Then<Either<DiFailure, Never>>>());
    expect(cause.defects, [bug, const DisposeFailure('a', 'release')]);
  });

  test('use on a scope that is not declared does not dispose it', () async {
    final log = <String>[];
    final scope = scopeOf(log);
    rightOf(await scope.run());
    final result = await scope
        .use(ReaderTaskEither<Scope, Never, int>.of(1))
        .run();
    expect(
      leftOf(result).only.getLeft().toNullable(),
      isA<ScopePhaseFailure>(),
    );
    expect(scope.phase, ScopePhase.initialized);
    expect(log, ['create a']);
    rightOf(await scope.dispose());
  });

  test('a program of use runs against the scope with a child', () async {
    final log = <String>[];
    final result = await scopeOf(log)
        .use(
          ReaderTaskEither<Scope, DiFailure, String>((scope) async {
            final child = scope.kid(
              components: [
                Component<String>(
                  key: textKey,
                  dependency: Dependency.require<int>(
                    key: intKey,
                  ).map<String>((v) => 'child $v'),
                ),
              ],
            );
            final run = await child.run();
            return run
                .mapLeft((cause) => cause.only)
                .flatMap((_) => child.get<String>(key: textKey));
          }),
        )
        .run();
    expect(rightOf(result), 'child 7');
    expect(log, ['create a', 'dispose a']);
  });
}
