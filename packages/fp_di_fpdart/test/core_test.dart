// The lifecycle of components: the guards of `run`, the lookups, the listener
// failure, the ownership of the steps, and the cleanup. The tests mirror the
// scenarios of the core tests of `fp_di`.
import 'dart:async';
import 'dart:math';

import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

const _count = DiKey<int>(name: 'count');

void main() {
  group('scope lifecycle', () {
    test('a second run on a scope that ran is a ScopePhaseFailure', () async {
      // from: core_test.dart: a second initialize on an initialized scope
      // throws StateError
      final di = Scope(
        components: [Component<int>.value(value: 1, key: _count)],
      );
      rightOf(await di.run());
      expect(di.isInitialized, isTrue);
      final failure = leftOf(await di.run()).only;
      expect(
        failure,
        isA<ScopePhaseFailure>()
            .having((f) => f.operation, 'operation', 'run')
            .having((f) => f.phase, 'phase', ScopePhase.initialized),
      );
      expect(di.isInitialized, isTrue);
      expect(rightOf(di.get<int>(key: _count)), 1);
      rightOf(await di.dispose());
    });

    test('run after dispose is a DisposedScopeFailure', () async {
      // from: core_test.dart: initialize after dispose throws
      // DisposedScopeError
      final di = Scope(
        components: [Component<int>.value(value: 1, key: _count)],
      );
      rightOf(await di.dispose());
      expect(leftOf(await di.run()).only, isA<DisposedScopeFailure>());
    });

    test('publish, get, getOption, and a missing dependency', () async {
      // from: core_test.dart: publish, get, maybeGet, and missing dependency
      final di = Scope(
        components: [
          Component<int>.value(value: 42, debugLabel: 'answer', key: _count),
        ],
      );
      expect(di.getOption<int>(key: _count), isA<None>());
      expect(leftOf(di.get<int>(key: _count)), isA<UnavailableKeyFailure>());

      rightOf(await di.run());
      expect(rightOf(di.get<int>(key: _count)), 42);
      expect(rightOf(di.nodes.single.value), 42);
      rightOf(await di.dispose());
    });

    test(
      'a failing listener is reported without interrupting the lifecycle',
      () async {
        // from: core_test.dart: a failing listener is reported without
        // interrupting lifecycle
        final di = Scope(
          components: [Component<int>.value(value: 1, key: _count)],
        );
        final reported = di.errors.first;
        rightOf(di.addListener(() => throw StateError('listener failed')));
        rightOf(await di.run());
        expect(rightOf(di.get<int>(key: _count)), 1);
        final cause = await reported;
        expect(cause.failures.single, isA<ListenerFailure>());
        rightOf(await di.nodes.single.dispose());
        rightOf(await di.dispose());
      },
    );
  });

  group('component lifecycle', () {
    test('cleanup is LIFO and handle disposal is idempotent', () async {
      // from: core_test.dart: cleanup is LIFO and handle disposal is
      // idempotent
      final events = <String>[];
      int acquire(int value) {
        events.add('acquire$value');
        return value;
      }

      void release(int value) => events.add('release$value');
      var chain = Dependency<int>(
        create: () => acquire(0),
        dispose: (_) => release(0),
      );
      for (var i = 1; i < 4; i++) {
        final value = i;
        chain = chain.map(
          (_) => acquire(value),
          dispose: (_) => release(value),
        );
      }
      final di = Scope(
        components: [
          Component<String>.effect(dependency: chain.map((_) => 'ready')),
        ],
      );
      rightOf(await di.run());
      final handle = di.nodes.single;
      rightOf(await handle.dispose());
      rightOf(await handle.dispose());
      expect(events, [
        'acquire0',
        'acquire1',
        'acquire2',
        'acquire3',
        'release3',
        'release2',
        'release1',
        'release0',
      ]);
      expect(handle.isActive, isFalse);
      expect(leftOf(handle.value), isA<InactiveNodeFailure>());
      rightOf(await di.dispose());
    });

    test('a run reports rollback cleanup failures with the cause', () async {
      // from: core_test.dart: activation reports rollback cleanup failures with
      // the cause
      final di = Scope(
        components: [
          Component<void>.effect(
            dependency: Dependency<int>(
              create: () => 1,
              dispose: (_) => throw StateError('rollback failed'),
            ).map<void>((_) => throw StateError('activation failed')),
          ),
        ],
      );
      final cause = leftOf(await di.run());
      expect(cause.failures.single, isA<ActivationFailure>());
      expect(
        (cause.failures.single as ActivationFailure).error,
        isA<StateError>(),
      );
      expect(cause.defects, hasLength(1));
      rightOf(await di.dispose());
    });

    test('cleanup failures are aggregated without short-circuiting', () async {
      // from: core_test.dart: cleanup failures are aggregated without
      // short-circuiting
      final events = <String>[];
      final di = Scope(
        components: [
          Component<int>.effect(
            dependency:
                Dependency<int>(
                  create: () => 1,
                  dispose: (_) {
                    events.add('first');
                    throw StateError('first');
                  },
                ).map<int>(
                  (_) => 2,
                  dispose: (_) {
                    events.add('second');
                    throw StateError('second');
                  },
                ),
          ),
        ],
      );
      rightOf(await di.run());
      final handle = di.nodes.single;

      final cause = leftOf(await handle.dispose());
      expect(cause.defects, hasLength(2));
      expect(events, ['second', 'first']);
      rightOf(await di.dispose());
    });

    test('independent components do not affect each other', () async {
      // from: core_test.dart: independent components do not affect each other
      final di = Scope(
        components: [
          Component<int>.value(value: 1, key: const DiKey<int>(name: 'left')),
          Component<int>.value(value: 2, key: const DiKey<int>(name: 'right')),
        ],
      );
      rightOf(await di.run());
      final [left, right] = di.nodes;
      rightOf(await left.dispose());
      expect(right.isActive, isTrue);
      expect(rightOf(di.get<int>(key: const DiKey<int>(name: 'right'))), 2);
      rightOf(await di.dispose());
    });
  });

  group('composition', () {
    test('Dependency.map acquires forward and releases backward', () async {
      // from: core_test.dart: Dependency.map acquires forward and releases
      // backward
      final events = <String>[];
      final chain =
          Dependency<int>(
            create: () {
              events.add('A+');
              return 2;
            },
            dispose: (_) => events.add('A-'),
          ).map<String>((value) {
            events.add('B+');
            return '$value!';
          }, dispose: (_) => events.add('B-'));
      final di = Scope(
        components: [Component<String>.effect(dependency: chain)],
      );
      rightOf(await di.run());
      final handle = di.nodes.single;
      expect(rightOf(handle.value), '2!');
      rightOf(await handle.dispose());
      expect(events, ['A+', 'B+', 'B-', 'A-']);
      rightOf(await di.dispose());
    });

    test(
      'Dependency.map rolls back the first step if the second fails',
      () async {
        // from: core_test.dart: Dependency.map rolls back the first step if the
        // second fails
        final events = <String>[];
        final chain =
            Dependency<int>(
              create: () {
                events.add('A+');
                return 1;
              },
              dispose: (_) => events.add('A-'),
            ).map<String>((_) {
              events.add('B!');
              throw StateError('B failed');
            }, dispose: (_) => events.add('B-'));
        final di = Scope(
          components: [Component<String>.effect(dependency: chain)],
        );
        expect(leftOf(await di.run()).failures.first, isA<ActivationFailure>());
        expect(events, ['A+', 'B!', 'A-']);
        rightOf(await di.dispose());
      },
    );

    test('Dependency map steps with and without dispose share ordered '
        'ownership', () async {
      // from: core_test.dart: Dependency map steps with and without dispose
      // share ordered ownership
      final events = <String>[];
      int step(int value) {
        events.add('$value+');
        return value;
      }

      void release(int value) => events.add('$value-');
      final composed = Component<int>.effect(
        dependency: Dependency.require<int>(key: const DiKey<int>(name: 'seed'))
            .map<int>(step, dispose: release)
            .map<int>((value) => value + 1)
            .map<int>(step, dispose: release)
            .map<int>((value) => step(value + 1), dispose: release),
      );
      final di = Scope(
        components: [
          Component<int>.value(value: 1, key: const DiKey<int>(name: 'seed')),
          composed,
        ],
      );
      rightOf(await di.run());
      final [seed, handle] = di.nodes;
      expect(rightOf(handle.value), 3);
      rightOf(await handle.dispose());
      expect(events, ['1+', '2+', '3+', '3-', '2-', '1-']);
      rightOf(await seed.dispose());
      rightOf(await di.dispose());
    });

    test('LIFO cleanup holds for generated effect sequences', () async {
      // from: core_test.dart: LIFO cleanup holds for generated effect
      // sequences
      final random = Random(7);
      for (var run = 0; run < 20; run++) {
        final size = random.nextInt(20) + 1;
        final releases = <int>[];
        var chain = Dependency<int>(
          create: () => 0,
          dispose: (_) => releases.add(0),
        );
        for (var i = 1; i < size; i++) {
          final value = i;
          chain = chain.map<int>(
            (_) => value,
            dispose: (_) => releases.add(value),
          );
        }
        final di = Scope(
          components: [
            Component<int>.effect(dependency: chain.map((_) => size)),
          ],
        );
        rightOf(await di.run());
        rightOf(await di.nodes.single.dispose());
        expect(releases, List<int>.generate(size, (i) => size - i - 1));
        rightOf(await di.dispose());
      }
    });

    test('stream subscriptions are owned effects', () async {
      // from: core_test.dart: stream subscriptions are owned effects
      final controller = StreamController<int>();
      final values = <int>[];
      final di = Scope(
        components: [
          Component<StreamSubscription<int>>.effect(
            dependency: Dependency<StreamSubscription<int>>(
              create: () => controller.stream.listen(values.add),
              dispose: (subscription) => subscription.cancel(),
            ),
          ),
        ],
      );
      rightOf(await di.run());
      final handle = di.nodes.single;
      controller.add(1);
      await Future<void>.delayed(Duration.zero);
      rightOf(await handle.dispose());
      controller.add(2);
      await Future<void>.delayed(Duration.zero);
      expect(values, [1]);
      await controller.close();
      rightOf(await di.dispose());
    });
  });
}
