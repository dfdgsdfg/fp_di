import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  Component<int> number(int value, {DiKey<int>? key}) =>
      Component<int>.value(value: value, key: key, debugLabel: 'n$value');

  test('publishes and requires list the keys', () {
    final components = [
      Component<int>.value(key: intKey, value: 1),
      Component<String>(
        key: textKey,
        dependency: Dependency.require<int>(
          key: intKey,
        ).map2(Dependency.require<bool>(key: flagKey), (a, b) => '$a $b'),
      ),
    ];
    expect(components.publishes, {intKey, textKey});
    expect(components.requires, {flagKey});
  });

  test('an optional read is not a required key', () {
    final components = [
      Component<String>(
        dependency: Dependency.option<int>(key: intKey).map<String>((_) => 'x'),
      ),
    ];
    expect(components.requires, isEmpty);
  });

  test('an empty list publishes and requires nothing', () {
    const components = <Component<Object?>>[];
    expect(components.publishes, isEmpty);
    expect(components.requires, isEmpty);
  });

  test('list concatenation keeps the order of the components', () {
    final one = [number(1, key: intKey)];
    final two = [Component<String>.value(key: textKey, value: 'x')];
    expect([...one, ...two].publishes.toList(), [intKey, textKey]);
    expect([...two, ...one].publishes.toList(), [textKey, intKey]);
  });

  test('a scope keeps an unmodifiable copy of the list', () {
    final list = <Component<Object?>>[number(1, key: intKey)];
    final scope = Scope(components: list);
    list.add(number(2, key: const DiKey<int>(name: 'other')));
    expect(scope.components, hasLength(1));
    expect(() => scope.components.add(number(3)), throwsUnsupportedError);
    expect(scope.child().components, isEmpty);
  });

  group('overriddenBy', () {
    test('replaces the component that publishes the key, in place', () async {
      final log = <String>[];
      final base = [
        logged<int>('base int', 1, log, key: intKey),
        logged<String>('base text', 'a', log, key: textKey),
        logged<bool>('base flag', false, log, key: flagKey),
      ];
      final overrides = [
        logged<bool>('new flag', true, log, key: flagKey),
        logged<int>('override int', 2, log, key: intKey),
      ];
      final components = rightOf(base.overriddenBy(overrides));
      expect(components.publishes.toList(), [intKey, textKey, flagKey]);
      expect(components.map((c) => c.label), [
        'override int',
        'base text',
        'new flag',
      ]);
      final scope = Scope(components: components);
      rightOf(await scope.run());
      expect(rightOf(scope.get<int>(key: intKey)), 2);
      expect(rightOf(scope.get<String>(key: textKey)), 'a');
      expect(rightOf(scope.get<bool>(key: flagKey)), isTrue);
      expect(log, isNot(contains('create base int')));
      expect(log, containsAll(['create override int', 'create new flag']));
    });

    test('keeps the base list unchanged', () {
      final base = [number(1, key: intKey)];
      rightOf(base.overriddenBy([number(2, key: intKey)]));
      expect(base.publishes, {intKey});
      expect(base.single.label, 'n1');
    });

    test('works for any iterable', () {
      final result = rightOf(
        {
          number(1, key: intKey),
        }.overriddenBy(Iterable.generate(1, (_) => number(2, key: intKey))),
      );
      expect(result.single.label, 'n2');
    });

    test('an empty override list gives an equal list', () {
      final base = [number(1, key: intKey)];
      expect(rightOf(base.overriddenBy(const [])), base);
    });

    test('a key that no component publishes is unmatched', () {
      final cause = leftOf(
        [number(1, key: intKey)].overriddenBy([
          Component<String>.value(key: textKey, value: 'x', debugLabel: 'text'),
        ]),
      );
      expect(
        cause.only,
        isA<UnmatchedOverrideFailure>()
            .having((f) => f.key, 'key', textKey)
            .having((f) => f.owner, 'owner', 'text'),
      );
      expect(cause, isA<Fail<DiFailure>>());
    });

    test('every problem is reported, in the order of the overrides', () {
      final base = [
        number(1, key: intKey),
        number(2, key: intKey),
        number(3, key: const DiKey<int>(name: 'flag')),
      ];
      final cause = leftOf(
        base.overriddenBy([
          Component<String>.value(key: textKey, value: 'a', debugLabel: 'a'),
          number(4, key: intKey),
          Component<String>.value(key: textKey, value: 'b', debugLabel: 'b'),
        ]),
      );
      expect(cause.failures.map((f) => f.runtimeType), [
        UnmatchedOverrideFailure,
        DuplicateKeyFailure,
        DuplicateKeyFailure,
        UnmatchedOverrideFailure,
      ]);
      expect(cause, isA<Both<DiFailure>>());
      final baseDuplicate = cause.failures[2] as DuplicateKeyFailure;
      expect(baseDuplicate.key, intKey);
      expect(baseDuplicate.labels, ['n1', 'n2']);
      final overrideDuplicate = cause.failures[1] as DuplicateKeyFailure;
      expect(overrideDuplicate.key, textKey);
      expect(overrideDuplicate.labels, ['a', 'b']);
    });

    test('two overrides with the same key are a duplicate', () {
      final cause = leftOf(
        [
          number(1, key: intKey),
        ].overriddenBy([number(2, key: intKey), number(3, key: intKey)]),
      );
      expect(
        cause.only,
        isA<DuplicateKeyFailure>().having((f) => f.labels, 'labels', [
          'n2',
          'n3',
        ]),
      );
    });

    test('an effect cannot be an override', () {
      final effect = Component<int>.effect(
        debugLabel: 'effect',
        dependency: Dependency<int>.of(1),
      );
      final cause = leftOf([number(1, key: intKey)].overriddenBy([effect]));
      expect(
        cause.only,
        isA<UnmatchedOverrideFailure>().having(
          (f) => f.owner,
          'owner',
          'effect',
        ),
      );
    });

    test('an effect of the base stays where it is', () {
      final effect = Component<int>.effect(dependency: Dependency<int>.of(1));
      final result = rightOf(
        [effect, number(1, key: intKey)].overriddenBy([number(2, key: intKey)]),
      );
      expect(result.first, same(effect));
      expect(result.last.label, 'n2');
    });
  });
}
