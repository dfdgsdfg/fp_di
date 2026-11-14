import 'package:fp_di/fp_di.dart';
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
        var chain = Dependency.require<int>(key: const DiKey(name: 'shared'));
        for (var i = 1; i < depth; i++) {
          chain = chain.map((v) => v + i);
        }
        final component = Component.effect(dependency: chain);
        final watch = Stopwatch()..start();
        final requires = component.requires;
        final optional = component.optional;
        final key = component.key;
        final reads = component.reads;
        final name = component.debugLabel;
        watch.stop();

        expect(requires, {const DiKey<int>(name: 'shared')});
        expect(optional, isEmpty);
        expect(key, isNull);
        expect(reads, {const DiKey<int>(name: 'shared')});
        expect(name, isNull);
        expect(watch.elapsed, lessThan(bound));
      },
    );

    test(
      'a 5000-deep map-with-dispose chain computes every shape within a bound',
      () {
        var chain = Dependency.maybe<int>(key: const DiKey(name: 'w'));
        for (var i = 1; i < depth; i++) {
          chain = chain.map<int?>((v) => v, dispose: (_) {});
        }
        final component = Component.effect(dependency: chain);
        final watch = Stopwatch()..start();
        final requires = component.requires;
        final optional = component.optional;
        final key = component.key;
        final reads = component.reads;
        watch.stop();

        expect(requires, isEmpty);
        expect(optional, {const DiKey<int>(name: 'w')});
        expect(key, isNull);
        expect(reads, {const DiKey<int>(name: 'w')});
        expect(watch.elapsed, lessThan(bound));
      },
    );

    test('a left-nested zip of 2000 distinct requires stays bounded', () {
      const width = 2000;
      final watch = Stopwatch()..start();
      Dependency<Object?> zip = Dependency.require<int>(
        key: const DiKey(name: 'r0'),
      );
      for (var i = 1; i < width; i++) {
        zip = (zip, Dependency.require<int>(key: DiKey<int>(name: 'r$i'))).zip;
      }
      final component = Component.effect(dependency: zip);
      final requires = component.requires;
      final optional = component.optional;
      final key = component.key;
      final reads = component.reads;
      watch.stop();

      expect(requires.length, width);
      expect(optional, isEmpty);
      expect(key, isNull);
      expect(reads.length, width);
      expect(watch.elapsed, lessThan(bound));
    });

    test('shape getters return stable results across calls', () {
      final tree = Component(
        dependency: (
          Dependency.require<int>(key: const DiKey(name: 'a')),
          Dependency.maybe<double>(key: const DiKey(name: 'w')),
        ).zip.map((v) => v.$1),
        key: const DiKey<int>(name: 'out'),
      );

      expect(identical(tree.requires, tree.requires), isTrue);
      expect(identical(tree.optional, tree.optional), isTrue);
      expect(identical(tree.reads, tree.reads), isTrue);
      expect(tree.requires, tree.requires);
      expect(
        () => tree.requires.add(const DiKey<int>(name: 'z')),
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
      final needsA = Dependency.require<int>(key: a);
      final needsS = Dependency.require<String>(key: s);
      final watchesW = Dependency.maybe<double>(key: w);

      // zip is a union: I = {a} ∪ {s} ∪ {} = {a, s}; W = {} ∪ {} ∪ {w} = {w}.
      // Nothing is subtracted, and published adds P = {out}.
      final tree = Component(
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
      final selfKey = Component(dependency: needsS, key: s);
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
      final source = Dependency.require<int>(key: a);
      expect(Component.effect(dependency: source.map((v) => v)).requires, {a});
      expect(
        Component.effect(
          dependency: source.map<int>((v) => v, dispose: (_) {}),
        ).requires,
        {a},
      );
      expect(
        Component.effect(dependency: source.map<int>((v) => v).lazy()).requires,
        {a},
      );

      final base = Component.effect(dependency: source);
      final published = Component(
        dependency: source,
        key: const DiKey<int>(name: 'out'),
      );
      expect(published.requires, {a});
      expect(published.key, const DiKey<int>(name: 'out'));
      expect(base.key, isNull);

      final named = Component.effect(dependency: source, debugLabel: 'label');
      expect(named.requires, {a});
      expect(named.key, isNull);
      expect(named.debugLabel, 'label');
    });
  });
}
