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

  test('overriddenBy replaces in place and appends new keys', () async {
    final log = <String>[];
    final base = [
      logged<int>('base int', 1, log, key: intKey),
      logged<String>('base text', 'a', log, key: textKey),
    ];
    final overrides = [
      logged<bool>('new flag', true, log, key: flagKey),
      logged<int>('override int', 2, log, key: intKey),
    ];
    final components = base.overriddenBy(overrides);
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

  test('overriddenBy keeps the base list unchanged', () {
    final base = [number(1, key: intKey)];
    base.overriddenBy([number(2, key: intKey)]);
    expect(base.publishes, {intKey});
    expect(base.single.label, 'n1');
  });

  test('overriddenBy works for any iterable', () {
    final result = {
      number(1, key: intKey),
    }.overriddenBy(Iterable.generate(1, (_) => number(2, key: intKey)));
    expect(result.single.label, 'n2');
  });

  test('a duplicate in the overrides still fails the run', () async {
    final components = [
      number(1, key: intKey),
    ].overriddenBy([number(2, key: intKey), number(3, key: intKey)]);
    expect(components, hasLength(2));
    expect(
      await failureOfRun(Scope(components: components)),
      isA<DuplicateKeyFailure>(),
    );
  });
}
