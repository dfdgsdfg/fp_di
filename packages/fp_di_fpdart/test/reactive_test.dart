import 'dart:async';

import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

const version = DiKey<int>(name: 'version');
const count = DiKey<int>(name: 'count');
const text = DiKey<String>(name: 'text');
const reader = DiKey<int>(name: 'reader');

/// An effect that reads [key], counts its activations, and gives the value.
Component<int> counting(DiKey<int> key, List<int> seen, {String? label}) =>
    Component<int>.effect(
      debugLabel: label,
      dependency: Dependency.require<int>(key: key).map<int>((value) {
        seen.add(value);
        return value;
      }),
    );

void main() {
  group('reactive publisher lifecycle', () {
    test(
      'publisher removal deactivates and later replacement reactivates',
      () async {
        // from: core_test.dart: publisher removal deactivates and later
        // replacement reactivates
        final root = Scope(
          components: [Component<int>.value(value: 1, key: version)],
        );
        // The pending scope sits between the dependent and the first publisher.
        final replacement = root.kid(
          components: [Component<int>.value(value: 2, key: version)],
        );
        final seen = <int>[];
        final leaf = replacement.kid(components: [counting(version, seen)]);
        rightOf(await root.run());
        rightOf(await leaf.run());
        final first = root.nodes.single;
        final dependent = leaf.nodes.single;
        expect(rightOf(dependent.value), 1);

        rightOf(await first.dispose());
        expect(dependent.isActive, isFalse);
        expect(dependent.state.phase, NodePhase.waiting);
        rightOf(await replacement.run());
        expect(dependent.isActive, isTrue);
        expect(rightOf(dependent.value), 2);
        expect(seen, [1, 2]);
        rightOf(await root.dispose());
      },
    );

    test('a nearer binding reloads dependents by publisher identity', () async {
      // from: core_test.dart: a nearer binding reloads dependents by
      // publisher identity
      final root = Scope(
        components: [Component<int>.value(value: 1, key: version)],
      );
      final mid = root.kid(
        components: [Component<int>.value(value: 2, key: version)],
      );
      final leaf = mid.kid(components: [counting(version, [])]);
      rightOf(await root.run());
      rightOf(await leaf.run());
      final dependent = leaf.nodes.single;
      expect(rightOf(dependent.value), 1);

      rightOf(await mid.run());
      final local = mid.nodes.single;
      expect(rightOf(dependent.value), 2);
      expect(dependent.state.commits, 2);
      rightOf(await local.dispose());
      expect(rightOf(dependent.value), 1);
      expect(dependent.state.commits, 3);
      rightOf(await root.dispose());
    });

    test('a node that nothing changed keeps its value', () async {
      final seen = <int>[];
      final root = Scope(
        components: [Component<int>.value(value: 1, key: version)],
      );
      final sibling = root.kid(
        components: [Component<int>.value(value: 5, key: count)],
      );
      final leaf = root.kid(components: [counting(version, seen)]);
      rightOf(await root.run());
      rightOf(await leaf.run());
      rightOf(await sibling.run());
      rightOf(await sibling.nodes.single.dispose());
      expect(seen, [1], reason: 'the target of the reader did not change');
      expect(leaf.nodes.single.state.commits, 1);
      rightOf(await root.dispose());
    });

    test('cleanup failure blocks automatic reacquisition', () async {
      // from: core_test.dart: cleanup failure blocks automatic reacquisition
      final root = Scope(
        components: [Component<int>.value(value: 1, key: count)],
      );
      final mid = root.kid(
        components: [Component<int>.value(value: 2, key: count)],
      );
      var activations = 0;
      final leaf = mid.kid(
        components: [
          Component<int>.effect(
            dependency: Dependency.require<int>(key: count).map<int>(
              (_) => ++activations,
              dispose: (_) => throw StateError('not released'),
            ),
          ),
        ],
      );
      rightOf(await root.run());
      rightOf(await leaf.run());
      final publisher = root.nodes.single;
      final dependent = leaf.nodes.single;

      expect(leftOf(await publisher.dispose()).defects, hasLength(1));
      rightOf(await mid.run());
      expect(dependent.isActive, isFalse);
      expect(dependent.state.phase, NodePhase.disposeFailed);
      expect(activations, 1);

      // A blocked node leaves only by its removal, which has nothing to
      // release.
      rightOf(await dependent.dispose());
      expect(dependent.state.phase, NodePhase.disposed);
      rightOf(await root.dispose());
    });

    test(
      'a dependent cleanup failure does not block the publisher reload',
      () async {
        // from: regression_test.dart: a dependent cleanup failure does not
        // block the publisher reload
        const trigger = DiKey<int>(name: 'trigger');
        final root = Scope(
          components: [Component<int>.value(value: 0, key: trigger)],
        );
        // The pending scope supplies the second trigger after the first leaves.
        final mid = root.kid(
          components: [Component<int>.value(value: 1, key: trigger)],
        );
        var publisherActivations = 0;
        final leaf = mid.kid(
          components: [
            Component<String>(
              key: text,
              debugLabel: 'publisher',
              dependency: Dependency.require<int>(key: trigger).map<String>((
                _,
              ) {
                publisherActivations++;
                return 'service';
              }),
            ),
            Component<int>.effect(
              debugLabel: 'dependent',
              dependency: Dependency.require<String>(key: text).map<int>(
                (_) => 1,
                dispose: (_) => throw StateError('dependent cleanup failed'),
              ),
            ),
          ],
        );
        rightOf(await root.run());
        rightOf(await leaf.run());
        final first = root.nodes.single;
        final [publisher, dependent] = leaf.nodes;

        expect(leftOf(await first.dispose()).defects, hasLength(1));
        expect(publisher.isActive, isFalse);
        expect(dependent.isActive, isFalse);

        // The publisher's own releases all succeeded, so only the dependent is
        // barred from reacquiring.
        rightOf(await mid.run());
        expect(publisher.isActive, isTrue);
        expect(publisherActivations, 2);
        expect(dependent.state.phase, NodePhase.disposeFailed);

        rightOf(await dependent.dispose());
        rightOf(await publisher.dispose());
        rightOf(await root.dispose());
      },
    );

    test('a component whose own cleanup fails stays blocked', () async {
      // from: regression_test.dart: a component whose own cleanup fails stays
      // blocked
      final root = Scope(
        components: [Component<int>.value(value: 1, key: count)],
      );
      final mid = root.kid(
        components: [Component<int>.value(value: 2, key: count)],
      );
      var activations = 0;
      final leaf = mid.kid(
        components: [
          Component<int>.effect(
            dependency: Dependency.require<int>(key: count).map<int>(
              (_) => ++activations,
              dispose: (_) => throw StateError('own cleanup failed'),
            ),
          ),
        ],
      );
      rightOf(await root.run());
      rightOf(await leaf.run());
      final first = root.nodes.single;
      final node = leaf.nodes.single;

      expect(leftOf(await first.dispose()).defects, hasLength(1));
      rightOf(await mid.run());
      expect(node.isActive, isFalse);
      expect(activations, 1);

      rightOf(await node.dispose());
      rightOf(await root.dispose());
    });

    test('a disposed consumer does not activate again when its publisher '
        'leaves and a new one arrives', () async {
      // from: regression_test.dart: a disposed consumer does not activate
      // again when its publisher leaves and a new one arrives
      // (V-T-RT-LC-003)
      final root = Scope(
        components: [Component<int>.value(value: 1, key: version)],
      );
      // Declared between the root and the consumer, it brings a new publisher
      // of the key when it runs.
      final mid = root.kid(
        components: [Component<int>.value(value: 2, key: version)],
      );
      final seen = <int>[];
      final consumers = mid.kid(
        components: [
          Component<int>(
            key: reader,
            dependency: Dependency.require<int>(key: version).map<int>((v) {
              seen.add(v);
              return v;
            }),
          ),
        ],
      );
      rightOf(await root.run());
      rightOf(await consumers.run());
      expect(seen, [1]);

      rightOf(await consumers.nodes.single.dispose());
      // The publisher leaves, and a nearer one arrives.
      rightOf(await rightOf(root.node<int>(key: version)).dispose());
      rightOf(await mid.run());
      expect(seen, [1], reason: 'a disposed member never activates again');
      expect(consumers.getOption<int>(key: reader), isA<None>());
      expect(consumers.nodes.single.state.phase, NodePhase.disposed);
      rightOf(await root.dispose());
    });
  });

  group('reconciliation', () {
    test('an optional reader sees a publisher that the same reconciliation '
        'activates', () async {
      // from: regression_test.dart: an optional reader sees a publisher that
      // the same reconciliation activates (G-RT-LC-002, Reconcile.tla
      // SkipRecheck)
      final root = Scope(
        components: [Component<int>.value(value: 1, key: count)],
      );
      final consumers = root.kid(
        components: [
          Component<Option<String>>.effect(
            debugLabel: 'watcher',
            dependency: Dependency.option<String>(key: text),
          ),
          Component<String>(
            key: text,
            dependency: Dependency.require<int>(
              key: count,
            ).map<String>((_) => 'ready'),
          ),
        ],
      );
      // The watcher activates without the String. The producer waits.
      rightOf(await consumers.run());
      final watcher = consumers.nodes.first;
      expect(rightOf(watcher.value), isA<None>());
      // The producer activates and publishes in the run of the root.
      rightOf(await root.run());
      expect(rightOf(consumers.get<String>(key: text)), 'ready');
      expect(rightOf(watcher.value), const Some('ready'));
      rightOf(await root.dispose());
    });

    test('optional feedback in a woken child is reported, and the parent '
        'runs', () async {
      // from: regression_test.dart: optional feedback in a woken child is
      // reported, and the parent initializes
      const k = DiKey<int>(name: 'K');
      const l = DiKey<int>(name: 'L');
      final root = Scope(
        components: [Component<int>.value(value: 0, key: count)],
      );
      final child = root.kid(
        components: [
          Component<int>(
            key: l,
            debugLabel: 'x',
            dependency: (
              Dependency.require<int>(key: count),
              Dependency.option<int>(key: k),
            ).zip.mapN<int>((_, v) => v.getOrElse(() => 0) + 1),
          ),
          Component<int>(
            key: k,
            debugLabel: 'y',
            dependency: Dependency.require<int>(key: l).map<int>((v) => v + 1),
          ),
        ],
      );
      final errors = <Cause<DiFailure>>[];
      final subscription = root.errors.listen(errors.add);
      rightOf(await child.run()); // x waits for the key of the parent
      rightOf(await root.run()); // wakes x and y, which do not settle
      await pause(1);
      expect(root.isInitialized, isTrue);
      expect(errors, hasLength(1));
      expect(errors.single.failures.single, isA<UnsettledFailure>());
      await subscription.cancel();
      rightOf(await root.dispose());
    });

    test('a throwing automatic activation is attempted once per '
        'reconciliation and again on a later mutation', () async {
      // from: regression_test.dart: a throwing automatic activation is
      // attempted once per reconciliation and again on a later mutation
      final root = Scope(
        components: [Component<int>.value(value: 1, key: count)],
      );
      var attempts = 0;
      final consumers = root.kid(
        components: [
          Component<String>(
            key: text,
            dependency: Dependency.require<int>(key: count).map<String>((_) {
              attempts++;
              if (attempts == 1) throw StateError('first attempt');
              return 'ok';
            }),
          ),
        ],
      );
      final errors = <Cause<DiFailure>>[];
      final subscription = root.errors.listen(errors.add);
      rightOf(await consumers.run()); // waits for the int
      rightOf(await root.run()); // wakes the consumer, which throws
      await pause(1);
      expect(attempts, 1, reason: 'one attempt in that reconciliation');
      expect(root.isInitialized, isTrue, reason: 'the mutation succeeds');
      expect(errors.single.failures.single, isA<ActivationFailure>());
      expect(consumers.getOption<String>(key: text), isA<None>());
      final node = consumers.nodes.single;
      expect(node.state.phase, NodePhase.activationFailed);
      expect(node.activationFailure.isSome(), isTrue);

      // A later mutation reconciles again, and the consumer activates.
      rightOf(await rightOf(root.child()).run());
      expect(attempts, 2);
      expect(rightOf(consumers.get<String>(key: text)), 'ok');
      expect(node.activationFailure.isNone(), isTrue);
      await subscription.cancel();
      rightOf(await root.dispose());
    });

    test('a failing member of the run is the failure of the run, and no '
        'report', () async {
      final root = Scope(
        components: [Component<int>.value(value: 1, key: count)],
      );
      final errors = <Cause<DiFailure>>[];
      final subscription = root.errors.listen(errors.add);
      final child = root.kid(
        components: [
          Component<String>(
            key: text,
            dependency: Dependency.require<int>(
              key: count,
            ).map<String>((_) => throw StateError('boom')),
          ),
        ],
      );
      rightOf(await root.run());
      // The member activates in the run of the child, because `count`
      // resolves at once. The failure goes to the caller.
      final cause = leftOf(await child.run());
      expect(cause.only, isA<ActivationFailure>());
      expect(child.phase, ScopePhase.declared);
      await pause(1);
      expect(errors, isEmpty);
      await subscription.cancel();
      rightOf(await root.dispose());
    });
  });

  group('withdrawal', () {
    test('disposing a publisher cancels an in-flight reader, which waits for '
        'the withdrawal and then reads the fallback', () async {
      // from: cancellation_test.dart: disposing a publisher cancels an
      // in-flight reader, which waits for the withdrawal and then reads the
      // fallback (CancelPropagatesToDependents, NoCancelLivelock)
      final gate = Completer<void>();
      final seen = <int>[];
      final root = Scope(
        components: [Component<int>.value(value: 2, key: count)],
      );
      final mid = root.kid(
        components: [Component<int>.value(value: 1, key: count)],
      );
      final child = mid.kid(
        components: [
          Component<int>(
            key: reader,
            dependency: Dependency.require<int>(key: count).mapTask<int>(
              (v) => Task(() async {
                seen.add(v);
                await gate.future;
                return v;
              }),
            ),
          ),
        ],
      );
      rightOf(await root.run());
      rightOf(await mid.run());
      final setup = child.run();
      await pause(1);
      expect(seen, [1], reason: 'the reader started with the nearer value');

      final withdrawal = rightOf(mid.node<int>(key: count)).dispose();
      gate.complete();
      // The reader is canceled, rolls back, and stays inactive: the run
      // succeeds without committing the departing value.
      rightOf(await setup);
      rightOf(await withdrawal);
      // The withdrawal reconciles: the reader activates with the fallback.
      expect(rightOf(child.get<int>(key: reader)), 2, reason: 'the fallback');
      expect(seen, [1, 2]);
      rightOf(await root.dispose());
    });

    test(
      'a reader of an active dependent of the publisher is canceled too',
      () async {
        // from: cancellation_test.dart: a reader of an active dependent of the
        // publisher is canceled too
        final gate = Completer<void>();
        final root = Scope(
          components: [Component<int>.value(value: 1, key: version)],
        );
        const doubled = DiKey<int>(name: 'doubled');
        final mid = root.kid(
          components: [
            Component<int>(
              key: doubled,
              dependency: Dependency.require<int>(
                key: version,
              ).map<int>((v) => v * 2),
            ),
          ],
        );
        var runs = 0;
        final child = mid.kid(
          components: [
            Component<int>(
              key: reader,
              dependency: Dependency.require<int>(key: doubled).mapTask<int>(
                (v) => Task(() async {
                  runs++;
                  await gate.future;
                  return v;
                }),
              ),
            ),
          ],
        );
        rightOf(await root.run());
        rightOf(await mid.run());
        final setup = child.run();
        await pause(1);
        final withdrawal = rightOf(root.node<int>(key: version)).dispose();
        gate.complete();
        rightOf(await setup);
        rightOf(await withdrawal);
        expect(runs, 1, reason: 'canceled, and waiting without a value');
        expect(child.nodes.single.missing, [doubled]);
        rightOf(await root.dispose());
      },
    );

    test('a withdrawal cancel reports the late release failure of the reader '
        'to errors, and the reader activates after the withdrawal', () async {
      // from: cancellation_test.dart: withdrawal cancel: the late release
      // failure of the reader goes to errors, the release failure of the
      // publisher to both dispose callers, and the reader activates again
      // after the withdrawal (RecipientsExact, NoReactivateBeforeWithdrawal)
      final gate = Completer<void>();
      final log = <String>[];
      final pubError = StateError('publisher release failed');
      final lateError = StateError('late release failed');
      final root = Scope(
        components: [
          Component<int>(
            key: version,
            dependency: Dependency<int>(
              create: () => 1,
              dispose: (_) {
                log.add('release publisher');
                throw pubError;
              },
            ),
          ),
        ],
      );
      final child = root.kid(
        components: [
          Component<int>(
            key: reader,
            dependency: Dependency.option<int>(key: version).mapTask<int>(
              (v) => Task(() async {
                log.add('create reader ${v.match(() => 'fallback', (x) => x)}');
                await gate.future;
                return v.getOrElse(() => -1);
              }),
              dispose: (_) {
                log.add('release reader');
                throw lateError;
              },
            ),
          ),
        ],
      );
      rightOf(await root.run());
      final errors = <Cause<DiFailure>>[];
      final subscription = root.errors.listen(errors.add);
      final setup = child.run();
      await pause(1);
      expect(log, ['create reader 1']);

      final publisher = rightOf(root.node<int>(key: version));
      final first = publisher.dispose();
      final second = publisher.dispose();
      gate.complete();

      rightOf(await setup); // the withdrawn reader stays inactive
      final one = leftOf(await first);
      final two = leftOf(await second);
      await pause(1);

      expect(identical(first, second), isTrue, reason: 'one shared result');
      expect(two, same(one));
      expect(one.defects.map((d) => (d as DisposeFailure).error), [
        pubError,
      ], reason: 'only the publisher release; not the late one of the reader');
      expect(errors, hasLength(1));
      expect(errors.single.defects.map((d) => (d as DisposeFailure).error), [
        lateError,
      ], reason: 'the late release of the reader reaches errors');
      expect(log, [
        'create reader 1',
        'release reader',
        'release publisher',
        'create reader fallback',
      ], reason: 'the reader reactivates only after the publisher released');
      expect(rightOf(child.get<int>(key: reader)), -1, reason: 'the fallback');
      await subscription.cancel();
      // The reactivated reader releases and fails again; not under test.
      leftOf(await root.dispose());
    });
  });

  group('node dispose', () {
    test('is idempotent and never fails for a disposed scope', () async {
      final root = Scope(
        components: [Component<int>.value(value: 1, key: version)],
      );
      rightOf(await root.run());
      final node = root.nodes.single;
      rightOf(await node.dispose());
      rightOf(await node.dispose());
      expect(node.state.phase, NodePhase.disposed);
      expect(node.isActive, isFalse);
      expect(leftOf(node.value), isA<InactiveNodeFailure>());
      rightOf(await root.dispose());
      rightOf(await node.dispose());
    });

    test('shares one result between concurrent callers', () async {
      final log = <String>[];
      final root = Scope(
        components: [logged<int>('a', 1, log, key: version, failDispose: 'x')],
      );
      rightOf(await root.run());
      final node = root.nodes.single;
      final first = node.dispose();
      final second = node.dispose();
      expect(identical(first, second), isTrue);
      expect(leftOf(await first).defects, hasLength(1));
      expect(log.where((l) => l == 'dispose a'), hasLength(1));
      rightOf(await node.dispose());
      rightOf(await root.dispose());
    });

    test('releases the dependents first, while the value is alive', () async {
      // from: core_test.dart: a dependent releases first while its publisher
      // value is still alive
      final events = <String>[];
      final root = Scope(
        components: [
          logged<int>('publisher', 1, events, key: version),
          Component<int>.effect(
            debugLabel: 'dependent',
            dependency: Dependency.require<int>(key: version).map<int>(
              (v) => v,
              dispose: (v) => events.add('dispose dependent sees $v'),
            ),
          ),
        ],
      );
      rightOf(await root.run());
      events.clear();
      rightOf(await root.nodes.first.dispose());
      expect(events, ['dispose dependent sees 1', 'dispose publisher']);
      expect(root.nodes.last.state.phase, NodePhase.waiting);
      expect(root.nodes.last.missing, [version]);
      rightOf(await root.dispose());
    });

    test('an activation of the node in flight is canceled', () async {
      final gate = Completer<void>();
      final log = <String>[];
      final root = Scope(
        components: [
          Component<int>(
            key: version,
            dependency: Dependency<int>(
              create: () async {
                await gate.future;
                return 1;
              },
              dispose: (_) => log.add('dispose'),
            ),
          ),
        ],
      );
      final run = root.run();
      await pause(1);
      // The nodes are visible in the state while the run runs.
      final node = root.findNode<int>(key: version).toNullable()!;
      expect(node.state.phase, NodePhase.activating);
      final disposal = node.dispose();
      gate.complete();
      expect(leftOf(await run).isInterrupted, isTrue);
      rightOf(await disposal);
      expect(log, ['dispose']);
      expect(node.state.phase, NodePhase.disposed);
      rightOf(await root.dispose());
    });
  });

  group('shadowing', () {
    test(
      'a nearer scope that runs later takes over from the farther one',
      () async {
        // The case of inventory 9.3.
        final seen = <int>[];
        final root = Scope(
          components: [Component<int>.value(value: 1, key: version)],
        );
        final nearer = root.kid(
          components: [Component<int>.value(value: 2, key: version)],
        );
        final leaf = nearer.kid(components: [counting(version, seen)]);
        rightOf(await root.run());
        rightOf(await leaf.run());
        expect(seen, [1]);
        rightOf(await nearer.run());
        expect(seen, [1, 2]);
        expect(rightOf(root.get<int>(key: version)), 1);
        expect(rightOf(nearer.get<int>(key: version)), 2);
        expect(rightOf(leaf.get<int>(key: version)), 2);
        rightOf(await root.dispose());
      },
    );

    test(
      'a node that began its release lets the lookup fall through',
      () async {
        // from: observation_test.dart: prefers the node whose value get returns
        final gate = Completer<void>();
        final root = Scope(
          components: [Component<int>.value(value: 1, key: version)],
        );
        final nearer = root.kid(
          components: [
            Component<int>(
              key: version,
              dependency: Dependency<int>(
                create: () => 2,
                dispose: (_) => gate.future,
              ),
            ),
          ],
        );
        rightOf(await root.run());
        rightOf(await nearer.run());
        expect(rightOf(nearer.get<int>(key: version)), 2);
        final disposal = nearer.nodes.single.dispose();
        await pause(1);
        // The nearer node releases: its key does not resolve any more.
        expect(rightOf(nearer.get<int>(key: version)), 1);
        expect(
          nearer.findNode<int>(key: version).toNullable(),
          root.nodes.single,
        );
        gate.complete();
        rightOf(await disposal);
        rightOf(await root.dispose());
      },
    );
  });

  group('rules of a run', () {
    test(
      'a child of a scope that is not run still takes the key later',
      () async {
        // from: core_test.dart: accepts a key that an uninitialized ancestor
        // declares
        final parent = Scope(
          components: [Component<int>.value(value: 1, key: version)],
        );
        final child = parent.kid(components: [counting(version, [])]);
        rightOf(await child.run());
        expect(child.nodes.single.state.phase, NodePhase.waiting);
        expect(parent.phase, ScopePhase.declared);
        rightOf(await parent.run());
        expect(child.nodes.single.isActive, isTrue);
        rightOf(await parent.dispose());
      },
    );

    test('a failed run leaves the nodes below waiting, and a retry wakes '
        'them', () async {
      // from: core_test.dart: a failed initialize binds nothing and a retry
      // can succeed
      var failing = true;
      final producers = Scope(
        components: [
          Component<int>.value(value: 1, key: version),
          Component<String>(
            key: text,
            dependency: Dependency.require<int>(
              key: version,
            ).map<String>((_) => failing ? throw StateError('boom') : 'ok'),
          ),
        ],
      );
      final seen = <int>[];
      final consumers = producers.kid(components: [counting(version, seen)]);
      rightOf(await consumers.run());
      expect(consumers.nodes.single.state.phase, NodePhase.waiting);
      expect(leftOf(await producers.run()).only, isA<ActivationFailure>());
      expect(producers.phase, ScopePhase.declared);
      expect(consumers.nodes.single.state.phase, NodePhase.waiting);
      expect(seen, isEmpty);
      failing = false;
      rightOf(await producers.run());
      expect(rightOf(producers.get<String>(key: text)), 'ok');
      expect(consumers.nodes.single.isActive, isTrue);
      expect(seen, [1]);
      rightOf(await producers.dispose());
    });
  });
}
