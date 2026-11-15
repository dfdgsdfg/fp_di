import 'dart:async';

import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('run', () {
    test('a scope builds nothing before run is called', () async {
      final log = <String>[];
      final scope = Scope(components: [logged<int>('a', 1, log, key: intKey)]);
      expect(scope.phase, ScopePhase.declared);
      final task = scope.run;
      expect(log, isEmpty);
      expect(scope.parent, const None());
      final result = rightOf(await task());
      expect(result, same(scope));
      expect(log, ['create a']);
      expect(scope.phase, ScopePhase.initialized);
      expect(scope.isInitialized, isTrue);
    });

    test('a second run is a Left, never a cached Right', () async {
      final scope = Scope(components: []);
      rightOf(await scope.run());
      final second = leftOf(await scope.run()).only;
      expect(
        second,
        isA<ScopePhaseFailure>()
            .having((f) => f.operation, 'operation', 'run')
            .having((f) => f.phase, 'phase', ScopePhase.initialized),
      );
      expect(second.message, contains('run'));
    });

    test(
      'a second run during the first run waits and then is a Left',
      () async {
        // from: core_test.dart: concurrent lifecycle mutations are serialized
        final gate = Completer<void>();
        final scope = Scope(
          components: [
            Component<int>(
              dependency: Dependency<int>(
                create: () async {
                  await gate.future;
                  return 1;
                },
              ),
            ),
          ],
        );
        final first = scope.run();
        final second = scope.run();
        await pause(1);
        expect(scope.phase, ScopePhase.initializing);
        gate.complete();
        rightOf(await first);
        expect(
          leftOf(await second).only,
          isA<ScopePhaseFailure>().having(
            (f) => f.phase,
            'phase',
            ScopePhase.initialized,
          ),
        );
      },
    );

    test('a run after a failed run starts again', () async {
      // from: core_test.dart: a failed initialize binds nothing and a retry
      // can succeed
      var attempts = 0;
      final scope = Scope(
        components: [
          Component<int>(
            dependency: Dependency<int>(
              create: () => ++attempts == 1 ? throw 'x' : attempts,
            ),
          ),
        ],
      );
      expect(await failureOfRun(scope), isA<ActivationFailure>());
      expect(scope.phase, ScopePhase.declared);
      expect(scope.nodes, isEmpty);
      rightOf(await scope.run());
      expect(scope.phase, ScopePhase.initialized);
      expect(rightOf(scope.get<int>()), 2);
    });

    test('get answers before run, and is a Left after dispose', () async {
      // from: core_test.dart: nodes is empty and get throws before initialize
      final scope = Scope(
        components: [Component<int>.value(key: intKey, value: 1)],
      );
      expect(leftOf(scope.get<int>(key: intKey)), isA<UnavailableKeyFailure>());
      expect(scope.getOption<int>(key: intKey), isA<None>());
      expect(scope.nodes, isEmpty);
      rightOf(await scope.run());
      expect(rightOf(scope.get<int>(key: intKey)), 1);
      expect(scope.getOption<int>(key: intKey), const Some(1));
      rightOf(await scope.dispose());
      expect(
        leftOf(scope.get<int>(key: intKey)),
        isA<DisposedScopeFailure>().having(
          (f) => f.operation,
          'operation',
          'get',
        ),
      );
      expect(scope.getOption<int>(key: intKey), isA<None>());
    });

    test('get of an unpublished key is an UnavailableKeyFailure', () async {
      final scope = Scope(components: []);
      rightOf(await scope.run());
      expect(
        leftOf(scope.get<int>(key: intKey)),
        isA<UnavailableKeyFailure>().having((f) => f.key, 'key', intKey),
      );
      expect(scope.getOption<int>(key: intKey), isA<None>());
    });

    test('get reads a published null', () async {
      final scope = Scope(components: [Component<int?>.value(value: null)]);
      rightOf(await scope.run());
      expect(rightOf(scope.get<int?>()), isNull);
    });
  });

  group('order', () {
    test('a dependent activates after its publisher, across layers', () async {
      final log = <String>[];
      final scope = Scope(
        components: [
          // Declared first, but it reads the key of a later component.
          Component<String>(
            key: textKey,
            debugLabel: 'c',
            dependency: Dependency.require<bool>(key: flagKey).map<String>((_) {
              log.add('create c');
              return 'c';
            }),
          ),
          Component<bool>(
            key: flagKey,
            debugLabel: 'b',
            dependency: Dependency.require<int>(key: intKey).map<bool>((_) {
              log.add('create b');
              return true;
            }),
          ),
          Component<int>(
            key: intKey,
            debugLabel: 'a',
            dependency: Dependency<int>(
              create: () async {
                await pause(10);
                log.add('create a');
                return 1;
              },
            ),
          ),
        ],
      );
      rightOf(await scope.run());
      expect(log, ['create a', 'create b', 'create c']);
    });

    test('independent components activate concurrently', () async {
      final aStarted = Completer<void>();
      final bStarted = Completer<void>();
      Component<T> waiting<T>(
        T value,
        Completer<void> mine,
        Completer<void> theirs,
      ) => Component<T>(
        dependency: Dependency<T>(
          create: () async {
            mine.complete();
            await theirs.future;
            return value;
          },
        ),
      );
      final scope = Scope(
        components: [
          waiting<int>(1, aStarted, bStarted),
          waiting<String>('b', bStarted, aStarted),
        ],
      );
      rightOf(await scope.run().timeout(const Duration(seconds: 2)));
      expect(rightOf(scope.get<int>()), 1);
      expect(rightOf(scope.get<String>()), 'b');
    });

    test('a node starts when its own publishers committed', () async {
      // Each node commits on its own: `b` does not wait for the slow
      // independent node.
      final log = <String>[];
      final scope = Scope(
        components: [
          Component<int>(
            key: intKey,
            dependency: Dependency<int>(
              create: () async {
                await pause(5);
                log.add('a');
                return 1;
              },
            ),
          ),
          Component<String>(
            key: textKey,
            dependency: Dependency<String>(
              create: () async {
                await pause(60);
                log.add('slow');
                return 's';
              },
            ),
          ),
          Component<bool>(
            key: flagKey,
            dependency: Dependency.require<int>(key: intKey).map<bool>((_) {
              log.add('b');
              return true;
            }),
          ),
        ],
      );
      rightOf(await scope.run());
      expect(log, ['a', 'b', 'slow']);
    });

    test(
      'an optional read orders the activation after the publisher',
      () async {
        final log = <String>[];
        final scope = Scope(
          components: [
            Component<String>(
              key: textKey,
              dependency: Dependency.option<int>(key: intKey).map<String>((o) {
                log.add('read');
                return o.match(() => 'none', (v) => 'some $v');
              }),
            ),
            Component<int>(
              key: intKey,
              dependency: Dependency<int>(
                create: () async {
                  await pause(10);
                  log.add('create');
                  return 1;
                },
              ),
            ),
          ],
        );
        rightOf(await scope.run());
        expect(log, ['create', 'read']);
        expect(rightOf(scope.get<String>(key: textKey)), 'some 1');
      },
    );

    test('an optional read is None when no scope publishes the key', () async {
      final scope = Scope(
        components: [
          Component<String>(
            key: textKey,
            dependency: Dependency.option<int>(
              key: intKey,
            ).map<String>((o) => o.match(() => 'none', (v) => 'some $v')),
          ),
        ],
      );
      rightOf(await scope.run());
      expect(rightOf(scope.get<String>(key: textKey)), 'none');
    });
  });

  group('failure', () {
    test(
      'a failed member rolls back committed members in reverse order',
      () async {
        // from: core_test.dart: activation failure rolls back all completed
        // effects
        final log = <String>[];
        final scope = Scope(
          components: [
            logged<int>('a', 1, log, key: intKey),
            loggedReading<String>(
              'b',
              Dependency.require<int>(key: intKey),
              'b',
              log,
              key: textKey,
            ),
            Component<bool>(
              key: flagKey,
              debugLabel: 'c',
              dependency: Dependency.require<String>(key: textKey).map<bool>((
                _,
              ) {
                log.add('create c');
                throw StateError('c failed');
              }),
            ),
          ],
        );
        final failure = await failureOfRun(scope);
        expect(failure, isA<ActivationFailure>());
        expect((failure as ActivationFailure).owner, 'c');
        expect(log, [
          'create a',
          'create b',
          'create c',
          'dispose b',
          'dispose a',
        ]);
        expect(scope.phase, ScopePhase.declared);
      },
    );

    test(
      'a failure rolls back every committed member, dependents first',
      () async {
        final log = <String>[];
        final scope = Scope(
          components: [
            logged<int>('a', 1, log, key: intKey, failDispose: 'a rollback'),
            logged<String>('x', 'x', log, key: textKey),
            loggedReading<bool>(
              'd',
              Dependency.require<int>(key: intKey),
              true,
              log,
              key: flagKey,
              failDispose: 'd rollback',
            ),
            Component<double>(
              debugLabel: 'c',
              dependency: Dependency.require<int>(
                key: intKey,
              ).map<double>((_) => throw StateError('c failed')),
            ),
          ],
        );
        final cause = await causeOfRun(scope);
        expect((cause.only as ActivationFailure).owner, 'c');
        // The rollback releases the members in reverse order of declaration,
        // and a reader before its publisher.
        expect(log.indexOf('dispose d'), lessThan(log.indexOf('dispose a')));
        expect(log.indexOf('dispose x'), lessThan(log.indexOf('dispose a')));
        expect(log.indexOf('dispose d'), lessThan(log.indexOf('dispose x')));
        expect(disposeFailuresOf(cause), ['d: d rollback', 'a: a rollback']);
        // The failure comes first, then the rollback of each member.
        expect(
          cause.fold<String>(
            empty: () => '_',
            fail: (_, _) => 'F',
            die: (_, _) => 'D',
            interrupt: (_) => 'I',
            then: (first, second) => '($first $second)',
            both: (left, right) => '[$left $right]',
          ),
          '(F (D D))',
        );
        expect(scope.phase, ScopePhase.declared);
      },
    );

    test(
      'the failure of the lowest id wins, and no new member starts',
      () async {
        final scope = Scope(
          components: [
            Component<int>(
              key: intKey,
              debugLabel: 'slow',
              dependency: Dependency<int>(
                create: () async {
                  await pause(30);
                  throw 'slow failed';
                },
                dispose: (_) {},
              ),
            ),
            Component<String>(
              key: textKey,
              debugLabel: 'quick',
              dependency: Dependency<String>(
                create: () => 'x',
                dispose: (_) {},
              ).map<String>((_) => throw 'quick failed'),
            ),
            // It reads a member that fails: it never starts.
            Component<bool>(
              key: flagKey,
              dependency: Dependency.require<int>(key: intKey).map<bool>((_) {
                fail('The next member must not start.');
              }),
            ),
          ],
        );
        final cause = await causeOfRun(scope);
        // The member in flight settles, so both failed, and the first by id
        // is the failure of the call.
        expect(
          [for (final f in cause.failures) (f as ActivationFailure).owner],
          ['slow'],
        );
        expect(cause.defects, isEmpty);
      },
    );

    test('rollback failures of other failed members are kept', () async {
      // from: review_regression_test.dart: 4. the rollback failures of every
      // failed member are kept
      Component<int> failing(String name, DiKey<int> key) => Component<int>(
        key: key,
        debugLabel: name,
        dependency: Dependency<int>(
          create: () => 1,
          dispose: (_) => throw '$name rollback',
        ).map<int>((_) => throw '$name failed'),
      );
      final scope = Scope(
        components: [
          failing('one', const DiKey<int>(name: 'one')),
          failing('two', const DiKey<int>(name: 'two')),
        ],
      );
      final cause = await causeOfRun(scope);
      // The failure of the first member by id, with its own rollback, and the
      // rollback failures of the other member.
      expect(
        [for (final f in cause.failures) (f as ActivationFailure).owner],
        ['one'],
      );
      expect(
        [for (final d in cause.defects) (d as DisposeFailure).owner],
        ['one', 'two'],
      );
    });

    test('nothing is published after a failed run', () async {
      final scope = Scope(
        components: [
          Component<int>.value(key: intKey, value: 1),
          Component<String>(
            key: textKey,
            dependency: Dependency.require<int>(
              key: intKey,
            ).map<String>((_) => throw 'x'),
          ),
        ],
      );
      await scope.run();
      expect(leftOf(scope.get<int>(key: intKey)), isA<UnavailableKeyFailure>());
      expect(scope.getOption<int>(key: intKey), isA<None>());
      expect(scope.phase, ScopePhase.declared);
      rightOf(await scope.dispose());
    });
  });

  group('validation', () {
    test('a duplicate key is a Left and creates nothing', () async {
      final log = <String>[];
      final failure = await failureOfRun(
        Scope(
          components: [
            logged<int>('first', 1, log, key: intKey),
            logged<int>('second', 2, log, key: intKey),
            logged<String>('other', 'x', log),
          ],
        ),
      );
      expect(
        failure,
        isA<DuplicateKeyFailure>().having((f) => f.key, 'key', intKey).having(
          (f) => f.labels,
          'labels',
          ['first', 'second'],
        ),
      );
      expect(log, isEmpty);
    });

    test('an undeclared key is a Left and creates nothing', () async {
      final log = <String>[];
      final scope = Scope(
        components: [
          logged<String>('a', 'a', log),
          loggedReading<bool>(
            'b',
            Dependency.require<int>(key: intKey),
            true,
            log,
          ),
        ],
      );
      final failure = await failureOfRun(scope);
      expect(
        failure,
        isA<UndeclaredKeyFailure>()
            .having((f) => f.key, 'key', intKey)
            .having((f) => f.owner, 'owner', 'b'),
      );
      expect(log, isEmpty);
      expect(scope.phase, ScopePhase.declared);
    });

    test('a cycle leaves its members waiting', () async {
      final log = <String>[];
      final scope = Scope(
        components: [
          logged<bool>('free', true, log, key: flagKey),
          loggedReading<int>(
            'a',
            Dependency.require<String>(key: textKey),
            1,
            log,
            key: intKey,
          ),
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
      // Nothing creates a value of a member that waits for the other one.
      expect(log, ['create free']);
      final [free, a, b] = scope.nodes;
      expect(free.isActive, isTrue);
      expect(a.state.phase, NodePhase.waiting);
      expect(a.missing, [textKey]);
      expect(b.state.phase, NodePhase.waiting);
      expect(b.missing, [intKey]);
    });

    test('optional feedback among the members fails the run', () async {
      // from: regression_test.dart: optional feedback among the members fails
      // initialize
      var runs = 0;
      final scope = Scope(
        components: [
          Component<int>(
            key: intKey,
            debugLabel: 'x',
            dependency: Dependency.option<String>(
              key: textKey,
            ).map<int>((_) => ++runs),
          ),
          Component<String>(
            key: textKey,
            debugLabel: 'y',
            dependency: Dependency.require<int>(
              key: intKey,
            ).map<String>((_) => 'y'),
          ),
        ],
      );
      final errors = <Cause<DiFailure>>[];
      final subscription = scope.errors.listen(errors.add);
      final failure = await failureOfRun(scope);
      expect(
        failure,
        isA<UnsettledFailure>().having((f) => f.passes, 'passes', 3).having(
          (f) => f.labels,
          'labels',
          ['x'],
        ),
      );
      // Two nodes allow three passes, so x runs a bounded number of times.
      expect(runs, lessThanOrEqualTo(4));
      expect(scope.phase, ScopePhase.declared, reason: 'the call rolls back');
      expect(scope.getOption<int>(key: intKey), isA<None>());
      await pause(1);
      expect(errors, isEmpty, reason: 'the caller receives the failure');
      await subscription.cancel();
    });

    test('a component that requires its own key is undeclared', () async {
      final scope = Scope(
        components: [
          Component<int>(
            key: intKey,
            dependency: Dependency.require<int>(key: intKey).map<int>((v) => v),
          ),
        ],
      );
      expect(
        await failureOfRun(scope),
        isA<UndeclaredKeyFailure>().having((f) => f.key, 'key', intKey),
      );
    });

    test('validation accumulates duplicates and undeclared keys', () async {
      final log = <String>[];
      final scope = Scope(
        components: [
          logged<int>('first', 1, log, key: intKey),
          logged<int>('second', 2, log, key: intKey),
          loggedReading<String>(
            'u1',
            Dependency.require<bool>(key: flagKey),
            'x',
            log,
            key: textKey,
          ),
          loggedReading<double>('u2', Dependency.require<BigInt>(), 1.0, log),
        ],
      );
      final cause = await causeOfRun(scope);
      expect(cause.failures, hasLength(3));
      expect(cause.defects, isEmpty);
      // Duplicates first, then undeclared keys, each in declaration order.
      expect(cause.failures[0], isA<DuplicateKeyFailure>());
      expect(
        cause.failures[1],
        isA<UndeclaredKeyFailure>().having((f) => f.owner, 'owner', 'u1'),
      );
      expect(
        cause.failures[2],
        isA<UndeclaredKeyFailure>().having((f) => f.owner, 'owner', 'u2'),
      );
      // Every failure is a Fail, joined with Both.
      expect(
        cause.fold<bool>(
          empty: () => false,
          fail: (_, _) => true,
          die: (_, _) => false,
          interrupt: (_) => false,
          then: (_, _) => false,
          both: (left, right) => left && right,
        ),
        isTrue,
      );
      expect(log, isEmpty);
      expect(scope.phase, ScopePhase.declared);
      expect(scope.nodes, isEmpty);
      expect(scope.state.nodeStates, isEmpty);
    });
  });
}
