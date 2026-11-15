import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fp_di_fpdart/src/dependency.dart' show StepContext;
import 'package:fp_di_fpdart/src/dependency.dart'
    as internal
    show runDependency;
import 'package:fp_di_fpdart/src/environment.dart';
import 'package:fp_di_fpdart/src/finalizers.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

typedef Fn = int Function(int);

/// Runs [dependency] in a scope that publishes 5 and 'x' and reads the value.
Future<A> valueOf<A>(Dependency<A> dependency) async {
  final scope = Scope(
    components: [
      Component<int>.value(key: intKey, value: 5),
      Component<String>.value(key: textKey, value: 'x'),
      Component<A>(
        key: DiKey<A>(name: 'result'),
        dependency: dependency,
      ),
    ],
  );
  rightOf(await scope.run());
  return rightOf(scope.get<A>(key: DiKey<A>(name: 'result')));
}

void main() {
  final five = Dependency.require<int>(key: intKey);

  group('Applicative laws', () {
    test('Dependency is a Functor and an Applicative, not a Monad', () {
      final dependency = Dependency<int>.of(1);
      expect(dependency, isA<Functor<Object?, int>>());
      expect(dependency, isA<Applicative<Object?, int>>());
      expect(dependency, isNot(isA<Monad<Object?, int>>()));
    });

    test('identity: ap(pure(id)) keeps the value', () async {
      final mapped = five.ap(five.pure((int x) => x));
      expect(await valueOf(mapped), await valueOf(five));
    });

    test('homomorphism: pure(x).ap(pure(f)) is pure(f(x))', () async {
      int f(int x) => x * 3;
      final left = Dependency<int>.of(4).ap(Dependency<int>.of(0).pure(f));
      expect(await valueOf(left), f(4));
      expect(await valueOf(Dependency<int>.of(0).pure(f(4))), f(4));
    });

    test('interchange: pure(y).ap(u) applies u to y', () async {
      final u = five.map<int Function(int)>(
        (n) =>
            (x) => x + n,
      );
      final left = Dependency<int>.of(2).ap(u);
      final right = u.ap(
        Dependency<int>.of(
          0,
        ).pure<int Function(int Function(int))>((g) => g(2)),
      );
      expect(await valueOf(left), 7);
      expect(await valueOf(right), 7);
    });

    test(
      'composition: pure(compose) <*> u <*> v <*> w is u <*> (v <*> w)',
      () async {
        final u = Dependency<Fn>.of((int x) => x + 1);
        final v = Dependency<Fn>.of((int x) => x * 2);
        final w = five;
        final compose = Dependency<int>.of(0)
            .pure<Fn Function(Fn) Function(Fn)>(
              (f) =>
                  (g) =>
                      (x) => f(g(x)),
            );
        final left = w.ap<int>(v.ap<Fn>(u.ap<Fn Function(Fn)>(compose)));
        final right = w.ap<int>(v).ap<int>(u);
        expect(await valueOf(left), 11);
        expect(await valueOf(right), 11);
      },
    );

    test('map is ap(pure(f)), observable through a run', () async {
      String f(int x) => 'n$x';
      expect(await valueOf(five.map(f)), await valueOf(five.ap(five.pure(f))));
      expect(await valueOf(five.map(f)), 'n5');
    });

    test('map keeps its dispose argument', () async {
      final log = <String>[];
      final scope = Scope(
        components: [
          Component<String>(
            dependency: Dependency<int>.of(
              1,
            ).map<String>((v) => 'v$v', dispose: (v) => log.add('dispose $v')),
          ),
        ],
      );
      rightOf(await scope.run());
      rightOf(await scope.dispose());
      expect(log, ['dispose v1']);
    });

    test('ap runs this dependency first, then the function', () async {
      final log = <String>[];
      final value = Dependency<int>(
        create: () {
          log.add('value');
          return 1;
        },
      );
      final function = Dependency<int Function(int)>(
        create: () {
          log.add('function');
          return (int x) => x + 1;
        },
      );
      expect(await valueOf(value.ap(function)), 2);
      expect(log, ['value', 'function']);
    });

    test('ap and pure state the union of the reads', () {
      final function = Dependency.option<String>(key: textKey)
          .map<int Function(int)>(
            (_) =>
                (x) => x,
          );
      final applied = five.ap(function);
      expect(applied.requires, {intKey});
      expect(applied.optional, {textKey});
      expect(five.pure(1).requires, isEmpty);
    });

    test('a throw of the applied function is an ActivationFailure', () async {
      final scope = Scope(
        components: [
          Component<int>(
            debugLabel: 'broken',
            dependency: Dependency<int>.of(1).ap(
              Dependency<int Function(int)>.of((_) => throw StateError('x')),
            ),
          ),
        ],
      );
      final failure = await failureOfRun(scope);
      expect(failure, isA<ActivationFailure>());
      expect((failure as ActivationFailure).owner, 'broken');
    });
  });

  group('traverseList and sequenceList', () {
    test('traverseList gives the values in list order', () async {
      final log = <String>[];
      final all = Dependency.traverseList<int, String>(
        [1, 2, 3],
        (n) => Dependency<String>(
          create: () {
            log.add('create $n');
            return 'v$n';
          },
          dispose: (v) => log.add('dispose $v'),
        ),
      );
      expect(await valueOf(all), ['v1', 'v2', 'v3']);
      expect(log, ['create 1', 'create 2', 'create 3']);
    });

    test('sequenceList unites the reads and keeps the order', () async {
      final all = Dependency.sequenceList<Object?>([
        Dependency.require<int>(key: intKey),
        Dependency.require<String>(key: textKey),
        Dependency.option<bool>(key: flagKey),
      ]);
      expect(all.requires, {intKey, textKey});
      expect(all.optional, {flagKey});
      expect(await valueOf(all), [5, 'x', const None()]);
    });

    test('an empty list gives an empty list', () async {
      expect(await valueOf(Dependency.sequenceList<int>(const [])), isEmpty);
    });

    test('the owned values dispose in reverse list order', () async {
      final log = <String>[];
      final scope = Scope(
        components: [
          Component<List<int>>(
            dependency: Dependency.traverseList<int, int>(
              [1, 2, 3],
              (n) => Dependency<int>(
                create: () => n,
                dispose: (v) => log.add('dispose $v'),
              ),
            ),
          ),
        ],
      );
      rightOf(await scope.run());
      rightOf(await scope.dispose());
      expect(log, ['dispose 3', 'dispose 2', 'dispose 1']);
    });
  });

  group('interpreters', () {
    test('building a dependency performs no effect', () {
      var effects = 0;
      final built = Dependency<int>(create: () => ++effects)
          .map<int>((v) => ++effects + v)
          .mapTask<int>((v) => Task(() async => ++effects + v))
          .mapTaskEither<String, int>((v) => TaskEither.of(++effects + v))
          .map2<int, int>(
            Dependency<int>(create: () => ++effects),
            (a, b) => ++effects + a + b,
          )
          .ap(
            Dependency<int Function(int)>(
              create: () =>
                  (x) => ++effects,
            ),
          );
      Dependency.traverseList<int, int>([1, 2], (n) => built);
      // The reads fold is an interpreter that needs no effect, too.
      expect(built.requires, isEmpty);
      expect(built.optional, isEmpty);
      expect(effects, 0);
    });

    test('the reads fold and the runner agree', () async {
      final dependency = (
        Dependency.require<int>(key: intKey),
        Dependency.require<String>(key: textKey).map<int>((s) => s.length),
        Dependency.option<bool>(key: flagKey),
      ).zip.mapN<String>((a, b, c) => '$a $b $c');
      final reads = {...dependency.requires, ...dependency.optional};
      expect(reads, {intKey, textKey, flagKey});

      // The runner needs nothing more than the keys that the fold reports.
      final ref = IORef.create<Finalizers>(Finalizers.empty).run();
      Future<Exit<DiFailure, String>> runWith(
        Map<DiKey<Object?>, Object?> map,
      ) => internal
          .runDependency(
            dependency,
            StepContext('probe', Environment.of(map), ref),
          )
          .run();
      final full = await runWith({intKey: 5, textKey: 'xy', flagKey: true});
      expect(rightOf(full), '5 2 Some(true)');
      final onlyRequired = await runWith({intKey: 5, textKey: 'xy'});
      expect(rightOf(onlyRequired), '5 2 None');

      // The same fold drives the validation of a scope: every required key
      // that the fold reports is undeclared in a scope without publishers.
      final scope = Scope(
        components: [Component<String>(dependency: dependency)],
      );
      final cause = await causeOfRun(scope);
      expect({
        for (final f in cause.failures) (f as UndeclaredKeyFailure).key,
      }, dependency.requires);
    });

    test('running twice runs the effects twice, the tree is a value', () async {
      var effects = 0;
      final dependency = Dependency<int>(create: () => ++effects);
      expect(await valueOf(dependency), 1);
      expect(await valueOf(dependency), 2);
      expect(effects, 2);
    });
  });
}
