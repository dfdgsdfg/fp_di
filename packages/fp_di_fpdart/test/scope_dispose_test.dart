import 'dart:async';

import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('child', () {
    test('a child reads a key of its parent', () async {
      final parent = Scope(
        components: [Component<int>.value(key: intKey, value: 10)],
      );
      rightOf(await parent.run());
      final child = parent.child(
        components: [
          Component<String>(
            key: textKey,
            dependency: Dependency.require<int>(
              key: intKey,
            ).map<String>((v) => 'child $v'),
          ),
        ],
      );
      expect(child.parent, Some(parent));
      rightOf(await child.run());
      expect(rightOf(child.get<String>(key: textKey)), 'child 10');
      expect(rightOf(child.get<int>(key: intKey)), 10);
      expect(child.getOption<int>(key: intKey), const Some(10));
      expect(
        leftOf(parent.get<String>(key: textKey)),
        isA<UnavailableKeyFailure>(),
      );
    });

    test('a child shadows the key of its parent', () async {
      final parent = Scope(
        components: [Component<int>.value(key: intKey, value: 1)],
      );
      rightOf(await parent.run());
      final child = parent.child(
        components: [
          Component<int>.value(key: intKey, value: 2),
          Component<String>(
            key: textKey,
            dependency: Dependency.require<int>(
              key: intKey,
            ).map<String>((v) => 'saw $v'),
          ),
        ],
      );
      rightOf(await child.run());
      expect(rightOf(child.get<int>(key: intKey)), 2);
      expect(rightOf(child.get<String>(key: textKey)), 'saw 2');
      expect(rightOf(parent.get<int>(key: intKey)), 1);
    });

    test('a child sees the key of a grandparent', () async {
      final root = Scope(
        components: [Component<int>.value(key: intKey, value: 1)],
      );
      rightOf(await root.run());
      final middle = root.child();
      rightOf(await middle.run());
      final leaf = middle.child(
        components: [
          Component<String>(
            key: textKey,
            dependency: Dependency.require<int>(
              key: intKey,
            ).map<String>((v) => 'leaf $v'),
          ),
        ],
      );
      rightOf(await leaf.run());
      expect(rightOf(leaf.get<String>(key: textKey)), 'leaf 1');
    });

    test('an optional read finds a key of the parent', () async {
      final parent = Scope(
        components: [Component<int>.value(key: intKey, value: 1)],
      );
      rightOf(await parent.run());
      final child = parent.child(
        components: [
          Component<String>(
            key: textKey,
            dependency: Dependency.option<int>(
              key: intKey,
            ).map<String>((o) => o.match(() => 'none', (v) => 'some $v')),
          ),
        ],
      );
      rightOf(await child.run());
      expect(rightOf(child.get<String>(key: textKey)), 'some 1');
    });

    test('a key that no ancestor publishes is undeclared', () async {
      final parent = Scope(components: []);
      rightOf(await parent.run());
      final child = parent.child(
        components: [
          Component<String>(
            key: textKey,
            debugLabel: 'text',
            dependency: Dependency.require<int>(
              key: intKey,
            ).map<String>((v) => '$v'),
          ),
        ],
      );
      expect(
        await failureOfRun(child),
        isA<UndeclaredKeyFailure>().having((f) => f.owner, 'owner', 'text'),
      );
    });

    test(
      'a child of a parent that is not active fails at its own run',
      () async {
        final parent = Scope(
          components: [Component<int>.value(key: intKey, value: 1)],
        );
        final child = parent.child(
          components: [
            Component<String>(
              dependency: Dependency.require<int>(
                key: intKey,
              ).map<String>((v) => '$v'),
            ),
          ],
        );
        expect(
          await failureOfRun(child),
          isA<InactiveAncestorFailure>().having(
            (f) => f.phase,
            'phase',
            ScopePhase.declared,
          ),
        );
        expect(child.phase, ScopePhase.failed);
        rightOf(await parent.run());
        rightOf(await parent.dispose());
        final late = parent.child();
        expect(
          await failureOfRun(late),
          isA<InactiveAncestorFailure>().having(
            (f) => f.phase,
            'phase',
            ScopePhase.disposed,
          ),
        );
      },
    );

    test(
      'a child cannot read the key of a parent after the parent disposes',
      () async {
        final parent = Scope(
          components: [Component<int>.value(key: intKey, value: 1)],
        );
        rightOf(await parent.run());
        final child = parent.child();
        rightOf(await child.run());
        rightOf(await parent.dispose());
        expect(child.phase, ScopePhase.disposed);
        expect(leftOf(child.get<int>(key: intKey)), isA<ScopePhaseFailure>());
      },
    );
  });

  group('dispose', () {
    test(
      'dependents dispose before their publishers, children first',
      () async {
        final log = <String>[];
        final parent = Scope(
          components: [
            logged<int>('a', 1, log, key: intKey),
            loggedReading<String>(
              'b',
              Dependency.require<int>(key: intKey),
              'b',
              log,
              key: textKey,
            ),
            loggedReading<bool>(
              'c',
              Dependency.require<String>(key: textKey),
              true,
              log,
              key: flagKey,
            ),
          ],
        );
        rightOf(await parent.run());
        final first = parent.child(
          components: [
            loggedReading<double>(
              'child 1',
              Dependency.require<int>(key: intKey),
              1.0,
              log,
            ),
          ],
        );
        final second = parent.child(
          components: [
            loggedReading<BigInt>(
              'child 2',
              Dependency.require<bool>(key: flagKey),
              BigInt.one,
              log,
            ),
          ],
        );
        rightOf(await first.run());
        rightOf(await second.run());
        log.clear();
        rightOf(await parent.dispose());
        expect(log, [
          'dispose child 2',
          'dispose child 1',
          'dispose c',
          'dispose b',
          'dispose a',
        ]);
        expect(parent.phase, ScopePhase.disposed);
        expect(first.phase, ScopePhase.disposed);
        expect(second.phase, ScopePhase.disposed);
      },
    );

    test('the components of one layer dispose concurrently', () async {
      final started = <String>[];
      final gate = Completer<void>();
      Component<T> slow<T>(String name, T value) => Component<T>(
        dependency: Dependency<T>(
          create: () => value,
          dispose: (_) async {
            started.add(name);
            if (started.length == 2) gate.complete();
            await gate.future;
          },
        ),
      );
      final scope = Scope(
        components: [slow<int>('a', 1), slow<String>('b', 'b')],
      );
      rightOf(await scope.run());
      rightOf(await scope.dispose().timeout(const Duration(seconds: 2)));
      expect(started, unorderedEquals(['a', 'b']));
    });

    test(
      'every failure is collected, and every dispose function runs',
      () async {
        final log = <String>[];
        final parent = Scope(
          components: [
            logged<int>('a', 1, log, key: intKey, failDispose: 'a failed'),
            loggedReading<String>(
              'b',
              Dependency.require<int>(key: intKey),
              'b',
              log,
              key: textKey,
              failDispose: 'b failed',
            ),
            logged<bool>('c', true, log, key: flagKey),
          ],
        );
        rightOf(await parent.run());
        final child = parent.child(
          components: [
            logged<double>('child', 1.0, log, failDispose: 'child failed'),
          ],
        );
        rightOf(await child.run());
        log.clear();
        final cause = leftOf(await parent.dispose());
        // Only defects: every failure is a dispose function that threw.
        expect(cause.failures, isEmpty);
        expect(cause.defects, everyElement(isA<DisposeFailure>()));
        expect(cause.defects.map((d) => (d as DisposeFailure).error), [
          'child failed',
          'b failed',
          'a failed',
        ]);
        expect(cause.defects.map((d) => (d as DisposeFailure).owner), [
          'child',
          'b',
          'a',
        ]);
        // The child first, then the strata in reverse order, one after the
        // other: Then(child, Then(b, a)).
        expect(
          cause.fold<String>(
            empty: () => '_',
            fail: (_, _) => 'F',
            die: (_, _) => 'D',
            then: (first, second) => '($first $second)',
            both: (left, right) => '[$left $right]',
          ),
          '(D (D D))',
        );
        expect(
          log,
          containsAll(['dispose child', 'dispose b', 'dispose a', 'dispose c']),
        );
        expect(log, hasLength(4));
        expect(parent.phase, ScopePhase.disposed);
        expect(child.phase, ScopePhase.disposed);
      },
    );

    test(
      'dispose is idempotent and concurrent calls share one result',
      () async {
        final log = <String>[];
        final scope = Scope(
          components: [logged<int>('a', 1, log, failDispose: 'failed')],
        );
        rightOf(await scope.run());
        final first = scope.dispose();
        final second = scope.dispose();
        expect(identical(first, second), isTrue);
        final one = leftOf(await first);
        final two = leftOf(await scope.dispose());
        expect(two, same(one));
        expect(log.where((l) => l == 'dispose a'), hasLength(1));
      },
    );

    test('a successful dispose is a Right on every call', () async {
      final scope = Scope(components: []);
      rightOf(await scope.run());
      expect(await scope.dispose(), const Right<Cause<DiFailure>, Unit>(unit));
      expect(await scope.dispose(), const Right<Cause<DiFailure>, Unit>(unit));
    });

    test('dispose of a declared or failed scope is a Right', () async {
      final declared = Scope(components: []);
      rightOf(await declared.dispose());
      expect(declared.phase, ScopePhase.disposed);
      expect(await failureOfRun(declared), isA<ScopePhaseFailure>());

      final log = <String>[];
      final failed = Scope(
        components: [
          logged<int>('a', 1, log, key: intKey),
          Component<String>(
            key: textKey,
            dependency: Dependency.require<int>(
              key: intKey,
            ).map<String>((_) => throw 'x'),
          ),
        ],
      );
      await failed.run();
      log.clear();
      rightOf(await failed.dispose());
      expect(failed.phase, ScopePhase.disposed);
      expect(log, isEmpty);
    });

    test('dispose during a run waits for the run to settle', () async {
      final gate = Completer<void>();
      final log = <String>[];
      final scope = Scope(
        components: [
          Component<int>(
            dependency: Dependency<int>(
              create: () async {
                log.add('create');
                await gate.future;
                return 1;
              },
              dispose: (_) => log.add('dispose'),
            ),
          ),
        ],
      );
      final run = scope.run();
      var disposed = false;
      final disposal = scope.dispose().then((result) {
        disposed = true;
        return result;
      });
      await pause();
      expect(disposed, isFalse);
      expect(scope.phase, ScopePhase.running);
      gate.complete();
      rightOf(await run);
      rightOf(await disposal);
      expect(log, ['create', 'dispose']);
      expect(scope.phase, ScopePhase.disposed);
    });

    test(
      'dispose during a failing run is a Right and releases nothing twice',
      () async {
        final gate = Completer<void>();
        final log = <String>[];
        final scope = Scope(
          components: [
            Component<int>(
              dependency:
                  Dependency<int>(
                    create: () => 1,
                    dispose: (_) => log.add('dispose'),
                  ).mapTask<int>(
                    (_) => Task(() async {
                      await gate.future;
                      throw 'failed';
                    }),
                  ),
            ),
          ],
        );
        final run = scope.run();
        final disposal = scope.dispose();
        gate.complete();
        expect(leftOf(await run).only, isA<ActivationFailure>());
        rightOf(await disposal);
        expect(log, ['dispose']);
      },
    );

    test('a disposed child leaves its parent', () async {
      final log = <String>[];
      final parent = Scope(components: []);
      rightOf(await parent.run());
      final child = parent.child(
        components: [logged<int>('a', 1, log, failDispose: 'failed')],
      );
      rightOf(await child.run());
      expect(
        leftOf(await child.dispose()).defects.single,
        isA<DisposeFailure>(),
      );
      // The parent does not report the failure of the child again.
      rightOf(await parent.dispose());
      expect(log.where((l) => l == 'dispose a'), hasLength(1));
    });
  });
}
