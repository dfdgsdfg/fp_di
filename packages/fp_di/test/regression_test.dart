import 'dart:async';

import 'package:fp_di/fp_di.dart';
import 'package:test/test.dart';

void main() {
  test(
    'a dependent cleanup failure does not block the publisher reload',
    () async {
      final trigger = DiKey<int>(name: 'trigger');
      final root = Scope(
        module: Module(components: [Component.value(value: 0, key: trigger)]),
      );
      // The pending scope supplies the second trigger after the first leaves.
      final mid = root.child(
        module: Module(components: [Component.value(value: 1, key: trigger)]),
      );

      var publisherActivations = 0;
      final leaf = mid.child(
        module: Module(
          components: [
            Component(
              dependency: Dependency.require<int>(key: trigger).map((_) {
                publisherActivations++;
                return 'service';
              }),
              debugLabel: 'publisher',
              key: DiKey<String>(name: 'text'),
            ),
            Component.effect(
              dependency:
                  Dependency.require<String>(
                    key: const DiKey(name: 'text'),
                  ).map(
                    (_) => 1,
                    dispose: (_) =>
                        throw StateError('dependent cleanup failed'),
                  ),
              debugLabel: 'dependent',
            ),
          ],
        ),
      );
      await root.initialize();
      await leaf.initialize();
      final first = root.nodes.single;
      final [publisher, dependent] = leaf.nodes;

      await expectLater(first.dispose(), throwsA(isA<DisposeException>()));
      expect(publisher.isActive, isFalse);
      expect(dependent.isActive, isFalse);

      // The publisher's own inverses all succeeded, so only the dependent is
      // barred from reacquiring.
      await mid.initialize();
      expect(publisher.isActive, isTrue);
      expect(publisherActivations, 2);
      expect(dependent.isActive, isFalse);

      await publisher.dispose();
      await dependent.dispose();
      await root.dispose();
    },
  );

  test('a component whose own cleanup fails stays blocked', () async {
    final root = Scope(
      module: Module(
        components: [Component.value(value: 1, key: DiKey<int>(name: 'count'))],
      ),
    );
    final mid = root.child(
      module: Module(
        components: [Component.value(value: 2, key: DiKey<int>(name: 'count'))],
      ),
    );
    var activations = 0;
    final leaf = mid.child(
      module: Module(
        components: [
          Component.effect(
            dependency: Dependency.require<int>(key: const DiKey(name: 'count'))
                .map(
                  (_) => ++activations,
                  dispose: (_) => throw StateError('own cleanup failed'),
                ),
          ),
        ],
      ),
    );
    await root.initialize();
    await leaf.initialize();
    final first = root.nodes.single;
    final node = leaf.nodes.single;

    await expectLater(first.dispose(), throwsA(isA<DisposeException>()));
    await mid.initialize();
    expect(node.isActive, isFalse);
    expect(activations, 1);

    await node.dispose();
    await root.dispose();
  });

  test('a nested mutation reports instead of deadlocking', () async {
    final di = Scope();
    final other = di.child(
      module: Module(
        components: [Component.value(value: 1, key: DiKey<int>(name: 'count'))],
      ),
    );
    final outer = di.child(
      module: Module(
        components: [
          Component.effect(
            dependency: Dependency<int>(
              create: () async {
                await other.initialize();
                return 2;
              },
            ),
          ),
        ],
      ),
    );
    await expectLater(
      outer.initialize(),
      throwsA(isA<ReentrantMutationError>()),
    ).timeout(const Duration(seconds: 5));
    await di.dispose();
  });

  test(
    'a nested mutation from a release reports instead of deadlocking',
    () async {
      final root = Scope();
      final other = root.child(
        module: Module(
          components: [
            Component.value(value: 9, key: DiKey<int>(name: 'count')),
          ],
        ),
      );
      final di = root.child(
        module: Module(
          components: [
            Component.effect(
              dependency: Dependency<void>(
                create: () {},
                dispose: (_) => other.initialize(),
              ),
            ),
          ],
        ),
      );
      await di.initialize();
      final handle = di.nodes.single;
      await expectLater(
        handle.dispose(),
        throwsA(isA<DisposeException>()),
      ).timeout(const Duration(seconds: 5));
      await root.dispose();
    },
  );

  test('a FutureOr key is rejected as unreachable', () async {
    // A component of FutureOr<String> publishes under a key that no lookup
    // can name. Silently publishing it would strand the binding.
    final rejected = Scope(
      module: Module(
        components: [
          Component<FutureOr<String>>(
            dependency: Dependency(create: () => 'inner'),
            key: DiKey<FutureOr<String>>(),
          ),
        ],
      ),
    );
    await expectLater(
      rejected.initialize(),
      throwsA(isA<UnreachableKeyError>()),
    );
    expect(rejected.isInitialized, isFalse);
    expect(rejected.maybeGet<String>(key: const DiKey(name: 'text')), isNull);
    await rejected.dispose();

    // The explicit type argument is the documented way out.
    final di = Scope(
      module: Module(
        components: [
          Component<String>(
            dependency: Dependency(create: () => 'inner'),
            key: DiKey<String>(name: 'text'),
          ),
        ],
      ),
    );
    await di.initialize();
    expect(di.get<String>(key: const DiKey(name: 'text')), 'inner');
    await di.dispose();
  });

  test('an unrelated caller may queue while a mutation is in flight', () async {
    final release = Completer<void>();
    final root = Scope(
      module: Module(
        components: [
          Component(
            dependency: Dependency(
              create: () async {
                await release.future;
                return 1;
              },
            ),
            key: DiKey<int>(name: 'slow'),
          ),
        ],
      ),
    );
    final other = root.child(
      module: Module(
        components: [
          Component.value(value: 2, key: DiKey<int>(name: 'queued')),
        ],
      ),
    );
    final slow = root.initialize();
    // Issued from outside the mutation: must queue, not be rejected.
    final queued = other.initialize();
    release.complete();
    await slow;
    await queued;
    expect(other.get<int>(key: DiKey<int>(name: 'queued')), 2);
    await root.dispose();
  });

  test('an optional reader sees a publisher that the same reconciliation '
      'activates (G-RT-LC-002, Reconcile.tla SkipRecheck)', () async {
    final di = Scope(
      module: Module(
        components: [Component.value(value: 1, key: DiKey<int>(name: 'count'))],
      ),
    );
    final consumers = di.child(
      module: Module(
        components: [
          Component<String?>.effect(
            dependency: Dependency.maybe<String>(
              key: const DiKey(name: 'text'),
            ),
            debugLabel: 'watcher',
          ),
          Component<String>(
            dependency: Dependency.require<int>(
              key: const DiKey(name: 'count'),
            ).map((_) => 'ready'),
            key: DiKey<String>(name: 'text'),
          ),
        ],
      ),
    );
    // The watcher activates without the String; the producer waits.
    await consumers.initialize();
    expect(consumers.nodes.first.value, isNull);
    // The producer activates and publishes in the mutation of the root.
    await di.initialize();
    expect(consumers.get<String>(key: const DiKey(name: 'text')), 'ready');
    expect(consumers.nodes.first.value, 'ready');
    await di.dispose();
  });

  /// x reads K optionally and publishes L; y requires L and publishes K.
  /// With `outside`, x also requires a key that the parent publishes.
  List<ComponentBase> feedback(void Function() onRun, {DiKey<int>? outside}) {
    final k = DiKey<int>(name: 'K');
    final l = DiKey<int>(name: 'L');
    final optionalK = Dependency.maybe<int>(key: k);
    return [
      Component<int>(
        key: l,
        debugLabel: 'x',
        dependency: outside == null
            ? optionalK.map((v) {
                onRun();
                return (v ?? 0) + 1;
              })
            : (Dependency.require<int>(key: outside), optionalK).zip.mapN((
                _,
                v,
              ) {
                onRun();
                return (v ?? 0) + 1;
              }),
      ),
      Component<int>(
        key: k,
        debugLabel: 'y',
        dependency: Dependency.require<int>(key: l).map((v) => v + 1),
      ),
    ];
  }

  test('optional feedback among the members fails initialize', () async {
    var runs = 0;
    final di = Scope(module: Module(components: feedback(() => runs++)));
    final errors = <DiException>[];
    final subscription = di.errors.listen(errors.add);
    await expectLater(
      di.initialize(),
      throwsA(
        isA<DependencyCycleError>().having((e) => e.passes, 'passes', 3).having(
          (e) => e.path,
          'path',
          ['x'],
        ),
      ),
    );
    // Two nodes allow three passes, so x runs a bounded number of times.
    expect(runs, lessThanOrEqualTo(4));
    expect(di.isInitialized, isFalse, reason: 'the call rolls back');
    expect(di.maybeGet<int>(key: DiKey<int>(name: 'L')), isNull);
    await Future<void>.delayed(Duration.zero);
    expect(errors, isEmpty, reason: 'the caller receives the error');
    await subscription.cancel();
    await di.dispose();
  });

  test('optional feedback in a woken child is reported, and the parent '
      'initializes', () async {
    final outside = DiKey<int>(name: 'outside');
    final root = Scope(
      module: Module(components: [Component.value(value: 0, key: outside)]),
    );
    final child = root.child(
      module: Module(components: feedback(() {}, outside: outside)),
    );
    final errors = <DiException>[];
    final subscription = root.errors.listen(errors.add);
    await child.initialize(); // x waits for the parent's key
    await root.initialize(); // wakes x and y, which do not settle
    await Future<void>.delayed(Duration.zero);
    expect(root.isInitialized, isTrue);
    expect(errors, [
      isA<ActivationException>().having(
        (e) => e.cause,
        'cause',
        isA<DependencyCycleError>().having(
          (e) => e.passes,
          'passes',
          isNotNull,
        ),
      ),
    ]);
    await subscription.cancel();
    await root.dispose();
  });

  test('a throwing automatic activation is attempted once per '
      'reconciliation and again on a later mutation', () async {
    final root = Scope(
      module: Module(
        components: [Component.value(value: 1, key: DiKey<int>(name: 'count'))],
      ),
    );
    var attempts = 0;
    final consumers = root.child(
      module: Module(
        components: [
          Component<String>(
            key: DiKey<String>(name: 'text'),
            dependency: Dependency.require<int>(key: const DiKey(name: 'count'))
                .map((_) {
                  attempts++;
                  if (attempts == 1) throw StateError('first attempt');
                  return 'ok';
                }),
          ),
        ],
      ),
    );
    final errors = <DiException>[];
    final subscription = root.errors.listen(errors.add);
    await consumers.initialize(); // waits for the int
    await root.initialize(); // wakes the consumer, which throws
    await Future<void>.delayed(Duration.zero);
    expect(attempts, 1, reason: 'one attempt in that reconciliation');
    expect(root.isInitialized, isTrue, reason: 'the mutation succeeds');
    expect(errors.single, isA<ActivationException>());
    expect(consumers.maybeGet<String>(key: const DiKey(name: 'text')), isNull);

    // A later mutation reconciles again, and the consumer activates.
    await root.child().initialize();
    expect(attempts, 2);
    expect(consumers.get<String>(key: const DiKey(name: 'text')), 'ok');
    await subscription.cancel();
    await root.dispose();
  });

  test('a disposed consumer does not activate again when its publisher '
      'leaves and a new one arrives (V-T-RT-LC-003)', () async {
    final key = DiKey<int>(name: 'value');
    final root = Scope(
      module: Module(components: [Component.value(value: 1, key: key)]),
    );
    // Declared between the root and the consumer; initialized later, it
    // brings a new publisher of the key.
    final mid = root.child(
      module: Module(components: [Component.value(value: 2, key: key)]),
    );
    var creations = 0;
    final consumers = mid.child(
      module: Module(
        components: [
          Component<int>(
            key: DiKey<int>(name: 'consumer'),
            dependency: Dependency.require<int>(key: key).map((v) {
              creations++;
              return v;
            }),
          ),
        ],
      ),
    );
    await root.initialize();
    await consumers.initialize();
    expect(creations, 1);

    await consumers.nodes.single.dispose();
    // The publisher leaves, and a nearer one arrives.
    await root.node(key: key).dispose();
    await mid.initialize();
    expect(creations, 1, reason: 'a disposed member never activates again');
    expect(consumers.maybeGet<int>(key: DiKey<int>(name: 'consumer')), isNull);
    await root.dispose();
  });
}
