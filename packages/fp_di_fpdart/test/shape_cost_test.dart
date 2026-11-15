// The cost of the derived shape of a dependency and of a component. This file
// tests the shape of a `Dependency` and of a `Component`. The `ShapeGraph`
// tooling of fp_di has its own tests.
import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

void main() {
  group('shape cost', () {
    // Bounds are generous: they separate linear-ish from cubic or exponential
    // growth, not one machine from another.
    const depth = 5000;
    const bound = Duration(seconds: 1);

    test(
      'a 5000-deep Dependency.map chain computes every shape within a bound',
      () {
        // from: shape_cost_test.dart: a 5000-deep Dependency.map chain
        // computes every shape within a bound
        var chain = Dependency.require<int>(key: const DiKey(name: 'shared'));
        for (var i = 1; i < depth; i++) {
          chain = chain.map((v) => v + i);
        }
        final component = Component<int>.effect(dependency: chain);
        final watch = Stopwatch()..start();
        final requires = component.requires;
        final optional = component.optional;
        final hasKey = component.hasKey;
        final reads = component.reads;
        final name = component.debugLabel;
        watch.stop();

        expect(requires, {const DiKey<int>(name: 'shared')});
        expect(optional, isEmpty);
        expect(hasKey, isFalse);
        expect(reads, {const DiKey<int>(name: 'shared')});
        expect(name, isNull);
        expect(watch.elapsed, lessThan(bound));
      },
    );

    test(
      'a 5000-deep map-with-dispose chain computes every shape within a bound',
      () {
        // from: shape_cost_test.dart: a 5000-deep map-with-dispose chain
        // computes every shape within a bound
        var chain = Dependency.option<int>(key: const DiKey(name: 'w'));
        for (var i = 1; i < depth; i++) {
          chain = chain.map<Option<int>>((v) => v, dispose: (_) {});
        }
        final component = Component<Option<int>>.effect(dependency: chain);
        final watch = Stopwatch()..start();
        final requires = component.requires;
        final optional = component.optional;
        final hasKey = component.hasKey;
        final reads = component.reads;
        watch.stop();

        expect(requires, isEmpty);
        expect(optional, {const DiKey<int>(name: 'w')});
        expect(hasKey, isFalse);
        expect(reads, {const DiKey<int>(name: 'w')});
        expect(watch.elapsed, lessThan(bound));
      },
    );

    test('a left-nested zip of 2000 distinct requires stays bounded', () {
      // from: shape_cost_test.dart: a left-nested zip of 2000 distinct
      // requires stays bounded
      const width = 2000;
      final watch = Stopwatch()..start();
      Dependency<Object?> zip = Dependency.require<int>(
        key: const DiKey(name: 'r0'),
      );
      for (var i = 1; i < width; i++) {
        zip = (zip, Dependency.require<int>(key: DiKey<int>(name: 'r$i'))).zip;
      }
      final component = Component<Object?>.effect(dependency: zip);
      final requires = component.requires;
      final optional = component.optional;
      final hasKey = component.hasKey;
      final reads = component.reads;
      watch.stop();

      expect(requires.length, width);
      expect(optional, isEmpty);
      expect(hasKey, isFalse);
      expect(reads.length, width);
      expect(watch.elapsed, lessThan(bound));
    });

    test('shape getters return stable results across calls', () {
      // from: shape_cost_test.dart: shape getters return stable results across
      // calls
      final tree = Component<int>(
        dependency: (
          Dependency.require<int>(key: const DiKey(name: 'a')),
          Dependency.option<double>(key: const DiKey(name: 'w')),
        ).zip.map((v) => v.$1),
        key: const DiKey<int>(name: 'out'),
      );

      expect(identical(tree.requires, tree.requires), isTrue);
      expect(identical(tree.optional, tree.optional), isTrue);
      expect(tree.requires, tree.requires);
      expect(
        () => tree.requires.add(const DiKey<int>(name: 'z')),
        throwsUnsupportedError,
      );
      expect(
        () => tree.reads.add(const DiKey<int>(name: 'z')),
        throwsUnsupportedError,
      );
    });
  });

  group('shape of a small tree', () {
    const a = DiKey<int>(name: 'a');
    const s = DiKey<String>(name: 's');
    const w = DiKey<double>(name: 'w');
    const out = DiKey<String>(name: 'out');

    test('matches the hand-computed algebra', () {
      // from: shape_cost_test.dart: matches the hand-computed algebra
      final needsA = Dependency.require<int>(key: a);
      final needsS = Dependency.require<String>(key: s);
      final watchesW = Dependency.option<double>(key: w);

      // zip is a union: I = {a} ∪ {s} ∪ {} = {a, s}; W = {} ∪ {} ∪ {w} = {w}.
      // Nothing is subtracted, and published adds P = {out}.
      final tree = Component<String>(
        dependency: ((needsA, needsS).zip, watchesW).zip.map((v) => v.$1.$2),
        debugLabel: 'tree',
        key: out,
      );
      expect(tree.requires, {a, s});
      expect(tree.optional, {w});
      expect(tree.key, out);
      expect(tree.reads, {a, s, w});
      expect(tree.debugLabel, 'tree');

      // A component that publishes a key it also requires keeps the
      // requirement: there is no subtraction rule.
      final selfKey = Component<String>(dependency: needsS, key: s);
      expect(selfKey.requires, {s});
      expect(selfKey.key, s);

      // A published value has no requirement.
      final publishesS = Component<String>.value(value: 'x', key: s);
      expect(publishesS.requires, isEmpty);
      expect(publishesS.optional, isEmpty);
      expect(publishesS.key, s);
      expect(publishesS.reads, isEmpty);
    });

    test('wrappers preserve or extend the source shape', () {
      // from: shape_cost_test.dart: wrappers preserve or extend the source
      // shape
      final source = Dependency.require<int>(key: a);
      expect(Component<int>.effect(dependency: source.map((v) => v)).requires, {
        a,
      });
      expect(
        Component<int>.effect(
          dependency: source.map<int>((v) => v, dispose: (_) {}),
        ).requires,
        {a},
      );
      expect(
        Component<Lazy<int>>.effect(
          dependency: source.map<int>((v) => v).lazy(),
        ).requires,
        {a},
      );

      final base = Component<int>.effect(dependency: source);
      final published = Component<int>(
        dependency: source,
        key: const DiKey<int>(name: 'out'),
      );
      expect(published.requires, {a});
      expect(published.key, const DiKey<int>(name: 'out'));
      expect(base.hasKey, isFalse);

      final named = Component<int>.effect(
        dependency: source,
        debugLabel: 'label',
      );
      expect(named.requires, {a});
      expect(named.hasKey, isFalse);
      expect(named.debugLabel, 'label');
    });
  });
}
