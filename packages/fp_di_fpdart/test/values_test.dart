import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fp_di_fpdart/src/finalizers.dart';
import 'package:test/test.dart';

void main() {
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

    test('an empty stack releases to Empty', () async {
      expect(Finalizers.empty.isEmpty, isTrue);
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
}
