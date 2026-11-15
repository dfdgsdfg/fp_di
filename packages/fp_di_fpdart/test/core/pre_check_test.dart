import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fp_di_fpdart/src/core/core.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('preCheck', () {
    test('passes components that declare what they read', () {
      final (s, top) = root([
        comp('A', key: a),
        comp('B', key: b, requires: [a]),
      ]);
      expect(preCheck(s, top).isEmpty, isTrue);
    });

    test('rejects a required key that nothing declares', () {
      // from: core_test.dart: rejects a required key that nothing declares
      final (s, top) = root([
        comp('B', key: b, requires: [a]),
      ]);
      final problems = failuresOf(preCheck(s, top));
      expect(problems, hasLength(1));
      final problem = problems.single as UndeclaredKeyFailure;
      expect(problem.key, a);
      expect(problem.owner, 'B');
    });

    test('accepts a key that an uninitialized ancestor declares', () {
      // from: core_test.dart: accepts a key that an uninitialized ancestor
      // declares
      final (s, top) = root([comp('A', key: a)]);
      final (s1, low) = child(s, top, [
        comp('B', key: b, requires: [a]),
      ]);
      expect(scopePhase(s1, top), ScopePhase.declared);
      expect(preCheck(s1, low).isEmpty, isTrue);
    });

    test('counts the declared keys of every ancestor', () {
      final (s, top) = root([comp('A', key: a)]);
      final (s1, mid) = child(s, top, [comp('B', key: b)]);
      final (s2, low) = child(s1, mid, [
        comp('C', key: c, requires: [a, b]),
      ]);
      expect(preCheck(s2, low).isEmpty, isTrue);
    });

    test('does not count the keys of a child scope', () {
      final (s, top) = root([
        comp('R', key: d, requires: [a, b]),
      ]);
      final (s1, _) = child(s, top, [comp('A', key: a)]);
      final (s2, _) = child(s1, top, [comp('B', key: b)]);
      final keys = [for (final f in failuresOf(preCheck(s2, top))) f];
      expect(keys.map((f) => (f as UndeclaredKeyFailure).key), [a, b]);
    });

    test('does not check optional reads', () {
      // from: core_test.dart: does not check optional reads
      final (s, top) = root([
        comp('B', key: b, optional: [a]),
      ]);
      expect(preCheck(s, top).isEmpty, isTrue);
    });

    test('counts a key only when another member publishes it', () {
      // from: core_test.dart: counts a key only when another member
      // publishes it
      final (s, top) = root([
        comp('Self', key: a, requires: [a]),
      ]);
      final problems = failuresOf(preCheck(s, top));
      expect(problems.single, isA<UndeclaredKeyFailure>());
      final (s1, top1) = root([
        comp('Self', key: a, requires: [b]),
        comp('Other', key: b),
      ]);
      expect(preCheck(s1, top1).isEmpty, isTrue);
    });

    test('an effect declares no key, and its reads count', () {
      final (s, top) = root([
        effect('E', requires: [a]),
        comp('B', key: b, requires: [a]),
      ]);
      final problems = failuresOf(preCheck(s, top));
      expect(problems.map((f) => (f as UndeclaredKeyFailure).owner), [
        'E',
        'B',
      ]);
      final (s1, top1) = root([
        effect('E'),
        comp('B', key: b, requires: [a]),
      ]);
      expect(failuresOf(preCheck(s1, top1)), hasLength(1));
      final (s2, top2) = root([
        comp('A', key: a),
        effect('E', requires: [a]),
      ]);
      expect(preCheck(s2, top2).isEmpty, isTrue);
    });

    test('an effect of an ancestor does not satisfy a read', () {
      final (s, top) = root([effect('E')]);
      final (s1, low) = child(s, top, [
        comp('B', key: b, requires: [a]),
      ]);
      expect(failuresOf(preCheck(s1, low)), hasLength(1));
    });

    test('reports a duplicate key with the labels of its publishers', () {
      // from: core_test.dart: duplicate publishers are rejected atomically
      final (s, top) = root([
        comp('One', key: a),
        comp('Two', key: b),
        comp('Three', key: a),
      ]);
      final problem =
          failuresOf(preCheck(s, top)).single as DuplicateKeyFailure;
      expect(problem.key, a);
      expect(problem.labels, ['One', 'Three']);
    });

    test('the same key in two scopes is no duplicate', () {
      final (s, top) = root([comp('Far', key: a)]);
      final (s1, low) = child(s, top, [comp('Near', key: a)]);
      expect(preCheck(s1, low).isEmpty, isTrue);
    });

    test('two effects of one type are no duplicate', () {
      final (s, top) = root([effect('E1'), effect('E2')]);
      expect(preCheck(s, top).isEmpty, isTrue);
    });

    test('accumulates every problem, duplicates first, joined with &', () {
      final (s, top) = root([
        comp('One', key: a),
        comp('Two', key: a),
        comp('Three', key: b),
        comp('Four', key: b),
        comp('Needy', key: c, requires: [d]),
        effect('Blind', requires: [d]),
      ]);
      final cause = preCheck(s, top);
      final problems = failuresOf(cause);
      expect(problems, hasLength(4));
      expect(problems[0], isA<DuplicateKeyFailure>());
      expect((problems[0] as DuplicateKeyFailure).key, a);
      expect((problems[1] as DuplicateKeyFailure).key, b);
      expect((problems[2] as UndeclaredKeyFailure).owner, 'Needy');
      expect((problems[3] as UndeclaredKeyFailure).owner, 'Blind');
      expect(cause, isA<Both<DiFailure>>());
      expect(cause.defects, isEmpty);
    });

    test('one problem is a single failure, not a pair', () {
      final (s, top) = root([
        comp('Needy', key: c, requires: [d]),
      ]);
      expect(preCheck(s, top), isA<Fail<DiFailure>>());
    });

    test('names a key once for each member that requires it', () {
      final (s, top) = root([
        comp('X', key: b, requires: [a]),
        comp('Y', key: c, requires: [a]),
      ]);
      expect(failuresOf(preCheck(s, top)), hasLength(2));
    });

    test('a scope without components passes', () {
      final (s, top) = root(const []);
      expect(preCheck(s, top).isEmpty, isTrue);
    });

    test('changes no state', () {
      final (s, top) = root([
        comp('Needy', key: c, requires: [d]),
      ]);
      final before = s.revision;
      preCheck(s, top);
      expect(s.revision, before);
      expect(s.nodes, isEmpty);
    });
  });
}
