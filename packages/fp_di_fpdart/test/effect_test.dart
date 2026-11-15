import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  Component<Object?> effect(
    String name,
    List<String> log, {
    Dependency<Object?>? reads,
    Object? failDispose,
  }) => Component<Object?>.effect(
    debugLabel: name,
    dependency: (reads ?? Dependency<Object?>.of(null)).map<Object?>(
      (_) {
        log.add('create $name');
        return name;
      },
      dispose: (_) {
        log.add('dispose $name');
        if (failDispose != null) throw failDispose;
      },
    ),
  );

  test('an effect publishes no key and is invisible to get', () async {
    final log = <String>[];
    final components = [
      logged<int>('a', 1, log, key: intKey),
      effect('hook', log),
    ];
    expect(components.publishes, {intKey});
    final scope = Scope(components: components);
    rightOf(await scope.run());
    expect(log, containsAll(['create a', 'create hook']));
    final hook = components.last;
    expect(hook.isEffect, isTrue);
    expect(components.first.isEffect, isFalse);
    expect(scope.get<Object?>(key: hook.key), isA<Left<DiFailure, Object?>>());
    expect(scope.get<Object?>(), isA<Left<DiFailure, Object?>>());
    expect(hook.key.toString(), 'effect(hook)');
    expect(
      Component<int>.effect(dependency: Dependency<int>.of(1)).label,
      'effect<int>',
    );
  });

  test('requires counts the reads of an effect', () {
    final components = [
      effect('hook', <String>[], reads: Dependency.require<int>(key: intKey)),
    ];
    expect(components.publishes, isEmpty);
    expect(components.requires, {intKey});
  });

  test('an effect runs after its reads and releases before them', () async {
    final log = <String>[];
    final scope = Scope(
      components: [
        // Declared first, but it reads a later component.
        effect('hook', log, reads: Dependency.require<int>(key: intKey)),
        logged<int>('a', 1, log, key: intKey),
      ],
    );
    rightOf(await scope.run());
    expect(log, ['create a', 'create hook']);
    rightOf(await scope.dispose());
    expect(log, ['create a', 'create hook', 'dispose hook', 'dispose a']);
  });

  test('an effect and a component that read one key start together', () async {
    final log = <String>[];
    final scope = Scope(
      components: [
        effect('hook', log, reads: Dependency.require<int>(key: intKey)),
        logged<int>('a', 1, log, key: intKey),
        loggedReading<String>(
          'b',
          Dependency.require<int>(key: intKey),
          'b',
          log,
          key: textKey,
        ),
      ],
    );
    rightOf(await scope.run());
    // The effect and b read the same key, so they start together.
    expect(log.first, 'create a');
    expect(log.skip(1), unorderedEquals(['create hook', 'create b']));
  });

  test('two effects of one type coexist', () async {
    final log = <String>[];
    final scope = Scope(components: [effect('one', log), effect('two', log)]);
    rightOf(await scope.run());
    expect(log, unorderedEquals(['create one', 'create two']));
    rightOf(await scope.dispose());
    expect(log.where((l) => l.startsWith('dispose')), hasLength(2));
  });

  test('an effect fails like any component', () async {
    final log = <String>[];
    final failing = Component<int>.effect(
      debugLabel: 'broken',
      dependency: Dependency.require<int>(key: intKey)
          .map<int>((v) => v, dispose: (_) => log.add('dispose broken step'))
          .map<int>((_) => throw StateError('x')),
    );
    final cause = await causeOfRun(
      Scope(
        components: [
          logged<int>('a', 1, log, key: intKey),
          loggedReading<String>(
            'b',
            Dependency.require<int>(key: intKey),
            'b',
            log,
            key: textKey,
            failDispose: 'b rollback',
          ),
          failing,
        ],
      ),
    );
    expect((cause.failures.single as ActivationFailure).owner, 'broken');
    expect(log, contains('dispose broken step'));
    expect(log, contains('dispose b'));
    expect(log, contains('dispose a'));
    expect(cause.defects, [const DisposeFailure('b', 'b rollback')]);
  });

  test('an undeclared read of an effect names the effect', () async {
    final failure = await failureOfRun(
      Scope(
        components: [
          effect('hook', <String>[], reads: Dependency.require<int>()),
        ],
      ),
    );
    expect(
      failure,
      isA<UndeclaredKeyFailure>().having((f) => f.owner, 'owner', 'hook'),
    );
  });

  test('a failed dispose of an effect is a defect', () async {
    final scope = Scope(
      components: [effect('hook', <String>[], failDispose: 'bad')],
    );
    rightOf(await scope.run());
    final cause = leftOf(await scope.dispose());
    expect(cause.defects, [const DisposeFailure('hook', 'bad')]);
  });

  test('the duplicate check ignores effects', () async {
    final log = <String>[];
    final scope = Scope(
      components: [
        logged<int>('a', 1, log, key: intKey),
        effect('one', log),
        effect('two', log),
      ],
    );
    rightOf(await scope.run());
  });

  test(
    'a child sees the keys of the parent, and an effect of the child',
    () async {
      final log = <String>[];
      final parent = Scope(components: [logged<int>('a', 1, log, key: intKey)]);
      rightOf(await parent.run());
      final child = parent.kid(
        components: [
          effect('hook', log, reads: Dependency.require<int>(key: intKey)),
        ],
      );
      rightOf(await child.run());
      rightOf(await parent.dispose());
      expect(log, ['create a', 'create hook', 'dispose hook', 'dispose a']);
    },
  );
}
