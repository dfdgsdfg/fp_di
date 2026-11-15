import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fp_di_fpdart/src/component.dart' show buildComponent;
import 'package:fp_di_fpdart/src/environment.dart';
import 'package:fp_di_fpdart/src/finalizers.dart';
import 'package:fp_di_fpdart/src/plan.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  const a = DiKey<int>(name: 'a');
  const b = DiKey<String>(name: 'b');

  Component<Object?> making<T>(
    DiKey<T> key,
    T value,
    List<String> log, {
    Object? failDispose,
  }) => logged<T>(key.name!, value, log, key: key, failDispose: failDispose);

  Component<Object?> failing(String name) => Component<int>(
    key: DiKey<int>(name: name),
    debugLabel: name,
    dependency: Dependency<int>(create: () => throw name),
  );

  group('Environment', () {
    test('the monoid is right-biased and has an identity', () {
      final below = Environment.of({a: 1, b: 'a'});
      final above = Environment.of({a: 2});
      final stacked = Environment.monoid.combine(below, above);
      expect(stacked.read(a), 2);
      expect(stacked.read(b), 'a');
      expect(Environment.monoid.combine(Environment.empty, below).read(a), 1);
      expect(Environment.monoid.combine(below, Environment.empty).read(b), 'a');
      expect(below.read(a), 1);
    });

    test('the monoid is associative', () {
      final x = Environment.of({a: 1});
      final y = Environment.of({a: 2, b: 'y'});
      final z = Environment.of({b: 'z'});
      final left = Environment.monoid.combine(
        Environment.monoid.combine(x, y),
        z,
      );
      final right = Environment.monoid.combine(
        x,
        Environment.monoid.combine(y, z),
      );
      expect(left.read(a), right.read(a));
      expect(left.read(b), right.read(b));
    });

    test('lookup tells a null value from a missing value', () {
      final environment = Environment.of({const DiKey<int?>(): null});
      expect(
        environment.lookup(const DiKey<int?>()),
        const Some<Object?>(null),
      );
      expect(environment.lookup(a), const None());
      expect(environment.contains(a), isFalse);
    });

    test('the environment is a copy', () {
      final entries = <DiKey<Object?>, Object?>{a: 1};
      final environment = Environment.of(entries);
      entries[a] = 2;
      expect(environment.read(a), 1);
    });
  });

  group('Finalizers', () {
    test(
      'a release runs the newest entry first, one after the other',
      () async {
        final log = <String>[];
        final stack = Finalizers.empty
            .push('a', () => log.add('a'))
            .push('b', () => log.add('b'))
            .push('c', () => throw 'c failed');
        final cause = await stack.release().run();
        expect(log, ['b', 'a']);
        expect(cause.defects, [const DisposeFailure('c', 'c failed')]);
      },
    );

    test('a group releases every member', () async {
      final log = <String>[];
      final group = Finalizers.empty.pushGroup([
        Finalizers.empty.push('a', () => throw 'a failed'),
        Finalizers.empty.push('b', () => log.add('b')),
        Finalizers.empty.push('c', () => throw 'c failed'),
      ]);
      final cause = await group.release().run();
      expect(log, ['b']);
      expect(cause.defects, [
        const DisposeFailure('a', 'a failed'),
        const DisposeFailure('c', 'c failed'),
      ]);
      expect(cause, isA<Both<DiFailure>>());
    });

    test('an empty group and an empty stack release to Empty', () async {
      expect(Finalizers.empty.pushGroup(const []).isEmpty, isTrue);
      expect(await Finalizers.empty.release().run(), const Empty<DiFailure>());
    });

    group('Monoid', () {
      final monoid = Finalizers.monoid;

      /// The names of the entries in release order.
      Future<List<String>> order(Finalizers stack, List<String> log) async {
        log.clear();
        await stack.release().run();
        return [...log];
      }

      Finalizers entry(String name, List<String> log) =>
          Finalizers.empty.push(name, () => log.add(name));

      test('the identity is the empty stack', () async {
        final log = <String>[];
        final x = entry('a', log).push('b', () => log.add('b'));
        expect(monoid.empty, same(Finalizers.empty));
        expect(await order(monoid.combine(monoid.empty, x), log), ['b', 'a']);
        expect(await order(monoid.combine(x, monoid.empty), log), ['b', 'a']);
      });

      test('combine is associative, seen through the release order', () async {
        final log = <String>[];
        final x = entry('x', log);
        final y = entry('y', log).push('y2', () => log.add('y2'));
        final z = entry('z', log);
        final left = monoid.combine(monoid.combine(x, y), z);
        final right = monoid.combine(x, monoid.combine(y, z));
        expect(await order(left, log), ['z', 'y2', 'y', 'x']);
        expect(await order(right, log), ['z', 'y2', 'y', 'x']);
      });

      test('the second stack releases first', () async {
        final log = <String>[];
        final both = monoid.combine(entry('first', log), entry('second', log));
        expect(await order(both, log), ['second', 'first']);
      });

      test('a group keeps its place in a combination', () async {
        final log = <String>[];
        final group = Finalizers.empty.pushGroup([
          entry('g1', log),
          entry('g2', log),
        ]);
        final stack = monoid.combine(entry('below', log), group);
        final released = await order(stack, log);
        expect(released.last, 'below');
        expect(released.take(2), unorderedEquals(['g1', 'g2']));
      });
    });

    test('a stack is immutable', () async {
      final log = <String>[];
      final base = Finalizers.empty.push('a', () => log.add('a'));
      base.push('b', () => log.add('b'));
      await base.release().run();
      expect(log, ['a']);
    });
  });

  group('DiKey typeclasses', () {
    test('Eq is reflexive, symmetric, and follows ==', () {
      const keys = <DiKey<Object?>>[
        DiKey<int>(),
        DiKey<int>(name: 'a'),
        DiKey<String>(),
        DiKey<num>(),
      ];
      for (final x in keys) {
        expect(DiKey.eq.eqv(x, x), isTrue);
        for (final y in keys) {
          expect(DiKey.eq.eqv(x, y), DiKey.eq.eqv(y, x));
          expect(DiKey.eq.eqv(x, y), x == y);
        }
      }
      expect(DiKey.eq.eqv(const DiKey<int>(), const DiKey<int>()), isTrue);
    });

    test('Hash agrees with Eq', () {
      expect(
        DiKey.hash.hash(const DiKey<int>(name: 'a')),
        DiKey.hash.hash(const DiKey<int>(name: 'a')),
      );
      expect(DiKey.hash.eqv(const DiKey<int>(), const DiKey<int>()), isTrue);
    });

    test('a key of an effect equals only itself', () {
      final first = Component<int>.effect(dependency: Dependency<int>.of(1));
      final second = Component<int>.effect(dependency: Dependency<int>.of(1));
      expect(DiKey.eq.eqv(first.key, first.key), isTrue);
      expect(DiKey.eq.eqv(first.key, second.key), isFalse);
      expect(DiKey.eq.eqv(first.key, const DiKey<int>()), isFalse);
      expect(DiKey.eq.eqv(const DiKey<int>(), first.key), isFalse);
    });
  });

  group('Component build', () {
    test('a component maps an environment to a value and finalizers', () async {
      final log = <String>[];
      final component = Component<int>(
        key: a,
        dependency: Dependency.require<int>(
          key: a,
        ).map<int>((v) => v + 1, dispose: (v) => log.add('dispose $v')),
      );
      final (out, finalizers) = rightOf(
        await buildComponent(component, Environment.of({a: 1})).run(),
      );
      expect(out.read(a), 2);
      expect(log, isEmpty);
      await finalizers.release().run();
      expect(log, ['dispose 2']);
    });
  });

  group('Plan.build', () {
    test('a stratum stacks the outputs and groups the finalizers', () async {
      final log = <String>[];
      final (out, finalizers) = rightOf(
        await Plan.build([
          [making<int>(a, 1, log), making<String>(b, 'a', log)],
        ], Environment.empty).run(),
      );
      expect(out.read(a), 1);
      expect(out.read(b), 'a');
      await finalizers.release().run();
      expect(log.take(2), unorderedEquals(['create a', 'create b']));
      expect(log.skip(2), unorderedEquals(['dispose a', 'dispose b']));
    });

    test('a stratum with failures: Both, then the release', () async {
      final log = <String>[];
      final cause = leftOf(
        await Plan.build([
          [
            failing('one'),
            making<int>(a, 1, log, failDispose: 'rollback'),
            failing('two'),
          ],
        ], Environment.empty).run(),
      );
      expect(log, ['create a', 'dispose a']);
      expect(
        [for (final f in cause.failures) (f as ActivationFailure).owner],
        ['one', 'two'],
      );
      expect(cause.defects.single, isA<DisposeFailure>());
      expect(cause, isA<Then<DiFailure>>());
      expect((cause as Then<DiFailure>).first, isA<Both<DiFailure>>());
    });

    test('a stratum reads the outputs of the strata before it', () async {
      final log = <String>[];
      final reader = Component<String>(
        key: b,
        dependency: Dependency.require<int>(
          key: a,
        ).map<String>((v) => 'saw $v', dispose: (v) => log.add('dispose $v')),
      );
      final (out, finalizers) = rightOf(
        await Plan.build([
          [making<int>(a, 1, log)],
          [reader],
        ], Environment.of({const DiKey<bool>(): true})).run(),
      );
      expect(out.read(b), 'saw 1');
      expect(out.read(a), 1);
      expect(out.read(const DiKey<bool>()), isTrue);
      await finalizers.release().run();
      expect(log, ['create a', 'dispose saw 1', 'dispose a']);
    });

    test('a failure stops the later strata and releases once', () async {
      final log = <String>[];
      final cause = leftOf(
        await Plan.build([
          [making<int>(a, 1, log, failDispose: 'one')],
          [making<String>(b, 'a', log, failDispose: 'two')],
          [failing('boom')],
          [making<bool>(const DiKey<bool>(name: 'late'), true, log)],
        ], Environment.empty).run(),
      );
      expect(log, ['create a', 'create b', 'dispose b', 'dispose a']);
      expect((cause.failures.single as ActivationFailure).owner, 'boom');
      expect(cause.defects, [
        const DisposeFailure('b', 'two'),
        const DisposeFailure('a', 'one'),
      ]);
      // The failure, then one release: Then(F, Then(D, D)).
      expect(
        cause.fold<String>(
          empty: () => '_',
          fail: (_, _) => 'F',
          die: (_, _) => 'D',
          then: (first, second) => '($first $second)',
          both: (left, right) => '[$left $right]',
        ),
        '(F (D D))',
      );
    });
  });
}
