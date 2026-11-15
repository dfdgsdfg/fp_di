import 'dart:async';

import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

const count = DiKey<int>(name: 'count');
const text = DiKey<String>(name: 'text');

/// Publishes [value] under `count`.
Component<int> number(int value) =>
    Component<int>.value(value: value, debugLabel: 'number', key: count);

/// Reads `count` and publishes a text built from it.
Component<String> label() => Component<String>(
  debugLabel: 'text',
  key: text,
  dependency: Dependency.require<int>(
    key: count,
  ).map<String>((value) => 'v$value'),
);

/// The text of `describe`, or a test failure.
String described(Scope scope) => rightOf(scope.describe());

void main() {
  group('structural sharing', () {
    test('two reads with no transition between them are one object', () async {
      // from: runtime_state_test.dart: each listener is called once at each
      // transition, in order
      final root = Scope(components: [number(1)]);
      final child = root.kid(components: [label()]);
      rightOf(await root.run());
      rightOf(await child.run());
      expect(identical(root.state, root.state), isTrue);
      expect(identical(child.state, child.state), isTrue);
      expect(identical(root.state.childStates.first, child.state), isTrue);
      expect(
        identical(root.nodes.single.state, root.state.nodeStates.single),
        isTrue,
      );
      expect(
        identical(child.nodes.single.state, child.state.nodeStates.single),
        isTrue,
      );
      rightOf(await root.dispose());
    });

    test('a transition keeps the objects that it does not change', () async {
      // from: runtime_state_test.dart: a transition keeps the objects that it
      // does not change
      final gate = Completer<void>();
      final root = Scope(
        components: [
          Component<int>(
            key: count,
            dependency: Dependency<int>(
              create: () async {
                await gate.future;
                return 1;
              },
            ),
          ),
          Component<String>.value(key: text, value: 't'),
        ],
      );
      final sibling = root.kid(
        components: [
          Component<bool>.value(
            key: const DiKey<bool>(name: 'flag'),
            value: true,
          ),
        ],
      );
      rightOf(await sibling.run());
      final states = <ScopeState>[];
      rightOf(root.addListener(() => states.add(root.state)));
      final done = root.run();
      await pause(1);
      final beforeCommit = root.state;
      expect(beforeCommit.nodeStates[0].phase, NodePhase.activating);
      expect(beforeCommit.nodeStates[1].phase, NodePhase.active);
      gate.complete();
      rightOf(await done);
      // The first value after the gate shows the commit of the first member.
      final afterCommit = states[states.indexOf(beforeCommit) + 1];
      expect(afterCommit.nodeStates[0].phase, NodePhase.active);
      expect(identical(afterCommit, beforeCommit), isFalse);
      expect(
        identical(afterCommit.nodeStates[1], beforeCommit.nodeStates[1]),
        isTrue,
      );
      expect(
        identical(
          afterCommit.childStates.single,
          beforeCommit.childStates.single,
        ),
        isTrue,
      );
      expect(identical(afterCommit.childStates.single, sibling.state), isTrue);
      rightOf(await root.dispose());
    });

    test('a scope that did not change keeps its object across a change of '
        'the other scopes', () async {
      final root = Scope(components: [number(1)]);
      final one = root.kid(components: [label()]);
      final two = root.kid();
      rightOf(await root.run());
      rightOf(await one.run());
      final before = one.state;
      final revision = root.revision;
      rightOf(await two.run());
      expect(root.revision, greaterThan(revision));
      expect(identical(one.state, before), isTrue);
      expect(identical(root.state.childStates.first, before), isTrue);
      expect(identical(root.state.childStates.last, two.state), isTrue);
      rightOf(await root.dispose());
    });

    test('a node state is equal by value', () async {
      // from: runtime_state_test.dart: a node state is equal by value
      Scope make() => Scope(components: [number(1)]);
      final one = make();
      final other = make();
      rightOf(await one.run());
      rightOf(await other.run());
      // Two roots number their nodes from zero.
      expect(one.state, other.state);
      expect(one.state.hashCode, other.state.hashCode);
      expect(one.state.nodeStates.single, other.state.nodeStates.single);
      expect(identical(one.state, other.state), isFalse);
      rightOf(await other.dispose());
      expect(one.state, isNot(other.state));
      rightOf(await one.dispose());
    });

    test('a read of a disposed scope still answers, and a disposed child '
        'leaves the state of its parent', () async {
      // from: runtime_state_test.dart: the indexes of the state do not keep a
      // disposed scope
      final root = Scope(components: []);
      rightOf(await root.run());
      for (var i = 0; i < 5; i++) {
        final session = root.kid(components: [number(i), label()]);
        rightOf(await session.run());
        expect(rightOf(session.get<int>(key: count)), i);
        rightOf(await session.dispose());
        expect(session.state.phase, ScopePhase.disposed);
      }
      expect(root.state.childStates, isEmpty);
      rightOf(await root.dispose());
    });

    test(
      'the state of a node that a failed run removed is not shared',
      () async {
        var failing = true;
        final root = Scope(
          components: [
            Component<int>(
              key: count,
              dependency: Dependency<int>(
                create: () => failing ? throw StateError('boom') : 1,
              ),
            ),
          ],
        );
        leftOf(await root.run());
        expect(root.state.nodeStates, isEmpty);
        failing = false;
        rightOf(await root.run());
        expect(root.nodes.single.state, root.state.nodeStates.single);
        expect(
          identical(root.nodes.single.state, root.state.nodeStates.single),
          isTrue,
        );
        rightOf(await root.dispose());
      },
    );
  });

  group('changedSince', () {
    test('pairs a created node and a node that left', () async {
      // from: runtime_state_test.dart: changedSince pairs a created node and a
      // node that left
      final root = Scope(components: []);
      rightOf(await root.run());
      final empty = root.state;
      final child = root.kid(components: [number(1)]);
      rightOf(await child.run());
      final created = root.state.changedSince(empty);
      expect(created, hasLength(1));
      expect(created.single.$1, isNull);
      expect(created.single.$2!.phase, NodePhase.active);

      final full = root.state;
      rightOf(await child.dispose());
      final left = root.state.changedSince(full);
      expect(left, hasLength(1));
      expect(left.single.$1!.phase, NodePhase.active);
      expect(left.single.$2, isNull);
      rightOf(await root.dispose());
    });

    test('the same object has no change', () async {
      final root = Scope(components: [number(1)]);
      rightOf(await root.run());
      final state = root.state;
      expect(state.changedSince(state), isEmpty);
      expect(root.state.changedSince(state), isEmpty);
      rightOf(await root.dispose());
    });

    test('pairs the publisher, the reader, and the waiting node of a '
        'release', () async {
      // from: runtime_state_test.dart: withdraws the keys in the transition
      // that starts it
      final gate = Completer<void>();
      const k1 = DiKey<int>(name: 'k1');
      const k2 = DiKey<int>(name: 'k2');
      final root = Scope(
        components: [
          Component<int>(
            key: k1,
            dependency: Dependency<int>(
              create: () => 1,
              dispose: (_) => gate.future,
            ),
          ),
          Component<int>.value(key: k2, value: 2),
        ],
      );
      final mid = root.kid(
        components: [
          Component<int>(
            key: const DiKey<int>(name: 'v'),
            dependency: Dependency.require<int>(key: k1).map<int>((v) => v),
          ),
          Component<int>(
            key: const DiKey<int>(name: 'n'),
            dependency: (
              Dependency.require<int>(key: k1),
              Dependency.require<int>(key: k2),
            ).zip.mapN<int>((x, y) => x + y),
          ),
        ],
      );
      // A child that publishes one of the two keys itself.
      final leaf = mid.kid(
        components: [Component<int>.value(key: k1, value: 9)],
      );
      rightOf(await root.run());
      rightOf(await mid.run());
      rightOf(await leaf.run());
      final publisher = rightOf(root.node<int>(key: k1));
      final reader = mid.nodes[0];
      final waiting = mid.nodes[1];
      rightOf(await rightOf(root.node<int>(key: k2)).dispose());

      final before = root.state;
      final gone = publisher.dispose();
      await pause(1);
      final during = root.state;
      final pairs = during.changedSince(before);
      expect(pairs.map((pair) => pair.$2!.id).toSet(), {
        publisher.state.id,
        reader.state.id,
        waiting.state.id,
      });
      for (final (earlier, later) in pairs) {
        expect(earlier, isNotNull);
        expect(earlier, isNot(later));
        expect(earlier!.id, later!.id);
      }
      expect(during.changedSince(during), isEmpty);
      // The scope that publishes the key itself did not change.
      expect(
        identical(
          during.childStates.single.childStates.single,
          before.childStates.single.childStates.single,
        ),
        isTrue,
      );
      gate.complete();
      rightOf(await gone);
      rightOf(await root.dispose());
    });

    test('lists the pairs of the later value first, then the nodes that '
        'left', () async {
      final root = Scope(components: [number(1)]);
      final child = root.kid(components: [label()]);
      rightOf(await root.run());
      rightOf(await child.run());
      final before = root.state;
      // The child leaves, and a new scope adds a node.
      rightOf(await child.dispose());
      final other = root.kid(
        components: [
          Component<bool>.value(
            key: const DiKey<bool>(name: 'flag'),
            value: true,
          ),
        ],
      );
      rightOf(await other.run());
      final pairs = root.state.changedSince(before);
      expect(pairs.map((p) => (p.$1?.phase, p.$2?.phase)), [
        (null, NodePhase.active),
        (NodePhase.active, null),
      ]);
      rightOf(await root.dispose());
    });
  });

  group('states', () {
    test('emits after each round that changed the scope, and closes at the '
        'disposal', () async {
      final root = Scope(components: [number(1)]);
      final child = root.kid(components: [label()]);
      rightOf(await root.run());
      final seen = <ScopeState>[];
      var closed = false;
      final subscription = child.states.listen(
        seen.add,
        onDone: () => closed = true,
      );
      await pause(1);
      expect(seen, isEmpty, reason: 'no event for the state at the start');
      // A change of the root that leaves the child as it was: no event.
      rightOf(await rightOf(root.child()).run());
      await pause(1);
      expect(seen, isEmpty);
      rightOf(await child.run());
      await pause(1);
      expect(seen.map((s) => s.phase).toSet(), {
        ScopePhase.initializing,
        ScopePhase.initialized,
      });
      expect(seen.last.phase, ScopePhase.initialized);
      // An event holds the state of its round, and no two events repeat.
      for (var i = 1; i < seen.length; i++) {
        expect(identical(seen[i], seen[i - 1]), isFalse);
      }
      rightOf(await child.dispose());
      await pause(1);
      expect(seen.last.phase, ScopePhase.disposed);
      expect(closed, isTrue);
      await subscription.cancel();
      rightOf(await root.dispose());
    });

    test('a scope hears the change of a descendant', () async {
      final root = Scope(components: []);
      final child = root.kid();
      rightOf(await root.run());
      final seen = <ScopeState>[];
      final subscription = root.states.listen(seen.add);
      rightOf(await child.run());
      await pause(1);
      expect(seen, isNotEmpty);
      expect(seen.last.childStates.single.phase, ScopePhase.initialized);
      await subscription.cancel();
      rightOf(await root.dispose());
    });

    test('a canceled subscription removes its listener', () async {
      final root = Scope(components: []);
      final seen = <ScopeState>[];
      final subscription = root.states.listen(seen.add);
      await pause(1);
      await subscription.cancel();
      rightOf(await root.run());
      await pause(1);
      expect(seen, isEmpty);
      rightOf(await root.dispose());
    });

    test('the stream of a disposed scope is empty and closed', () async {
      final root = Scope(components: []);
      rightOf(await root.dispose());
      expect(await root.states.toList(), isEmpty);
    });
  });

  group('missing', () {
    test('lists missing keys while inactive and is empty after', () async {
      // from: observation_test.dart: lists missing keys while inactive and is
      // empty after
      const ratio = DiKey<double>(name: 'ratio');
      final di = Scope(components: []);
      final ints = di.kid(components: [number(1)]);
      final doubles = ints.kid(
        components: [Component<double>.value(value: 2.0, key: ratio)],
      );
      final consumer = doubles.kid(
        components: [
          Component<double>.effect(
            debugLabel: 'pair',
            dependency: (
              Dependency.require<int>(key: count),
              Dependency.require<double>(key: ratio),
            ).zip.mapN<double>((i, d) => i + d),
          ),
        ],
      );
      rightOf(await consumer.run());
      final pair = consumer.nodes.single;
      expect(pair.missing, [count, ratio]);
      expect(
        () => pair.missing.add(const DiKey<bool>()),
        throwsUnsupportedError,
      );

      rightOf(await ints.run());
      expect(pair.missing, [ratio]);

      rightOf(await doubles.run());
      expect(pair.isActive, isTrue);
      expect(pair.missing, isEmpty);

      rightOf(await pair.dispose());
      expect(pair.missing, isEmpty);
      rightOf(await di.dispose());
    });

    test('matches InactiveNodeFailure.missing', () async {
      // The parent declares the int key but never runs, so the text waits.
      // from: observation_test.dart: matches InactiveNodeException.missing
      final pending = Scope(components: [number(1)]);
      final di = pending.kid(components: [label()]);
      rightOf(await di.run());
      final node = di.nodes.single;
      final failure = leftOf(node.value) as InactiveNodeFailure;
      expect(failure.missing, node.missing);
      expect(failure.missing, [count]);
      rightOf(await pending.dispose());
    });
  });

  group('describe', () {
    test('labels a node by its key unless it has a debugLabel', () async {
      // from: observation_test.dart: labels a node by its key unless it has a
      // debugLabel
      final di = Scope(
        components: [
          Component<int>.value(key: const DiKey<int>(name: 'port'), value: 1),
          Component<int>.effect(dependency: Dependency<int>.of(2)),
          Component<bool>.value(
            key: const DiKey<bool>(name: 'enabled'),
            value: true,
            debugLabel: 'flag',
          ),
        ],
      );
      rightOf(await di.run());
      final lines = described(di).split('\n');
      expect(lines[1], '  - DiKey<int>(port): active');
      expect(lines[2], matches(RegExp(r'^  - effect<int>#\d+: active$')));
      expect(lines[3], '  - flag (DiKey<bool>(enabled)): active');
      expect(di.nodes.first.toString(), isNotEmpty);
      rightOf(await di.dispose());
    });

    test('lists nodes and child scopes with their state', () async {
      // The outer scope declares the bool key but never runs, so `flagged`
      // waits.
      // from: observation_test.dart: lists nodes and child scopes with their
      // state
      const enabled = DiKey<bool>(name: 'enabled');
      const flag = DiKey<String>(name: 'flag');
      final outer = Scope(
        components: [Component<bool>.value(value: true, key: enabled)],
      );
      final di = outer.kid(
        components: [
          Component<String>.value(
            value: 'hi',
            debugLabel: 'greeting',
            key: const DiKey<String>(name: 'greeting'),
          ),
          number(1),
        ],
      );
      final child = di.kid(
        components: [
          Component<String>(
            key: flag,
            debugLabel: 'flagged',
            dependency: Dependency.require<bool>(
              key: enabled,
            ).map<String>((flag) => '$flag'),
          ),
          Component<int>.effect(
            debugLabel: 'twice',
            dependency: Dependency.require<int>(
              key: count,
            ).map<int>((v) => v * 2),
          ),
        ],
      );
      rightOf(await di.run());
      rightOf(await child.run());

      expect(
        described(di),
        [
          'scope',
          '  - greeting (DiKey<String>(greeting)): active',
          '  - number (DiKey<int>(count)): active',
          '  child scope 1',
          '    - flagged (DiKey<String>(flag)): waiting; '
              'missing DiKey<bool>(enabled)',
          '    - twice: active',
        ].join('\n'),
      );
      expect(
        described(child),
        startsWith('scope\n  - flagged (DiKey<String>(flag)): waiting'),
      );
      rightOf(await outer.dispose());
    });

    test('numbers the children with a path', () async {
      final root = Scope(components: []);
      final one = root.kid();
      root.kid();
      one.kid();
      one.kid();
      expect(
        described(root),
        [
          'scope (not initialized)',
          '  child scope 1 (not initialized)',
          '    child scope 1.1 (not initialized)',
          '    child scope 1.2 (not initialized)',
          '  child scope 2 (not initialized)',
        ].join('\n'),
      );
    });

    test('lists declared components before the run', () async {
      // from: observation_test.dart: lists declared components before
      // initialize
      final di = Scope(components: [number(1), label()]);
      expect(
        described(di),
        [
          'scope (not initialized)',
          '  - number (DiKey<int>(count)): declared',
          '  - text (DiKey<String>(text)): declared',
        ].join('\n'),
      );

      rightOf(await di.run());
      expect(
        described(di),
        [
          'scope',
          '  - number (DiKey<int>(count)): active',
          '  - text (DiKey<String>(text)): active',
        ].join('\n'),
      );
      rightOf(await di.dispose());
    });

    test('names a dispose-failed and an activation-failed node', () async {
      // from: observation_test.dart: names a dispose-failed and an
      // activation-failed node
      final di = Scope(components: [number(1)]);
      final errors = <Cause<DiFailure>>[];
      final subscription = di.errors.listen(errors.add);
      // `later` sits between the publisher and the leaf. It runs after the
      // publisher is withdrawn.
      final later = di.kid(components: [number(2)]);
      final leaf = later.kid(
        components: [
          // Dormant until the first number appears, so its activation fails
          // automatically.
          Component<int>.effect(
            debugLabel: 'failing',
            dependency: Dependency.require<int>(
              key: count,
            ).map<int>((_) => throw StateError('boom')),
          ),
          Component<int>.effect(
            debugLabel: 'brittle',
            dependency: Dependency.require<int>(
              key: count,
            ).map<int>((v) => v, dispose: (_) => throw StateError('release')),
          ),
        ],
      );
      rightOf(await leaf.run());
      rightOf(await di.run());
      expect(leftOf(await di.nodes.single.dispose()).defects, hasLength(1));
      rightOf(await later.run());

      final report = described(leaf);
      expect(report, contains('  - brittle: dispose failed'));
      expect(report, contains('  - failing: activation failed'));
      expect(leaf.nodes.map((node) => node.state.phase), [
        NodePhase.activationFailed,
        NodePhase.disposeFailed,
      ]);
      expect(
        errors.map((cause) => cause.failures.single),
        everyElement(isA<ActivationFailure>()),
      );
      await subscription.cancel();
      rightOf(await di.dispose());
    });

    test('lists each component once while the run runs', () async {
      // from: observation_test.dart: lists each component once while
      // initialize runs
      final gate = Completer<void>();
      final di = Scope(
        components: [
          number(1),
          Component<int>.effect(
            debugLabel: 'slow',
            dependency: Dependency.require<int>(key: count).mapTask<int>(
              (v) => Task(() async {
                await gate.future;
                return v;
              }),
            ),
          ),
        ],
      );
      final pending = di.run();
      await pause(1);
      // The nodes exist, so no component is also listed as `declared`.
      expect(
        described(di),
        [
          'scope (not initialized)',
          '  - number (DiKey<int>(count)): active',
          '  - slow: activating',
        ].join('\n'),
      );

      gate.complete();
      rightOf(await pending);
      expect(
        described(di),
        [
          'scope',
          '  - number (DiKey<int>(count)): active',
          '  - slow: active',
        ].join('\n'),
      );
      rightOf(await di.dispose());
    });

    test('names a node activating while its setup is in flight', () async {
      // from: observation_test.dart: names a node activating while its setup
      // is in flight
      final gate = Completer<void>();
      var started = false;
      final di = Scope(components: [number(1)]);
      final child = di.kid(
        components: [
          Component<int>.effect(
            debugLabel: 'slow',
            dependency: Dependency.require<int>(key: count).mapTask<int>(
              (v) => Task(() async {
                started = true;
                await gate.future;
                return v;
              }),
            ),
          ),
        ],
      );
      // The reader waits, because the publisher is not run.
      rightOf(await child.run());
      expect(described(child), contains('  - slow: waiting'));
      final slow = child.nodes.single;
      expect(slow.state.phase, NodePhase.waiting);

      final setup = di.run();
      await pause(1);
      expect(started, isTrue);
      expect(described(child), contains('  - slow: activating'));
      expect(slow.state.phase, NodePhase.activating);

      gate.complete();
      rightOf(await setup);
      expect(described(child), contains('  - slow: active'));
      expect(slow.state.phase, NodePhase.active);
      rightOf(await di.dispose());
    });

    group('after a failed automatic activation', () {
      /// A child scope with a reader that throws while [nextFailure] is not 0.
      Scope failingChild(Scope parent, int Function() nextFailure) =>
          parent.kid(
            components: [
              Component<int>.effect(
                debugLabel: 'flaky',
                dependency: Dependency.require<int>(key: count).map<int>(
                  (v) => nextFailure() > 0 ? throw StateError('boom') : v,
                ),
              ),
            ],
          );

      test('a later successful attempt clears the failure', () async {
        // from: observation_test.dart: a later successful attempt clears the
        // failure
        var attempts = 0;
        final di = Scope(components: [number(1)]);
        final errors = <Cause<DiFailure>>[];
        final subscription = di.errors.listen(errors.add);
        final child = failingChild(di, () => attempts++ == 0 ? 1 : 0);
        rightOf(await child.run());
        rightOf(await di.run());
        expect(errors, hasLength(1));
        expect(described(child), contains('  - flaky: activation failed'));

        // A later mutation that reconciles makes the runtime try again.
        rightOf(await rightOf(di.child(components: [label()])).run());
        expect(attempts, 2);
        expect(described(child), contains('  - flaky: active'));
        await subscription.cancel();
        rightOf(await di.dispose());
      });

      test('a missing key outranks the past failure', () async {
        // from: observation_test.dart: a missing key outranks the past failure
        final di = Scope(components: [number(1)]);
        final subscription = di.errors.listen((_) {});
        final child = failingChild(di, () => 1);
        rightOf(await child.run());
        rightOf(await di.run());
        expect(described(child), contains('  - flaky: activation failed'));

        rightOf(await rightOf(di.node<int>(key: count)).dispose());
        final report = described(child);
        expect(
          report,
          contains('  - flaky: waiting; missing DiKey<int>(count)'),
        );
        expect(report, isNot(contains('activation failed')));
        await subscription.cancel();
        rightOf(await di.dispose());
      });
    });

    test('a disposed node has the state disposed and no entry', () async {
      // from: observation_test.dart: a disposed node has the state disposed
      // and no entry
      final di = Scope(components: [number(1)]);
      rightOf(await di.run());
      final node = di.nodes.single;
      expect(node.state.phase, NodePhase.active);
      expect(node.isActive, isTrue);

      rightOf(await node.dispose());
      expect(node.state.phase, NodePhase.disposed);
      expect(node.isActive, isFalse);
      expect(described(di), 'scope');
      rightOf(await di.dispose());
      // The node of a disposed scope is disposed, and the read does not fail.
      expect(node.state.phase, NodePhase.disposed);
    });

    test('rejects a disposed scope', () async {
      // from: observation_test.dart: rejects a disposed scope
      final di = Scope(components: []);
      final child = di.kid();
      rightOf(await child.dispose());
      expect(
        leftOf(child.describe()),
        isA<DisposedScopeFailure>().having(
          (f) => f.operation,
          'operation',
          'describe',
        ),
      );
      rightOf(await di.dispose());
    });
  });

  group('isDisposed', () {
    test('is true from the dispose call and stays true', () async {
      // from: observation_test.dart: is true from the dispose call and stays
      // true
      final gate = Completer<void>();
      final di = Scope(
        components: [
          Component<int>(
            key: count,
            dependency: Dependency<int>(
              create: () => 1,
              dispose: (_) => gate.future,
            ),
          ),
        ],
      );
      rightOf(await di.run());
      final child = di.kid();
      expect(di.isDisposed, isFalse);
      expect(child.isDisposed, isFalse);

      final disposal = di.dispose();
      // The disposal has not run, and both scopes already report it.
      expect(di.isDisposed, isTrue);
      expect(child.isDisposed, isTrue);
      await pause(1);
      // The release waits on the gate.
      expect(di.isDisposed, isTrue);

      gate.complete();
      rightOf(await disposal);
      expect(di.isDisposed, isTrue);
      expect(child.isDisposed, isTrue);
      expect(di.isInitialized, isTrue);
    });

    test('is false for a scope whose child is disposed', () async {
      // from: observation_test.dart: is false for a scope whose child is
      // disposed
      final di = Scope(components: []);
      final child = di.kid();
      rightOf(await child.dispose());
      expect(child.isDisposed, isTrue);
      expect(di.isDisposed, isFalse);
      rightOf(await di.dispose());
    });
  });

  group('activationFailure', () {
    Scope readerChild(Scope parent, int Function(int value) body) => parent.kid(
      components: [
        Component<int>.effect(
          debugLabel: 'reader',
          dependency: Dependency.require<int>(key: count).map<int>(body),
        ),
      ],
    );

    test('holds the failure that errors reported', () async {
      // from: observation_test.dart: holds the failure that errors reported
      final di = Scope(components: [number(1)]);
      final errors = <Cause<DiFailure>>[];
      final subscription = di.errors.listen(errors.add);
      final child = readerChild(di, (_) => throw StateError('boom'));
      rightOf(await child.run());
      final node = child.nodes.single;
      expect(node.activationFailure.isNone(), isTrue);

      rightOf(await di.run());
      expect(node.state.phase, NodePhase.activationFailed);
      final failure = node.activationFailure.toNullable()!;
      expect(failure, same(errors.single));
      expect((failure.only as ActivationFailure).error, isA<StateError>());
      // A second read returns the same failure.
      expect(node.activationFailure.toNullable(), same(failure));
      await subscription.cancel();
      rightOf(await di.dispose());
    });

    test('keeps a failure that no subscriber of errors received', () async {
      // from: observation_test.dart: keeps a failure that no listener of
      // errors received
      final di = Scope(components: [number(1)]);
      final child = readerChild(di, (_) => throw StateError('boom'));
      rightOf(await child.run());
      rightOf(await di.run());
      final failure = child.nodes.single.activationFailure.toNullable()!;
      expect((failure.only as ActivationFailure).error, isA<StateError>());
      rightOf(await di.dispose());
    });

    test('is none after a later successful activation', () async {
      // from: observation_test.dart: is null after a later successful
      // activation
      var attempts = 0;
      final di = Scope(components: [number(1)]);
      final child = readerChild(
        di,
        (v) => attempts++ == 0 ? throw StateError('boom') : v,
      );
      rightOf(await child.run());
      rightOf(await di.run());
      final node = child.nodes.single;
      expect(node.activationFailure.isSome(), isTrue);

      // A later mutation that reconciles makes the runtime try again.
      rightOf(await rightOf(di.child(components: [label()])).run());
      expect(node.state.phase, NodePhase.active);
      expect(node.activationFailure.isNone(), isTrue);
      rightOf(await di.dispose());
    });

    test('is none while the node waits for a key', () async {
      // from: observation_test.dart: is null while the node waits for a key
      final di = Scope(components: [number(1)]);
      final child = readerChild(di, (_) => throw StateError('boom'));
      rightOf(await child.run());
      rightOf(await di.run());
      final node = child.nodes.single;
      expect(node.activationFailure.isSome(), isTrue);

      rightOf(await rightOf(di.node<int>(key: count)).dispose());
      expect(node.state.phase, NodePhase.waiting);
      expect(node.activationFailure.isNone(), isTrue);
      rightOf(await di.dispose());
    });

    test('is none for a disposed node', () async {
      // from: observation_test.dart: is null for a disposed node
      final di = Scope(components: [number(1)]);
      final child = readerChild(di, (_) => throw StateError('boom'));
      rightOf(await child.run());
      rightOf(await di.run());
      final node = child.nodes.single;
      expect(node.activationFailure.isSome(), isTrue);

      rightOf(await node.dispose());
      expect(node.state.phase, NodePhase.disposed);
      expect(node.activationFailure.isNone(), isTrue);
      rightOf(await di.dispose());
    });
  });

  group('findNode', () {
    test('is none for a key that no node publishes', () async {
      // from: observation_test.dart: is null for a key that no node publishes
      final di = Scope(components: [number(1)]);
      rightOf(await di.run());
      expect(di.findNode<String>(key: text), isA<None>());
      expect(di.findNode<Object>(), isA<None>());
      rightOf(await di.dispose());
    });

    test('does not count a scope that is not run', () async {
      // from: observation_test.dart: does not count a scope that is not
      // initialized
      final di = Scope(components: [number(1)]);
      final child = di.kid();
      expect(di.findNode<int>(key: count), isA<None>());
      expect(child.findNode<int>(key: count), isA<None>());

      rightOf(await di.run());
      expect(rightOf(di.findNode<int>(key: count).toNullable()!.value), 1);
      expect(rightOf(child.findNode<int>(key: count).toNullable()!.value), 1);
      rightOf(await di.dispose());
    });

    test('returns a waiting node that get cannot read', () async {
      // from: observation_test.dart: returns a waiting node that get cannot
      // read
      final di = Scope(components: [number(1)]);
      final child = di.kid(components: [label()]);
      rightOf(await child.run());

      expect(child.getOption<String>(key: text), isA<None>());
      final node = child.findNode<String>(key: text).toNullable()!;
      expect(node.state.phase, NodePhase.waiting);
      expect(node.missing, [count]);
      // The parent does not see the node of its child.
      expect(di.findNode<String>(key: text), isA<None>());

      rightOf(await di.run());
      expect(node.state.phase, NodePhase.active);
      expect(
        rightOf(child.findNode<String>(key: text).toNullable()!.value),
        'v1',
      );
      rightOf(await di.dispose());
    });

    test('prefers the node whose value get returns', () async {
      // from: observation_test.dart: prefers the node whose value get
      // returns
      final di = Scope(components: [number(1)]);
      rightOf(await di.run());
      // `gap` declares the text key and stays not run, so the nearer
      // publisher of the count key waits.
      final gap = di.kid(
        components: [Component<String>.value(value: 't', key: text)],
      );
      final child = gap.kid(
        components: [
          Component<int>(
            key: count,
            debugLabel: 'nearer',
            dependency: Dependency.require<String>(
              key: text,
            ).map<int>((value) => value.length),
          ),
        ],
      );
      rightOf(await child.run());

      expect(rightOf(child.get<int>(key: count)), 1);
      final far = child.findNode<int>(key: count).toNullable()!;
      expect(far.state.phase, NodePhase.active);
      expect(rightOf(far.value), 1);

      // Without an active publisher, the nearest node answers.
      rightOf(await rightOf(di.node<int>(key: count)).dispose());
      final near = child.findNode<int>(key: count).toNullable()!;
      expect(near.state.phase, NodePhase.waiting);
      expect(near.missing, [text]);
      rightOf(await di.dispose());
    });

    test('leads from a waiting node to the failure behind it', () async {
      // from: observation_test.dart: leads from a waiting node to the failure
      // behind it
      final di = Scope(components: [number(1)]);
      final child = di.kid(
        components: [
          Component<String>(
            key: text,
            dependency: Dependency.require<int>(
              key: count,
            ).map<String>((_) => throw StateError('boom')),
          ),
          Component<int>.effect(
            debugLabel: 'reader',
            dependency: Dependency.require<String>(
              key: text,
            ).map<int>((value) => value.length),
          ),
        ],
      );
      rightOf(await child.run());
      // No subscriber of `errors` exists when the activation fails.
      rightOf(await di.run());

      final reader = child.nodes.last;
      expect(reader.state.phase, NodePhase.waiting);
      final behind = [
        for (final key in reader.missing.whereType<DiKey<Object?>>())
          child.findNode<Object?>(key: key).toNullable(),
      ];
      expect(behind.single?.state.phase, NodePhase.activationFailed);
      final failure = behind.single!.activationFailure.toNullable()!;
      expect((failure.only as ActivationFailure).error, isA<StateError>());
      rightOf(await di.dispose());
    });

    test('does not count a member that was disposed alone', () async {
      // from: observation_test.dart: does not count a member that was
      // disposed alone
      final di = Scope(components: [number(1)]);
      rightOf(await di.run());
      final child = di.kid(components: [number(2)]);
      rightOf(await child.run());
      expect(rightOf(child.findNode<int>(key: count).toNullable()!.value), 2);

      rightOf(await rightOf(child.node<int>(key: count)).dispose());
      expect(rightOf(child.findNode<int>(key: count).toNullable()!.value), 1);
      rightOf(await rightOf(di.node<int>(key: count)).dispose());
      expect(child.findNode<int>(key: count), isA<None>());
      rightOf(await di.dispose());
    });

    test('returns the nodes of a scope while the run runs', () async {
      // from: observation_test.dart: returns the nodes of a scope while
      // initialize runs
      final gate = Completer<void>();
      final di = Scope(
        components: [
          number(1),
          Component<String>(
            key: text,
            dependency: Dependency<String>(
              create: () => gate.future.then((_) => 't'),
            ),
          ),
        ],
      );
      final initialization = di.run();
      await pause(1);

      expect(di.isInitialized, isFalse);
      expect(
        di.findNode<int>(key: count).toNullable()?.state.phase,
        NodePhase.active,
      );
      expect(
        di.findNode<String>(key: text).toNullable()?.state.phase,
        NodePhase.activating,
      );
      gate.complete();
      rightOf(await initialization);
      expect(rightOf(di.findNode<String>(key: text).toNullable()!.value), 't');
      rightOf(await di.dispose());
    });

    test('is none for a disposed scope', () async {
      // from: observation_test.dart: rejects a disposed scope
      final di = Scope(components: []);
      final child = di.kid();
      rightOf(await child.dispose());
      expect(child.findNode<int>(key: count), isA<None>());
      rightOf(await di.dispose());
    });
  });

  test('reads do not change the revision', () async {
    // from: observation_test.dart: reads do not change the revision
    final pending = Scope(components: [number(1)]);
    final di = pending.kid(components: [label()]);
    rightOf(await di.run());
    final node = di.nodes.single;
    final before = di.revision;
    di.describe();
    node.missing;
    node.state;
    node.activationFailure;
    di.state;
    di.findNode<String>(key: text);
    di.get<String>(key: text);
    di.isDisposed;
    unawaited(node.whenActive.run());
    expect(di.revision, before);
    rightOf(await pending.dispose());
  });

  group('cause of an unavailable key', () {
    const gate = DiKey<int>(name: 'gate');
    const first = DiKey<String>(name: 'first');
    const second = DiKey<String>(name: 'second');
    const third = DiKey<String>(name: 'third');
    const other = DiKey<int>(name: 'other');

    /// Reads [gate] and publishes [key]. Its `create` runs [body].
    Component<String> gated(DiKey<String> key, String Function() body) =>
        Component<String>(
          key: key,
          dependency: Dependency.require<int>(
            key: gate,
          ).map<String>((_) => body()),
        );

    /// Reads [from] and publishes [key].
    Component<String> behind(DiKey<String> key, DiKey<String> from) =>
        Component<String>(
          key: key,
          dependency: Dependency.require<String>(
            key: from,
          ).map<String>((value) => '$value>'),
        );

    /// A root scope that publishes [gate] and [other].
    Scope rootScope() => Scope(
      components: [
        Component<int>.value(value: 1, key: gate),
        Component<int>.value(value: 2, key: other),
      ],
    );

    /// The failure of `get` for [key]. `getOption` is none, and the revision
    /// of the runtime stays the same.
    UnavailableKeyFailure thrownBy(Scope scope, DiKey<String> key) {
      final before = scope.revision;
      final failure = leftOf(scope.get<String>(key: key));
      expect(scope.getOption<String>(key: key), isA<None>());
      expect(scope.revision, before);
      return failure as UnavailableKeyFailure;
    }

    test('holds the failed node of each key behind a failure', () async {
      // from: observation_test.dart: holds the failed node of each key behind
      // a failure
      final root = Scope(
        components: [Component<int>.value(value: 1, key: gate)],
      );
      final child = root.kid(
        components: [
          gated(first, () => throw StateError('boom')),
          behind(second, first),
          behind(third, second),
        ],
      );
      rightOf(await child.run());
      // Before the root runs, each node only waits.
      final waitsFor = <DiKey<String>, DiKey<Object?>>{
        first: gate,
        second: first,
        third: second,
      };
      for (final MapEntry(:key, value: missing) in waitsFor.entries) {
        final waiting = thrownBy(child, key);
        expect(waiting.failedNodeStates, isEmpty);
        expect(waiting.message, contains('waits for $missing'));
      }

      final errors = <Cause<DiFailure>>[];
      final subscription = root.errors.listen(errors.add);
      rightOf(await root.run());
      final node = child.findNode<String>(key: first).toNullable()!;
      expect(node.state.phase, NodePhase.activationFailed);
      for (final key in [first, second, third]) {
        final error = thrownBy(child, key);
        expect(error.key, key);
        final failed = error.failedNodeStates.single;
        expect(failed.phase, NodePhase.activationFailed);
        expect(failed.key, Some(first));
        expect(
          identical(
            failed.activationFailure.toNullable(),
            node.activationFailure.toNullable(),
          ),
          isTrue,
        );
        expect(error.message, contains('boom'));
        expect(child.getOption<String>(key: key), isA<None>());
      }
      await subscription.cancel();
      rightOf(await root.dispose());
    });

    test('holds two failed nodes in the order of the missing keys', () async {
      // from: observation_test.dart: holds two failed nodes in the order of
      // the missing keys
      const both = DiKey<String>(name: 'both');
      final root = rootScope();
      final child = root.kid(
        components: [
          gated(first, () => throw StateError('one')),
          gated(second, () => throw ArgumentError('two')),
          Component<String>(
            key: both,
            dependency: (
              Dependency.require<String>(key: first),
              Dependency.require<String>(key: second),
            ).zip.mapN<String>((a, b) => '$a$b'),
          ),
        ],
      );
      rightOf(await child.run());
      final subscription = root.errors.listen((_) {});
      rightOf(await root.run());
      final error = thrownBy(child, both);
      expect(error.failedNodeStates.map((state) => state.key), [
        Some(first),
        Some(second),
      ]);
      final causes = [
        for (final state in error.failedNodeStates)
          (state.activationFailure.toNullable()!.only as ActivationFailure)
              .error,
      ];
      expect(causes.first, isStateError);
      expect(causes.last, isArgumentError);
      expect(error.message, contains('one'));
      expect(error.message, contains('1 more failed'));
      expect(error.message, isNot(contains('two')));
      await subscription.cancel();
      rightOf(await root.dispose());
    });

    test(
      'is empty without a publisher and differs for a declared key',
      () async {
        // from: observation_test.dart: is empty without a publisher and differs
        // for a declared key
        final root = rootScope();
        final child = root.kid(
          components: [gated(first, () => throw StateError('boom'))],
        );
        final declared = root.kid(
          components: [Component<String>.value(value: 'x', key: second)],
        );
        rightOf(await child.run());
        final subscription = root.errors.listen((_) {});
        rightOf(await root.run());
        expect(declared.state.phase, ScopePhase.declared);

        final none = thrownBy(child, third);
        final notInitialized = thrownBy(declared, second);
        expect(none.key, third);
        expect(none.failedNodeStates, isEmpty);
        expect(notInitialized.key, second);
        expect(notInitialized.failedNodeStates, isEmpty);
        expect(none.message, isNot(equals(notInitialized.message)));
        expect(notInitialized.message, contains('not initialized'));
        expect(none.message, isNot(contains('not initialized')));
        await subscription.cancel();
        rightOf(await root.dispose());
      },
    );

    test('gives the same failed nodes from a child of the child', () async {
      // from: observation_test.dart: gives the same failed nodes from a child
      // of the child
      final root = rootScope();
      final child = root.kid(
        components: [
          gated(first, () => throw StateError('boom')),
          behind(second, first),
        ],
      );
      rightOf(await child.run());
      final grandchild = child.kid();
      rightOf(await grandchild.run());
      final subscription = root.errors.listen((_) {});
      rightOf(await root.run());
      for (final key in [first, second]) {
        final fromChild = thrownBy(child, key);
        final fromGrandchild = thrownBy(grandchild, key);
        expect(fromChild.failedNodeStates, hasLength(1));
        expect(fromGrandchild.failedNodeStates, fromChild.failedNodeStates);
        expect(fromGrandchild.message, fromChild.message);
      }
      await subscription.cancel();
      rightOf(await root.dispose());
    });

    test('is empty for a node that waits for a disposed root member', () async {
      // from: observation_test.dart: is empty for a node that waits for a
      // disposed root member
      final root = rootScope();
      final child = root.kid(
        components: [
          Component<String>(
            key: first,
            dependency: Dependency.require<int>(
              key: other,
            ).map<String>((value) => 'v$value'),
          ),
        ],
      );
      rightOf(await child.run());
      rightOf(await root.run());
      expect(rightOf(child.node<String>(key: first)).isActive, isTrue);

      rightOf(await rightOf(root.node<int>(key: other)).dispose());
      final error = thrownBy(child, first);
      expect(error.failedNodeStates, isEmpty);
      expect(error.message, contains('waits for $other'));
      rightOf(await root.dispose());
    });

    test('returns the value again after the runtime retries', () async {
      // from: observation_test.dart: returns the value again after the
      // runtime retries
      var failing = true;
      final root = rootScope();
      final child = root.kid(
        components: [
          gated(first, () => failing ? throw StateError('boom') : 'ok'),
          behind(second, first),
          behind(third, second),
        ],
      );
      rightOf(await child.run());
      final subscription = root.errors.listen((_) {});
      rightOf(await root.run());
      expect(thrownBy(child, third).failedNodeStates, hasLength(1));

      failing = false;
      rightOf(
        await rightOf(
          root.child(
            components: [
              Component<int>.value(
                value: 3,
                key: const DiKey<int>(name: 'spare'),
              ),
            ],
          ),
        ).run(),
      );
      expect(rightOf(child.get<String>(key: first)), 'ok');
      expect(rightOf(child.get<String>(key: second)), 'ok>');
      expect(rightOf(child.get<String>(key: third)), 'ok>>');
      await subscription.cancel();
      rightOf(await root.dispose());
    });

    test('searches a chain of 500 waiting nodes in linear time', () async {
      // from: observation_test.dart: searches a chain of 2000 waiting nodes in
      // linear time
      const length = 500;
      final keys = [
        for (var i = 0; i < length; i++) DiKey<String>(name: 'c$i'),
      ];
      final root = rootScope();
      final chain = root.kid(
        components: [
          gated(keys.first, () => throw StateError('boom')),
          for (var i = 1; i < length; i++) behind(keys[i], keys[i - 1]),
        ],
      );
      rightOf(await chain.run());
      final subscription = root.errors.listen((_) {});
      rightOf(await root.run());

      final watch = Stopwatch()..start();
      for (var i = 0; i < 20; i++) {
        expect(thrownBy(chain, keys.last).failedNodeStates, hasLength(1));
      }
      watch.stop();
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      await subscription.cancel();
      rightOf(await root.dispose());
    });

    test('getWhenAvailable fails with the failed nodes', () async {
      // from: get_when_available_test.dart: fails with the cause when an
      // automatic activation fails
      final parent = Scope(
        components: [Component<String>.value(key: text, value: 'x')],
      );
      const b = DiKey<String>(name: 'b');
      final child = parent.kid(
        components: [
          Component<String>(
            key: b,
            dependency: Dependency.require<String>(
              key: text,
            ).map<String>((_) => throw StateError('broken')),
          ),
        ],
      );
      final errors = <Cause<DiFailure>>[];
      final subscription = parent.errors.listen(errors.add);
      rightOf(await child.run());
      final result = child.getWhenAvailable<String>(key: b).run();
      await pause(1);

      rightOf(await parent.run());
      final error = leftOf(await result) as UnavailableKeyFailure;
      final failed = error.failedNodeStates;
      expect(failed, hasLength(1));
      expect(failed.single.key, Some(b));
      expect(
        (failed.single.activationFailure.toNullable()!.only
                as ActivationFailure)
            .error,
        isA<StateError>(),
      );
      await subscription.cancel();
      rightOf(await parent.dispose());
    });

    test(
      'getWhenAvailable fails when the node of the key is disposed alone',
      () async {
        // from: get_when_available_test.dart: fails when the node of the key is
        // disposed alone
        const gone = DiKey<String>(name: 'gone');
        const b = DiKey<String>(name: 'b');
        final declares = Scope(
          components: [Component<String>.value(key: gone, value: 'g')],
        );
        final inner = declares.kid(
          components: [
            Component<String>(
              key: b,
              dependency: Dependency.require<String>(
                key: gone,
              ).map<String>((v) => '$v!'),
            ),
          ],
        );
        rightOf(await inner.run());
        final result = inner.getWhenAvailable<String>(key: b).run();
        await pause(1);
        rightOf(await rightOf(inner.node<String>(key: b)).dispose());
        expect(
          leftOf(await result),
          isA<UnavailableKeyFailure>().having((f) => f.key, 'key', b),
        );
        rightOf(await declares.dispose());
      },
    );

    test('getWhenAvailable fails when the node of the key is in '
        'disposeFailed', () async {
      // from: get_when_available_test.dart: fails when the node of the key is
      // in disposeFailed
      const gone = DiKey<String>(name: 'gone');
      const b = DiKey<String>(name: 'b');
      final parent = Scope(
        components: [
          Component<String>.value(key: text, value: 'x'),
          Component<String>.value(key: gone, value: 'g'),
        ],
      );
      final child = parent.kid(
        components: [
          Component<String>(
            key: b,
            dependency: Dependency.require<String>(key: gone).map<String>(
              (v) => '$v!',
              dispose: (_) => throw StateError('stuck'),
            ),
          ),
        ],
      );
      final subscription = parent.errors.listen((_) {});
      rightOf(await parent.run());
      rightOf(await child.run());
      expect(rightOf(child.get<String>(key: b)), 'g!');

      // Withdraw the key that the node reads: its release fails.
      leftOf(await rightOf(parent.node<String>(key: gone)).dispose());
      await pause(1);
      expect(
        child.findNode<String>(key: b).toNullable()?.state.phase,
        NodePhase.disposeFailed,
      );
      final error = await child.getWhenAvailable<String>(key: b).run();
      expect(leftOf(error), isA<UnavailableKeyFailure>());
      await subscription.cancel();
      rightOf(await parent.dispose());
    });
  });
}
