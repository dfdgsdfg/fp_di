import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('reads', () {
    test('require, option, and of state their reads', () {
      final required = Dependency.require<int>(key: intKey);
      expect(required.requires, {intKey});
      expect(required.optional, isEmpty);
      final optional = Dependency.option<String>(key: textKey);
      expect(optional.requires, isEmpty);
      expect(optional.optional, {textKey});
      final pure = Dependency<int>.of(1);
      expect(pure.requires, isEmpty);
      expect(pure.optional, isEmpty);
      expect(Dependency.require<int>().requires, {const DiKey<int>()});
    });

    test('map keeps the reads', () {
      final dependency = Dependency.require<int>(
        key: intKey,
      ).map<String>((v) => '$v');
      expect(dependency.requires, {intKey});
    });

    test('map2 and map3 use the union of the reads', () {
      final a = Dependency.require<int>(key: intKey);
      final b = Dependency.option<String>(key: textKey);
      final c = Dependency.require<bool>(key: flagKey);
      final two = a.map2(b, (x, y) => (x, y));
      expect(two.requires, {intKey});
      expect(two.optional, {textKey});
      final three = a.map3(b, c, (x, y, z) => (x, y, z));
      expect(three.requires, {intKey, flagKey});
      expect(three.optional, {textKey});
    });

    test(
      'zip and mapN use the union of the reads and keep the order',
      () async {
        final log = <String>[];
        final zipped = (
          Dependency<int>(
            create: () => 1,
            dispose: (_) => log.add('dispose 1'),
          ),
          Dependency.require<String>(key: textKey),
          Dependency.option<bool>(key: flagKey),
        ).zip;
        expect(zipped.requires, {textKey});
        expect(zipped.optional, {flagKey});
        final scope = Scope(
          components: [
            Component<String>.value(key: textKey, value: 'x'),
            Component<String>(
              key: const DiKey<String>(name: 'joined'),
              dependency: zipped.mapN<String>(
                (a, b, c) => '$a $b $c',
                dispose: (v) => log.add('dispose $v'),
              ),
            ),
          ],
        );
        rightOf(await scope.run());
        expect(
          rightOf(scope.get<String>(key: const DiKey<String>(name: 'joined'))),
          '1 x None',
        );
        rightOf(await scope.dispose());
        expect(log, ['dispose 1 x None', 'dispose 1']);
      },
    );

    test('zip and mapN work for two to eight dependencies', () {
      Dependency<int> d(int v) => Dependency<int>.of(v);
      expect((d(1), d(2)).zip.mapN<int>((a, b) => a + b), isNotNull);
      expect((d(1), d(2), d(3)).zip.mapN<int>((a, b, c) => c), isNotNull);
      expect(
        (d(1), d(2), d(3), d(4)).zip.mapN<int>((a, b, c, e) => e),
        isNotNull,
      );
      expect(
        (d(1), d(2), d(3), d(4), d(5)).zip.mapN<int>((a, b, c, e, f) => f),
        isNotNull,
      );
      expect(
        (
          d(1),
          d(2),
          d(3),
          d(4),
          d(5),
          d(6),
        ).zip.mapN<int>((a, b, c, e, f, g) => g),
        isNotNull,
      );
      expect(
        (
          d(1),
          d(2),
          d(3),
          d(4),
          d(5),
          d(6),
          d(7),
        ).zip.mapN<int>((a, b, c, e, f, g, h) => h),
        isNotNull,
      );
      expect(
        (
          d(1),
          d(2),
          d(3),
          d(4),
          d(5),
          d(6),
          d(7),
          d(8),
        ).zip.mapN<int>((a, b, c, e, f, g, h, i) => i),
        isNotNull,
      );
    });

    test('zip of eight gives every value', () async {
      Dependency<int> d(int v) => Dependency<int>.of(v);
      final scope = Scope(
        components: [
          Component<int>(
            key: intKey,
            dependency: (d(1), d(2), d(3), d(4), d(5), d(6), d(7), d(8)).zip
                .mapN<int>(
                  (a, b, c, e, f, g, h, i) => a + b + c + e + f + g + h + i,
                ),
          ),
        ],
      );
      rightOf(await scope.run());
      expect(rightOf(scope.get<int>(key: intKey)), 36);
    });
  });

  group('steps', () {
    test('a dependency builds nothing before the scope runs', () async {
      var created = 0;
      final scope = Scope(
        components: [
          Component<int>(
            key: intKey,
            dependency: Dependency<int>(create: () => ++created),
          ),
        ],
      );
      expect(created, 0);
      rightOf(await scope.run());
      expect(created, 1);
    });

    test('create, task, and taskEither publish their values', () async {
      final scope = Scope(
        components: [
          Component<int>(
            key: intKey,
            dependency: Dependency<int>(create: () async => 1),
          ),
          Component<String>(
            key: textKey,
            dependency: Dependency.task<String>(Task(() async => 'two')),
          ),
          Component<bool>(
            key: flagKey,
            dependency: Dependency.taskEither<String, bool>(
              TaskEither.right(true),
            ),
          ),
        ],
      );
      rightOf(await scope.run());
      expect(rightOf(scope.get<int>(key: intKey)), 1);
      expect(rightOf(scope.get<String>(key: textKey)), 'two');
      expect(rightOf(scope.get<bool>(key: flagKey)), isTrue);
    });

    test('mapTask and mapTaskEither run after the earlier step', () async {
      final scope = Scope(
        components: [
          Component<int>(
            key: intKey,
            dependency: Dependency<int>.of(2)
                .mapTask<int>((v) => Task(() async => v * 3))
                .mapTaskEither<String, int>((v) => TaskEither.right(v + 1)),
          ),
        ],
      );
      rightOf(await scope.run());
      expect(rightOf(scope.get<int>(key: intKey)), 7);
    });

    test('a throw from create becomes an ActivationFailure', () async {
      final error = StateError('create');
      final failure = await failureOfRun(
        Scope(
          components: [
            Component<int>(
              key: intKey,
              debugLabel: 'broken',
              dependency: Dependency<int>(create: () => throw error),
            ),
          ],
        ),
      );
      expect(
        failure,
        isA<ActivationFailure>()
            .having((f) => f.owner, 'owner', 'broken')
            .having((f) => f.error, 'error', same(error)),
      );
    });

    test('a throw from map keeps the error and the stack trace', () async {
      final log = <String>[];
      late StackTrace thrown;
      final error = ArgumentError('bad');
      final dependency =
          Dependency<int>(
                create: () => 1,
                dispose: (_) {
                  log.add('dispose first');
                  throw StateError('rollback first');
                },
              )
              .map<int>((v) => v + 1, dispose: (_) => log.add('dispose second'))
              .map<int>((_) {
                try {
                  throw error;
                } catch (_, stackTrace) {
                  thrown = stackTrace;
                  rethrow;
                }
              }, dispose: (_) => log.add('never'));
      final cause = await causeOfRun(
        Scope(
          components: [Component<int>(key: intKey, dependency: dependency)],
        ),
      );
      // The failure, then the rollback: Then(Fail, Die).
      expect(cause, isA<Then<DiFailure>>());
      final then = cause as Then<DiFailure>;
      expect(then.first, isA<Fail<DiFailure>>());
      final fail = then.first as Fail<DiFailure>;
      expect(fail.error, isA<ActivationFailure>());
      expect((fail.error as ActivationFailure).error, same(error));
      expect(fail.stackTrace.toString(), thrown.toString());
      expect(then.second, isA<Die<DiFailure>>());
      expect(log, ['dispose second', 'dispose first']);
      expect(cause.defects, hasLength(1));
      final defect = cause.defects.single as DisposeFailure;
      expect(defect.error, isA<StateError>());
      expect(defect.owner, 'DiKey<int>(int)');
    });

    test('a Left from mapTaskEither is the error, not wrapped', () async {
      final log = <String>[];
      final dependency =
          Dependency<int>(
                create: () => 1,
                dispose: (_) => log.add('dispose first'),
              )
              .map<int>((v) => v, dispose: (_) => log.add('dispose second'))
              .mapTaskEither<String, int>(
                (_) => TaskEither.left('invalid'),
                dispose: (_) => log.add('never'),
              );
      final cause = await causeOfRun(
        Scope(
          components: [Component<int>(key: intKey, dependency: dependency)],
        ),
      );
      expect(cause, isA<Fail<DiFailure>>());
      expect((cause.only as ActivationFailure).error, 'invalid');
      expect((cause as Fail<DiFailure>).stackTrace.toString(), isNotEmpty);
      expect(cause.defects, isEmpty);
      expect(log, ['dispose second', 'dispose first']);
    });

    test('a Left from Dependency.taskEither fails the activation', () async {
      final failure = await failureOfRun(
        Scope(
          components: [
            Component<int>(
              key: intKey,
              dependency: Dependency.taskEither<int, int>(TaskEither.left(7)),
            ),
          ],
        ),
      );
      expect((failure as ActivationFailure).error, 7);
    });

    test(
      'the owned values of one component dispose in reverse order',
      () async {
        final log = <String>[];
        final dependency =
            Dependency<int>(create: () => 1, dispose: (_) => log.add('first'))
                .mapTask<int>(
                  (v) => Task(() async => v + 1),
                  dispose: (_) => log.add('second'),
                )
                .map<int>((v) => v + 1, dispose: (_) => log.add('third'));
        final scope = Scope(
          components: [Component<int>(key: intKey, dependency: dependency)],
        );
        rightOf(await scope.run());
        expect(rightOf(scope.get<int>(key: intKey)), 3);
        rightOf(await scope.dispose());
        expect(log, ['third', 'second', 'first']);
      },
    );

    test('Dependency.of owns nothing', () async {
      final scope = Scope(
        components: [
          Component<int>(key: intKey, dependency: Dependency<int>.of(4)),
        ],
      );
      rightOf(await scope.run());
      rightOf(await scope.dispose());
    });
  });

  group('Component', () {
    test('the key defaults to the type, and the label to the key', () {
      final unnamed = Component<int>(dependency: Dependency<int>.of(1));
      expect(unnamed.key, const DiKey<int>());
      expect(unnamed.label, 'DiKey<int>');
      final named = Component<int>.value(
        value: 1,
        key: intKey,
        debugLabel: 'one',
      );
      expect(named.key, intKey);
      expect(named.label, 'one');
      expect(
        Component<int>.value(value: 1, key: intKey).label,
        'DiKey<int>(int)',
      );
    });

    test('the reads come from the dependency', () {
      final component = Component<String>(
        dependency: Dependency.require<int>(
          key: intKey,
        ).map2(Dependency.option<bool>(key: flagKey), (a, b) => '$a $b'),
      );
      expect(component.requires, {intKey});
      expect(component.optional, {flagKey});
    });

    test(
      'a list of components with concrete dispose functions works',
      () async {
        final disposed = <Object>[];
        final components = <Component<Object?>>[
          Component<int>(
            key: intKey,
            dependency: Dependency<int>(
              create: () => 1,
              dispose: (int value) => disposed.add(value),
            ),
          ),
          Component<String>(
            key: textKey,
            dependency: Dependency.require<int>(key: intKey).map<String>(
              (v) => 'v$v',
              dispose: (String value) => disposed.add(value),
            ),
          ),
          Component<List<int>>(
            dependency: Dependency<List<int>>(
              create: () => [1],
              dispose: (List<int> value) => disposed.add(value.length),
            ),
          ),
        ];
        final scope = Scope(components: components);
        rightOf(await scope.run());
        rightOf(await scope.dispose());
        expect(disposed, hasLength(3));
        expect(disposed, containsAll(<Object>[1, 'v1']));
      },
    );
  });

  group('DiKey', () {
    test('equality uses the type and the name', () {
      expect(const DiKey<int>(), const DiKey<int>());
      expect(const DiKey<int>().hashCode, const DiKey<int>().hashCode);
      expect(const DiKey<int>(name: 'a'), const DiKey<int>(name: 'a'));
      expect(const DiKey<int>(name: 'a'), isNot(const DiKey<int>(name: 'b')));
      expect(const DiKey<int>(), isNot(const DiKey<num>()));
      expect(const DiKey<int>(), isNot(const DiKey<int>(name: 'a')));
      expect(const DiKey<int>().type, int);
    });

    test('toString shows the type and the name', () {
      expect(const DiKey<int>().toString(), 'DiKey<int>');
      expect(const DiKey<int>(name: 'a').toString(), 'DiKey<int>(a)');
    });
  });
}
