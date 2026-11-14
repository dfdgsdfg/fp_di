import 'dart:async';
import 'dart:math';

import 'package:fp_di/fp_di.dart';
import 'package:test/test.dart';

void main() {
  group('initialize', () {
    test('rejects a required key that nothing declares', () async {
      final log = <String>[];
      final di = Scope(
        module: Module(
          components: [
            // The publisher forgot its key.
            Component.effect(
              dependency: Dependency<int>(
                create: () {
                  log.add('up db');
                  return 1;
                },
              ),
              debugLabel: 'db',
            ),
            Component(
              dependency: Dependency.require<int>(
                key: const DiKey(name: 'count'),
              ).map((v) => '$v'),
              debugLabel: 'repo',
              key: DiKey<String>(name: 'text'),
            ),
          ],
        ),
      );
      await expectLater(
        di.initialize(),
        throwsA(
          isA<UndeclaredKeyError>()
              .having((e) => e.undeclared, 'undeclared', [
                (label: 'repo', key: DiKey<int>(name: 'count')),
              ])
              .having((e) => e.message, 'message', contains('Component<T>')),
        ),
      );
      expect(log, isEmpty, reason: 'nothing is created');
      expect(di.isInitialized, isFalse);
      expect(di.nodes, isEmpty);
      await di.dispose();
    });

    test('accepts a key that an uninitialized ancestor declares', () async {
      final root = Scope(
        module: Module(
          components: [
            Component.value(value: 1, key: DiKey<int>(name: 'count')),
          ],
        ),
      );
      final child = await root
          .child(
            module: Module(
              components: [
                Component.effect(
                  dependency: Dependency.require<int>(
                    key: const DiKey(name: 'count'),
                  ).map((v) => '$v'),
                ),
              ],
            ),
          )
          .initialize();
      expect(child.nodes.single.isActive, isFalse);
      await root.initialize();
      expect(child.nodes.single.value, '1');
      await root.dispose();
    });

    test('does not check optional reads', () async {
      final di = await Scope(
        module: Module(
          components: [
            Component.effect(
              dependency: Dependency.maybe<int>(
                key: const DiKey(name: 'count'),
              ),
            ),
          ],
        ),
      ).initialize();
      expect(di.nodes.single.isActive, isTrue);
      expect(di.nodes.single.value, isNull);
      await di.dispose();
    });

    test('counts a key only when another member publishes it', () async {
      const k = DiKey<int>(name: 'k');
      // `self` injects the key it publishes, so it needs another publisher;
      // `reader` injects the key and `self` publishes it.
      final self = Component(
        dependency: Dependency.require<int>(key: k).map((v) => v),
        debugLabel: 'self',
        key: k,
      );
      final reader = Component.effect(
        dependency: Dependency.require<int>(key: k).map((v) => v),
        debugLabel: 'reader',
      );
      await expectLater(
        Scope(module: Module(components: [self, reader])).initialize(),
        throwsA(
          isA<UndeclaredKeyError>().having((e) => e.undeclared, 'undeclared', [
            (label: 'self', key: k),
          ]),
        ),
      );
    });

    test(
      'a second initialize on an initialized scope throws StateError',
      () async {
        final di = Scope(
          module: Module(
            components: [
              Component.value(value: 1, key: DiKey<int>(name: 'count')),
            ],
          ),
        );
        await di.initialize();
        expect(di.isInitialized, isTrue);
        await expectLater(di.initialize(), throwsA(isA<StateError>()));
        expect(di.isInitialized, isTrue);
        expect(di.get<int>(key: const DiKey(name: 'count')), 1);
        await di.dispose();
      },
    );

    test('initialize after dispose throws DisposedScopeError', () async {
      final di = Scope(
        module: Module(
          components: [
            Component.value(value: 1, key: DiKey<int>(name: 'count')),
          ],
        ),
      );
      await di.dispose();
      await expectLater(
        () async => di.initialize(),
        throwsA(isA<DisposedScopeError>()),
      );
    });

    test('a failed initialize binds nothing and a retry can succeed', () async {
      final events = <String>[];
      var attempts = 0;
      final di = Scope(
        module: Module(
          components: [
            Component(
              dependency: Dependency(
                create: () {
                  events.add('good+');
                  return 1;
                },
                dispose: (_) => events.add('good-'),
              ),
              debugLabel: 'good',
              key: DiKey<int>(name: 'count'),
            ),
            Component(
              dependency: Dependency<String>(
                create: () {
                  attempts++;
                  if (attempts == 1) throw StateError('first attempt fails');
                  return 'ok';
                },
              ),
              debugLabel: 'flaky',
              key: DiKey<String>(name: 'text'),
            ),
          ],
        ),
      );

      await expectLater(di.initialize(), throwsA(isA<ActivationException>()));
      expect(di.isInitialized, isFalse);
      expect(di.nodes, isEmpty);
      expect(di.maybeGet<int>(key: const DiKey(name: 'count')), isNull);
      expect(di.maybeGet<String>(key: const DiKey(name: 'text')), isNull);
      expect(events, ['good+', 'good-']);

      await di.initialize();
      expect(di.isInitialized, isTrue);
      expect(di.nodes, hasLength(2));
      expect(di.get<int>(key: const DiKey(name: 'count')), 1);
      expect(di.get<String>(key: const DiKey(name: 'text')), 'ok');
      expect(attempts, 2);
      await di.dispose();
    });

    test('nodes is empty and get throws before initialize', () async {
      final di = Scope(
        module: Module(
          components: [
            Component.value(value: 1, key: DiKey<int>(name: 'count')),
          ],
        ),
      );
      expect(di.isInitialized, isFalse);
      expect(di.nodes, isEmpty);
      expect(
        () => di.get<int>(key: const DiKey(name: 'count')),
        throwsA(isA<UnavailableKeyException>()),
      );
      expect(di.maybeGet<int>(key: const DiKey(name: 'count')), isNull);
      await di.dispose();
    });

    test('a child initialized before its parent is dormant until the parent '
        'initializes', () async {
      final root = Scope(
        module: Module(
          components: [
            Component.value(value: 7, key: DiKey<int>(name: 'count')),
          ],
        ),
      );
      final child = root.child(
        module: Module(
          components: [
            Component.effect(
              dependency: Dependency.require<int>(
                key: const DiKey(name: 'count'),
              ),
            ),
          ],
        ),
      );

      await child.initialize();
      expect(child.isInitialized, isTrue);
      expect(root.isInitialized, isFalse);
      final consumer = child.nodes.single;
      expect(consumer.isActive, isFalse);
      expect(consumer.missing, hasLength(1));
      expect(() => consumer.value, throwsA(isA<InactiveNodeException>()));

      await root.initialize();
      expect(consumer.isActive, isTrue);
      expect(consumer.value, 7);
      expect(consumer.missing, isEmpty);
      await root.dispose();
    });
  });

  group('environment and scopes', () {
    test('publish, get, maybeGet, and missing dependency', () async {
      final di = Scope(
        module: Module(
          components: [
            Component.value(
              value: 42,
              debugLabel: 'answer',
              key: DiKey<int>(name: 'count'),
            ),
          ],
        ),
      );
      expect(di.maybeGet<int>(key: const DiKey(name: 'count')), isNull);
      expect(
        () => di.get<int>(key: const DiKey(name: 'count')),
        throwsA(isA<UnavailableKeyException>()),
      );

      await di.initialize();
      expect(di.get<int>(key: const DiKey(name: 'count')), 42);
      expect(di.nodes.single.value, 42);
      await di.dispose();
    });

    test('duplicate publishers are rejected atomically', () async {
      final di = Scope(
        module: Module(
          components: [
            Component.value(value: 1, key: DiKey<int>(name: 'count')),
            Component.value(value: 2, key: DiKey<int>(name: 'count')),
          ],
        ),
      );
      await expectLater(di.initialize(), throwsA(isA<DuplicateKeyError>()));
      // The failed initialize rolls back the first publisher too.
      expect(di.isInitialized, isFalse);
      expect(di.nodes, isEmpty);
      expect(di.maybeGet<int>(key: const DiKey(name: 'count')), isNull);
      await di.dispose();
    });

    test('named keys and child bindings retain parent lookup', () async {
      final primary = DiKey<String>(name: 'primary');
      final analytics = DiKey<String>(name: 'analytics');
      final root = Scope(
        module: Module(
          components: [
            Component.value(value: 'production', key: primary),
            Component.value(value: 'analytics', key: analytics),
          ],
        ),
      );
      final child = root.child(
        module: Module(
          components: [Component.value(value: 'mock', key: primary)],
        ),
      );
      await root.initialize();
      await child.initialize();

      expect(root.get<String>(key: primary), 'production');
      expect(child.get<String>(key: primary), 'mock');
      expect(child.get<String>(key: analytics), 'analytics');

      await child.nodes.single.dispose();
      expect(child.get<String>(key: primary), 'production');
      await child.dispose();
      await root.nodes[0].dispose();
      await root.nodes[1].dispose();
      await root.dispose();
    });

    test('disposing a scope recursively disposes descendants', () async {
      final events = <String>[];
      final root = Scope();
      final child = root.child();
      final grandchild = child.child(
        module: Module(
          components: [
            Component(
              dependency: Dependency(
                create: () => 'value',
                dispose: (_) => events.add('grandchild'),
              ),
              key: DiKey<String>(name: 'text'),
            ),
          ],
        ),
      );
      await root.initialize();
      await child.initialize();
      await grandchild.initialize();
      await child.dispose();
      expect(events, ['grandchild']);
      expect(
        () => grandchild.get<String>(key: const DiKey(name: 'text')),
        throwsA(isA<DisposedScopeError>()),
      );
      await root.dispose();
    });

    test(
      'a failing listener is reported without interrupting lifecycle',
      () async {
        final di = Scope(
          module: Module(
            components: [
              Component.value(value: 1, key: DiKey<int>(name: 'count')),
            ],
          ),
        );
        final reported = di.errors.first;
        di.addListener(() => throw StateError('listener failed'));
        await di.initialize();
        expect(di.get<int>(key: const DiKey(name: 'count')), 1);
        expect(await reported, isA<DiListenerException>());
        await di.nodes.single.dispose();
        await di.dispose();
      },
    );
  });

  group('component lifecycle', () {
    test('cleanup is LIFO and handle disposal is idempotent', () async {
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
        module: Module(
          components: [Component.effect(dependency: chain.map((_) => 'ready'))],
        ),
      );
      await di.initialize();
      final handle = di.nodes.single;
      await handle.dispose();
      await handle.dispose();
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
      expect(() => handle.value, throwsA(isA<InactiveNodeException>()));
      await di.dispose();
    });

    test(
      'a dependent releases first while its publisher value is still alive',
      () async {
        final events = <String>[];
        final database = DiKey<String>(name: 'database');
        final repository = DiKey<String>(name: 'repository');
        var databaseReleased = false;
        String? readDatabase;

        final di = Scope(
          module: Module(
            components: [
              Component(
                dependency: Dependency(
                  create: () => 'db',
                  dispose: (_) {
                    databaseReleased = true;
                    events.add('A');
                  },
                ),
                debugLabel: 'database',
                key: database,
              ),
              Component(
                dependency: Dependency.require<String>(key: database).map(
                  (db) {
                    readDatabase = db;
                    return 'repo';
                  },
                  dispose: (_) {
                    expect(databaseReleased, isFalse);
                    expect(readDatabase, 'db');
                    events.add('B');
                  },
                ),
                debugLabel: 'repository',
                key: repository,
              ),
              Component.effect(
                dependency: Dependency.require<String>(
                  key: repository,
                ).map((_) => 'feature', dispose: (_) => events.add('C')),
                debugLabel: 'feature',
              ),
            ],
          ),
        );
        await di.initialize();
        final [a, b, c] = di.nodes;

        await a.dispose();
        expect(events, ['C', 'B', 'A']);
        expect(b.isActive, isFalse);
        expect(c.isActive, isFalse);
        await di.dispose();
      },
    );

    test('activation failure rolls back all completed effects', () async {
      final events = <String>[];
      final di = Scope(
        module: Module(
          components: [
            Component.effect(
              dependency:
                  Dependency(
                        create: () => events.add('A+'),
                        dispose: (_) => events.add('A-'),
                      )
                      .map(
                        (_) => events.add('B+'),
                        dispose: (_) => events.add('B-'),
                      )
                      .map<void>((_) => throw StateError('C failed')),
            ),
          ],
        ),
      );
      await expectLater(
        di.initialize(),
        throwsA(
          isA<ActivationException>().having(
            (failure) => failure.cause,
            'cause',
            isA<StateError>(),
          ),
        ),
      );
      expect(events, ['A+', 'B+', 'B-', 'A-']);
      expect(di.isInitialized, isFalse);
      await di.dispose();
    });

    test(
      'activation reports rollback cleanup failures with the cause',
      () async {
        final di = Scope(
          module: Module(
            components: [
              Component.effect(
                dependency: Dependency<int>(
                  create: () => 1,
                  dispose: (_) => throw StateError('rollback failed'),
                ).map<void>((_) => throw StateError('activation failed')),
              ),
            ],
          ),
        );
        await expectLater(
          di.initialize(),
          throwsA(
            isA<ActivationException>()
                .having((failure) => failure.cause, 'cause', isA<StateError>())
                .having(
                  (failure) => failure.rollbackFailures.length,
                  'rollback failures',
                  1,
                ),
          ),
        );
        await di.dispose();
      },
    );

    test('cleanup failures are aggregated without short-circuiting', () async {
      final events = <String>[];
      final di = Scope(
        module: Module(
          components: [
            Component.effect(
              dependency:
                  Dependency<int>(
                    create: () => 1,
                    dispose: (_) {
                      events.add('first');
                      throw StateError('first');
                    },
                  ).map(
                    (_) => 2,
                    dispose: (_) {
                      events.add('second');
                      throw StateError('second');
                    },
                  ),
            ),
          ],
        ),
      );
      await di.initialize();
      final handle = di.nodes.single;

      await expectLater(
        handle.dispose(),
        throwsA(
          isA<DisposeException>().having(
            (failure) => failure.disposeFailures.length,
            'disposeFailures',
            2,
          ),
        ),
      );
      expect(events, ['second', 'first']);
      await di.dispose();
    });

    test('independent components do not affect each other', () async {
      final di = Scope(
        module: Module(
          components: [
            Component.value(value: 1, key: DiKey<int>(name: 'left')),
            Component.value(value: 2, key: DiKey<int>(name: 'right')),
          ],
        ),
      );
      await di.initialize();
      final [left, right] = di.nodes;
      await left.dispose();
      expect(right.isActive, isTrue);
      expect(di.get<int>(key: DiKey<int>(name: 'right')), 2);
      await di.dispose();
    });

    test('concurrent lifecycle mutations are serialized', () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final events = <String>[];
      final root = Scope(
        module: Module(
          components: [
            Component(
              dependency: Dependency(
                create: () async {
                  events.add('first start');
                  started.complete();
                  await release.future;
                  events.add('first end');
                  return 1;
                },
              ),
              key: DiKey<int>(name: 'first'),
            ),
          ],
        ),
      );
      final other = root.child(
        module: Module(
          components: [
            Component(
              dependency: Dependency(
                create: () {
                  events.add('second');
                  return 2;
                },
              ),
              key: DiKey<int>(name: 'second'),
            ),
          ],
        ),
      );
      final first = root.initialize();
      await started.future;
      final second = other.initialize();
      await Future<void>.delayed(Duration.zero);
      expect(events, ['first start']);
      release.complete();
      await Future.wait([first, second]);
      expect(events, ['first start', 'first end', 'second']);
      await root.dispose();
    });
  });

  group('composition', () {
    test('Dependency.map acquires forward and releases backward', () async {
      final events = <String>[];
      final chain =
          Dependency(
            create: () {
              events.add('A+');
              return 2;
            },
            dispose: (_) => events.add('A-'),
          ).map((value) {
            events.add('B+');
            return '$value!';
          }, dispose: (_) => events.add('B-'));
      final di = Scope(
        module: Module(components: [Component.effect(dependency: chain)]),
      );
      await di.initialize();
      final handle = di.nodes.single;
      expect(handle.value, '2!');
      await handle.dispose();
      expect(events, ['A+', 'B+', 'B-', 'A-']);
      await di.dispose();
    });

    test(
      'Dependency.map rolls back the first step if the second fails',
      () async {
        final events = <String>[];
        final chain =
            Dependency(
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
          module: Module(components: [Component.effect(dependency: chain)]),
        );
        await expectLater(di.initialize(), throwsA(isA<ActivationException>()));
        expect(events, ['A+', 'B!', 'A-']);
        await di.dispose();
      },
    );

    test('Dependency map steps with and without dispose share ordered '
        'ownership', () async {
      final events = <String>[];
      int step(int value) {
        events.add('$value+');
        return value;
      }

      void release(int value) => events.add('$value-');
      final composed = Component.effect(
        dependency: Dependency.require<int>(key: DiKey<int>(name: 'seed'))
            .map(step, dispose: release)
            .map((value) => value + 1)
            .map(step, dispose: release)
            .map((value) => step(value + 1), dispose: release),
      );
      final di = Scope(
        module: Module(
          components: [
            Component.value(value: 1, key: DiKey<int>(name: 'seed')),
            composed,
          ],
        ),
      );
      await di.initialize();
      final [seed, handle] = di.nodes;
      expect(handle.value, 3);
      await handle.dispose();
      expect(events, ['1+', '2+', '3+', '3-', '2-', '1-']);
      await seed.dispose();
      await di.dispose();
    });

    test('LIFO cleanup holds for generated effect sequences', () async {
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
          chain = chain.map((_) => value, dispose: (_) => releases.add(value));
        }
        final di = Scope(
          module: Module(
            components: [Component.effect(dependency: chain.map((_) => size))],
          ),
        );
        await di.initialize();
        await di.nodes.single.dispose();
        expect(releases, List<int>.generate(size, (i) => size - i - 1));
        await di.dispose();
      }
    });
  });

  group('reactive publisher lifecycle', () {
    test(
      'publisher removal deactivates and later replacement reactivates',
      () async {
        final version = DiKey<int>(name: 'version');
        final root = Scope(
          module: Module(components: [Component.value(value: 1, key: version)]),
        );
        // The pending scope sits between the dependent and the first publisher.
        final replacement = root.child(
          module: Module(components: [Component.value(value: 2, key: version)]),
        );
        var activations = 0;
        final leaf = replacement.child(
          module: Module(
            components: [
              Component.effect(
                dependency: Dependency.require<int>(key: version).map((value) {
                  activations++;
                  return value;
                }),
              ),
            ],
          ),
        );
        await root.initialize();
        await leaf.initialize();
        final first = root.nodes.single;
        final dependent = leaf.nodes.single;
        expect(dependent.value, 1);

        await first.dispose();
        expect(dependent.isActive, isFalse);
        await replacement.initialize();
        expect(dependent.isActive, isTrue);
        expect(dependent.value, 2);
        expect(activations, 2);

        await root.dispose();
      },
    );

    test('a nearer binding reloads dependents by publisher identity', () async {
      final version = DiKey<int>(name: 'version');
      final root = Scope(
        module: Module(components: [Component.value(value: 1, key: version)]),
      );
      final mid = root.child(
        module: Module(components: [Component.value(value: 2, key: version)]),
      );
      final leaf = mid.child(
        module: Module(
          components: [
            Component.effect(dependency: Dependency.require<int>(key: version)),
          ],
        ),
      );
      await root.initialize();
      await leaf.initialize();
      final dependent = leaf.nodes.single;
      expect(dependent.value, 1);

      await mid.initialize();
      final local = mid.nodes.single;
      expect(dependent.value, 2);
      await local.dispose();
      expect(dependent.value, 1);

      await root.dispose();
    });

    test('cleanup failure blocks automatic reacquisition', () async {
      final root = Scope(
        module: Module(
          components: [
            Component.value(value: 1, key: DiKey<int>(name: 'count')),
          ],
        ),
      );
      final mid = root.child(
        module: Module(
          components: [
            Component.value(value: 2, key: DiKey<int>(name: 'count')),
          ],
        ),
      );
      var activations = 0;
      final leaf = mid.child(
        module: Module(
          components: [
            Component.effect(
              dependency:
                  Dependency.require<int>(key: const DiKey(name: 'count')).map(
                    (_) => ++activations,
                    dispose: (_) => throw StateError('not released'),
                  ),
            ),
          ],
        ),
      );
      await root.initialize();
      await leaf.initialize();
      final publisher = root.nodes.single;
      final dependent = leaf.nodes.single;

      await expectLater(publisher.dispose(), throwsA(isA<DisposeException>()));
      await mid.initialize();
      expect(dependent.isActive, isFalse);
      expect(activations, 1);

      await dependent.dispose();
      await root.dispose();
    });

    test('stream subscriptions are owned effects', () async {
      final controller = StreamController<int>();
      final values = <int>[];
      final di = Scope(
        module: Module(
          components: [
            Component.effect(
              dependency: Dependency<StreamSubscription<int>>(
                create: () => controller.stream.listen(values.add),
                dispose: (subscription) => subscription.cancel(),
              ),
            ),
          ],
        ),
      );
      await di.initialize();
      final handle = di.nodes.single;
      controller.add(1);
      await Future<void>.delayed(Duration.zero);
      await handle.dispose();
      controller.add(2);
      await Future<void>.delayed(Duration.zero);
      expect(values, [1]);
      await controller.close();
      await di.dispose();
    });
  });
}
