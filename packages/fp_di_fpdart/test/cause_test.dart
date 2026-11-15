import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

void main() {
  final trace = StackTrace.current;
  Cause<int> fail(int error) => Fail<int>(error, trace);
  Cause<int> die(Object defect) => Die<int>(defect, trace);
  const Cause<int> empty = Empty<int>();

  final samples = <Cause<int>>[
    empty,
    fail(1),
    die('d'),
    Then<int>(fail(1), die('d')),
    Both<int>(fail(1), Then<int>(fail(2), die('e'))),
  ];

  group('identity', () {
    test('Empty is the identity of + and &', () {
      for (final cause in samples) {
        expect(empty + cause, same(cause));
        expect(cause + empty, same(cause));
        expect(empty & cause, same(cause));
        expect(cause & empty, same(cause));
      }
    });

    test('+ builds Then and & builds Both', () {
      expect(fail(1) + fail(2), isA<Then<int>>());
      expect(fail(1) & fail(2), isA<Both<int>>());
      expect((fail(1) + fail(2)), Then<int>(fail(1), fail(2)));
      expect((fail(1) & fail(2)), Both<int>(fail(1), fail(2)));
    });

    test('isEmpty means no Fail and no Die anywhere', () {
      expect(empty.isEmpty, isTrue);
      expect(const Then<int>(Empty(), Empty()).isEmpty, isTrue);
      expect(
        const Both<int>(Empty(), Then<int>(Empty(), Empty())).isEmpty,
        isTrue,
      );
      expect(fail(1).isEmpty, isFalse);
      expect(die('d').isEmpty, isFalse);
      expect(Then<int>(empty, fail(1)).isEmpty, isFalse);
    });
  });

  group('Functor', () {
    test('a cause is a Functor', () {
      expect(fail(1), isA<Functor<Object?, int>>());
    });

    test('map identity', () {
      for (final cause in samples) {
        expect(cause.map((error) => error), cause);
      }
    });

    test('map composition', () {
      int f(int x) => x + 10;
      int g(int x) => x * 2;
      for (final cause in samples) {
        expect(cause.map(f).map(g), cause.map((x) => g(f(x))));
      }
    });

    test('map changes the typed errors and keeps the defects', () {
      final mapped = samples.last.map((error) => 'e$error');
      expect(mapped.failures, ['e1', 'e2']);
      expect(mapped.defects, ['e']);
      expect(mapped, isA<Both<String>>());
    });

    test('map keeps the stack trace', () {
      final mapped = fail(1).map((e) => e + 1) as Fail<int>;
      expect(mapped.stackTrace, same(trace));
    });
  });

  group('reading', () {
    final cause = Both<int>(
      Then<int>(fail(1), die('a')),
      Then<int>(fail(2), Both<int>(die('b'), fail(3))),
    );

    test('failures and defects go from left to right', () {
      expect(cause.failures, [1, 2, 3]);
      expect(cause.defects, ['a', 'b']);
    });

    test('failureOption is the first typed error', () {
      expect(cause.failureOption, const Some(1));
      expect(die('d').failureOption, const None());
      expect(empty.failureOption, const None());
    });

    test('fold visits each case', () {
      final shape = cause.fold<String>(
        empty: () => '_',
        fail: (error, _) => 'F$error',
        die: (defect, _) => 'D$defect',
        then: (first, second) => '($first>$second)',
        both: (left, right) => '[$left|$right]',
      );
      expect(shape, '[(F1>Da)|(F2>[Db|F3])]');
    });

    test('prettyPrint is an indented tree', () {
      expect(
        Then<int>(fail(1), Both<int>(die('b'), empty)).prettyPrint(),
        'Then\n'
        '  Fail: 1\n'
        '  Both\n'
        '    Die: b\n'
        '    Empty',
      );
      expect(cause.toString(), cause.prettyPrint());
    });
  });

  group('equality', () {
    test('a stack trace does not change equality', () {
      final other = StackTrace.fromString('other');
      expect(Fail<int>(1, trace), Fail<int>(1, other));
      expect(Fail<int>(1, trace).hashCode, Fail<int>(1, other).hashCode);
      expect(Die<int>('d', trace), Die<int>('d', other));
      expect(
        Then<int>(fail(1), die('d')),
        Then<int>(Fail<int>(1, other), Die<int>('d', other)),
      );
      expect(
        Both<int>(fail(1), die('d')).hashCode,
        Both<int>(Fail<int>(1, other), Die<int>('d', other)).hashCode,
      );
      expect(const Empty<int>(), const Empty<String>());
    });

    test('different cases and values differ', () {
      expect(fail(1), isNot(fail(2)));
      expect(fail(1), isNot(die(1)));
      expect(fail(1) + fail(2), isNot(fail(1) & fail(2)));
      expect(fail(1) + fail(2), isNot(fail(2) + fail(1)));
      expect(const Empty<int>(), isNot(fail(1)));
    });
  });

  group('Monoid', () {
    final thenMonoid = Cause.thenMonoid<int>();
    final bothMonoid = Cause.bothMonoid<int>();

    test('the empty element is Empty', () {
      expect(thenMonoid.empty, empty);
      expect(bothMonoid.empty, empty);
    });

    test('identity laws', () {
      for (final monoid in [thenMonoid, bothMonoid]) {
        for (final cause in samples) {
          expect(monoid.combine(monoid.empty, cause), cause);
          expect(monoid.combine(cause, monoid.empty), cause);
        }
      }
    });

    test('associativity holds for failures and defects', () {
      for (final monoid in [thenMonoid, bothMonoid]) {
        for (final x in samples) {
          for (final y in samples) {
            for (final z in samples) {
              final left = monoid.combine(monoid.combine(x, y), z);
              final right = monoid.combine(x, monoid.combine(y, z));
              expect(left.failures, right.failures);
              expect(left.defects, right.defects);
            }
          }
        }
      }
    });

    test('combine uses + or &', () {
      expect(thenMonoid.combine(fail(1), fail(2)), isA<Then<int>>());
      expect(bothMonoid.combine(fail(1), fail(2)), isA<Both<int>>());
      expect(
        [fail(1), fail(2), fail(3)].fold(bothMonoid.empty, bothMonoid.combine),
        Both<int>(Both<int>(fail(1), fail(2)), fail(3)),
      );
    });
  });

  group('Eq', () {
    final eq = Cause.eq<int>();

    test('reflexive, symmetric, and transitive', () {
      final other = StackTrace.fromString('other');
      final again = <Cause<int>>[
        empty,
        Fail<int>(1, other),
        Die<int>('d', other),
        Then<int>(Fail<int>(1, other), Die<int>('d', other)),
        Both<int>(
          Fail<int>(1, other),
          Then<int>(Fail<int>(2, other), Die<int>('e', other)),
        ),
      ];
      for (var i = 0; i < samples.length; i++) {
        expect(eq.eqv(samples[i], samples[i]), isTrue);
        expect(eq.eqv(samples[i], again[i]), isTrue);
        expect(eq.eqv(again[i], samples[i]), isTrue);
        for (var j = 0; j < samples.length; j++) {
          expect(
            eq.eqv(samples[i], samples[j]),
            eq.eqv(samples[j], samples[i]),
          );
          if (i != j) expect(eq.eqv(samples[i], samples[j]), isFalse);
        }
      }
    });

    test('Then and Both differ, and so do the orders', () {
      expect(eq.eqv(fail(1) + fail(2), fail(1) & fail(2)), isFalse);
      expect(eq.eqv(fail(1) + fail(2), fail(2) + fail(1)), isFalse);
      expect(eq.neqv(fail(1), fail(2)), isTrue);
    });
  });

  group('Foldable', () {
    final cause = Both<int>(
      Then<int>(fail(1), die('a')),
      Then<int>(fail(2), Both<int>(die('b'), fail(3))),
    );

    test('a cause is a Foldable', () {
      expect(cause, isA<Foldable<Object?, int>>());
    });

    test('foldLeft visits the failures from left to right', () {
      for (final sample in [...samples, cause]) {
        expect(
          sample.foldLeft<List<int>>([], (all, error) => [...all, error]),
          sample.failures,
        );
      }
    });

    test('foldRight visits the failures from right to left', () {
      for (final sample in [...samples, cause]) {
        expect(
          sample.foldRight<List<int>>([], (all, error) => [...all, error]),
          sample.failures.reversed.toList(),
        );
      }
    });

    test('the derived operations agree with failures', () {
      expect(cause.length(), cause.failures.length);
      expect(cause.any((e) => e == 3), isTrue);
      expect(cause.all((e) => e < 3), isFalse);
      expect(
        cause.foldMap<List<int>>(
          Monoid.instance([], (a, b) => [...a, ...b]),
          (e) => [e],
        ),
        cause.failures,
      );
      expect(
        cause.foldLeftWithIndex<List<String>>(
          [],
          (i, all, e) => [...all, '$i:$e'],
        ),
        ['0:1', '1:2', '2:3'],
      );
      expect(empty.length(), 0);
    });

    test('plus, prepend, and append add typed failures', () {
      expect(fail(1).plus(fail(2)).failures, [1, 2]);
      expect(fail(2).prepend(1).failures, [1, 2]);
      expect(fail(1).append(2).failures, [1, 2]);
      expect(die('d').append(1).defects, ['d']);
    });
  });
}
