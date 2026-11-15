import 'dart:async';

import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

const a = DiKey<int>(name: 'a');
const b = DiKey<int>(name: 'b');
const c = DiKey<int>(name: 'c');

/// A listener on [scope] that keeps the state of [root] at each call.
final class Recorder {
  Recorder(this.root, Scope scope) {
    rightOf(scope.addListener(call));
  }

  final Scope root;
  final List<ScopeState> values = [];
  final List<int> revisions = [];

  void call() {
    values.add(root.state);
    revisions.add(root.revision);
  }
}

/// [items] without an item that equals the item before it.
List<T> runs<T>(Iterable<T> items) {
  final result = <T>[];
  for (final item in items) {
    if (result.isEmpty || result.last != item) result.add(item);
  }
  return result;
}

Component<int> number(DiKey<int> key, int value) =>
    Component<int>.value(key: key, value: value);

Component<int> reading(DiKey<int> key, DiKey<int> from) => Component<int>(
  key: key,
  dependency: Dependency.require<int>(key: from).map<int>((v) => v + 1),
);

void main() {
  group('transitions and listener calls', () {
    test('each listener is called once at each transition, in order', () async {
      // from: runtime_state_test.dart: each listener is called once at each
      // transition, in order
      final root = Scope(components: [number(a, 1)]);
      final onRoot = Recorder(root, root);
      final before = root.revision;
      final child = root.kid(components: [reading(b, a)]);
      // The creation of a child scope is a transition.
      expect(root.revision, before + 1);
      expect(root.state.childStates.single.phase, ScopePhase.declared);
      final onChild = Recorder(root, child);
      final grandchild = child.kid(components: [reading(c, b)]);
      final sibling = root.kid();
      final onGrandchild = Recorder(root, grandchild);
      final onSibling = Recorder(root, sibling);

      rightOf(await grandchild.run());
      // The value of the root holds the child of a scope that is `declared`.
      expect(root.state.childStates.first.phase, ScopePhase.declared);
      expect(
        root.state.childStates.first.childStates.single.phase,
        ScopePhase.initialized,
      );
      rightOf(await root.run());
      rightOf(await child.run());
      rightOf(await sibling.run());
      expect(rightOf(grandchild.get<int>(key: c)), 3);
      expect(root.revision, root.revision, reason: 'a read leaves it');

      rightOf(await root.dispose());

      final recorders = [onRoot, onChild, onGrandchild, onSibling];
      for (final recorder in recorders) {
        expect(recorder.revisions, isNotEmpty);
        for (var i = 1; i < recorder.revisions.length; i++) {
          expect(recorder.revisions[i], recorder.revisions[i - 1] + 1);
        }
      }
      // The listener of the root is called for every transition.
      expect(onRoot.revisions.first, before + 1);
      expect(onRoot.revisions.last, root.revision);
      // Each listener of one transition reads the same value.
      for (final recorder in recorders.skip(1)) {
        for (var i = 0; i < recorder.revisions.length; i++) {
          final at = onRoot.revisions.indexOf(recorder.revisions[i]);
          expect(onRoot.values[at], recorder.values[i]);
        }
      }
      // The listeners of a disposed scope leave after its transition.
      expect(onGrandchild.revisions.last, lessThan(onChild.revisions.last));
      expect(onChild.revisions.last, lessThan(onRoot.revisions.last));
    });

    test('a read of the state does not change the revision', () async {
      // from: runtime_state_test.dart: reads of the state do not change the
      // revision
      final root = Scope(components: [number(a, 1)]);
      rightOf(await root.run());
      final before = root.revision;
      root.state;
      root.nodes.single.state;
      root.findNode<int>(key: a);
      root.get<int>(key: a);
      root.node<int>(key: a);
      expect(root.nodes.single.value.isRight(), isTrue);
      expect(root.revision, before);
      rightOf(await root.dispose());
    });

    test('a state is equal by value', () async {
      // from: runtime_state_test.dart: a node state is equal by value
      final root = Scope(components: [number(a, 1), reading(b, a)]);
      rightOf(await root.run());
      expect(root.state, root.state);
      expect(root.state.nodeStates[0], root.nodes[0].state);
      expect(root.state.nodeStates[0], isNot(root.state.nodeStates[1]));
      expect(root.state.hashCode, root.state.hashCode);
      rightOf(await root.dispose());
    });
  });

  group('phases', () {
    test('a scope is declared, initializing, and initialized', () async {
      // from: runtime_state_test.dart: a scope is declared, initializing, and
      // initialized
      final root = Scope(components: [number(a, 1), reading(b, a)]);
      expect(root.state.phase, ScopePhase.declared);
      expect(root.state.nodeStates, isEmpty);
      final recorder = Recorder(root, root);
      rightOf(await root.run());
      expect(runs(recorder.values.map((value) => value.phase)), [
        ScopePhase.initializing,
        ScopePhase.initialized,
      ]);
      // The first value of `initializing` has one state for each component.
      expect(recorder.values.first.nodeStates, hasLength(2));
      expect(recorder.values.first.nodeStates[0].phase, NodePhase.inactive);
      expect(recorder.values.first.nodeStates[1].phase, NodePhase.waiting);
      expect(root.nodes, hasLength(2));
      for (var i = 0; i < 2; i++) {
        expect(root.nodes[i].state, root.state.nodeStates[i]);
      }
    });

    test('a failed run returns the scope to declared', () async {
      // from: runtime_state_test.dart: a failed initialize returns the scope
      // to declared
      final gate = Completer<void>();
      final root = Scope(
        components: [
          Component<int>(
            key: a,
            dependency: Dependency<int>(create: () => throw StateError('boom')),
          ),
          Component<int>(
            key: b,
            dependency: Dependency<int>(
              create: () async {
                await gate.future;
                return 1;
              },
            ),
          ),
        ],
      );
      final recorder = Recorder(root, root);
      final done = root.run();
      await pause(1);
      // The failed member keeps `activating` while its sibling settles.
      expect(root.state.phase, ScopePhase.initializing);
      expect(root.state.nodeStates[0].phase, NodePhase.activating);
      expect(root.state.nodeStates[1].phase, NodePhase.activating);
      gate.complete();
      final cause = leftOf(await done);
      expect(cause.only, isA<ActivationFailure>());
      expect(runs(recorder.values.map((value) => value.phase)), [
        ScopePhase.initializing,
        ScopePhase.declared,
      ]);
      expect(root.state.nodeStates, isEmpty);
      expect(root.isInitialized, isFalse);
      final failed = [
        for (final value in recorder.values)
          if (value.nodeStates.isNotEmpty) value.nodeStates[0],
      ];
      expect(runs(failed.map((node) => node.phase)), [
        NodePhase.inactive,
        NodePhase.activating,
        NodePhase.disposed,
      ]);
      // No node holds the failure: the caller of `run` has it.
      expect(
        failed.map((node) => node.activationFailure),
        everyElement(isA<None>()),
      );
      // A later call can retry.
      expect(root.isDisposed, isFalse);
    });

    test('a node goes through its phases, and commits count', () async {
      // from: runtime_state_test.dart: a node goes through its phases, and
      // commits count
      final createGate = Completer<void>();
      final disposeGate = Completer<void>();
      final root = Scope(
        components: [
          Component<int>(
            key: a,
            dependency: Dependency<int>(
              create: () async {
                await createGate.future;
                return 1;
              },
              dispose: (_) => disposeGate.future,
            ),
          ),
        ],
      );
      final child = root.kid(components: [reading(b, a)]);
      rightOf(await child.run());
      final reader = child.nodes.single;
      expect(reader.state.phase, NodePhase.waiting);
      expect(reader.state.missing, [a]);
      expect(reader.state.commits, 0);

      final recorder = Recorder(root, root);
      final done = root.run();
      await pause(1);
      createGate.complete();
      rightOf(await done);
      final publisher = root.nodes.single;
      final gone = publisher.dispose();
      await pause(1);
      disposeGate.complete();
      rightOf(await gone);

      final ofPublisher = [
        for (final value in recorder.values) value.nodeStates.single,
      ];
      expect(runs(ofPublisher.map((node) => node.phase)), [
        NodePhase.inactive,
        NodePhase.activating,
        NodePhase.active,
        NodePhase.deactivating,
        NodePhase.disposed,
      ]);
      final ofReader = [
        for (final value in recorder.values)
          value.childStates.single.nodeStates.single,
      ];
      expect(runs(ofReader.map((node) => node.phase)), [
        NodePhase.waiting,
        NodePhase.inactive,
        NodePhase.activating,
        NodePhase.active,
        NodePhase.deactivating,
        NodePhase.waiting,
      ]);
      // The number of commits increases by one at a commit, and at no other
      // transition.
      for (final states in [ofPublisher, ofReader]) {
        expect(states.first.commits, 0);
        for (var i = 1; i < states.length; i++) {
          final committed =
              states[i].phase == NodePhase.active &&
              states[i - 1].phase != NodePhase.active;
          expect(
            states[i].commits,
            states[i - 1].commits + (committed ? 1 : 0),
          );
        }
        expect(states.last.commits, 1);
      }
      // `missing` is empty only in the phases `active` and `disposed`.
      for (final node in ofReader) {
        if (node.phase == NodePhase.active) expect(node.missing, isEmpty);
        if (node.phase == NodePhase.waiting) expect(node.missing, isNotEmpty);
      }
    });

    test('a rebuilt node commits again under the same id', () async {
      // from: runtime_state_test.dart: a rebuilt node commits again under the
      // same id
      final root = Scope(components: [number(a, 1)]);
      rightOf(await root.run());
      final mid = root.kid(components: [number(a, 2)]);
      final leaf = mid.kid(components: [reading(b, a)]);
      rightOf(await leaf.run());
      final reader = leaf.nodes.single;
      final first = reader.state;
      expect(first.commits, 1);
      expect(rightOf(reader.value), 2);
      rightOf(await mid.run());
      expect(rightOf(reader.value), 3);
      expect(reader.state.commits, 2);
      expect(reader.state.id, first.id);
      expect(reader.state, isNot(first));
    });

    test('labels and keys are those of the component', () async {
      // from: runtime_state_test.dart: labels and keys are those of describe
      final root = Scope(
        components: [
          number(a, 1),
          Component<int>(
            debugLabel: 'named',
            dependency: Dependency<int>.of(2),
          ),
          Component<int>.effect(dependency: Dependency<int>.of(3)),
          Component<int>.effect(
            debugLabel: 'watcher',
            dependency: Dependency<int>.of(4),
          ),
        ],
      );
      rightOf(await root.run());
      final states = root.state.nodeStates;
      expect(states[0].label, '$a');
      expect(states[0].key, Some(a));
      expect(states[1].label, 'named');
      expect(states[2].label, startsWith('effect<int>#'));
      expect(states[2].key.isNone(), isTrue);
      expect(states[3].label, 'watcher');
      rightOf(await root.dispose());
    });
  });

  group('failures', () {
    test(
      'an automatic activation failure is in the state, then in errors',
      () async {
        // from: runtime_state_test.dart: an automatic activation failure is in
        // the state, then in errors
        final root = Scope(components: []);
        rightOf(await root.run());
        final mid = root.kid(components: [number(a, 1)]);
        final leaf = mid.kid(
          components: [
            Component<int>(
              key: b,
              dependency: Dependency.option<int>(key: a).map<int>(
                (o) => o.match(() => 1, (_) => throw StateError('boom')),
              ),
            ),
          ],
        );
        rightOf(await leaf.run());
        final reader = leaf.nodes.single;
        expect(reader.state.phase, NodePhase.active);

        final onRoot = Recorder(root, root);
        final onLeaf = Recorder(root, leaf);
        final reported = <Cause<DiFailure>>[];
        // What each listener had kept last when the subscriber ran.
        final seenAtReport = <NodeState>[];
        root.errors.listen((error) {
          reported.add(error);
          for (final recorder in [onRoot, onLeaf]) {
            expect(recorder.revisions.last, root.revision);
            seenAtReport.add(
              recorder
                  .values
                  .last
                  .childStates
                  .single
                  .childStates
                  .single
                  .nodeStates
                  .single,
            );
          }
        });
        rightOf(await mid.run());

        expect(reported, hasLength(1));
        expect(reader.state.phase, NodePhase.activationFailed);
        expect(
          identical(
            reader.state.activationFailure.toNullable(),
            reported.single,
          ),
          isTrue,
        );
        expect(
          identical(reader.activationFailure.toNullable(), reported.single),
          isTrue,
        );
        // The subscriber ran after every listener of the transition that shows
        // the failure.
        expect(seenAtReport, hasLength(2));
        for (final node in seenAtReport) {
          expect(node.phase, NodePhase.activationFailed);
          expect(
            identical(node.activationFailure.toNullable(), reported.single),
            isTrue,
          );
        }

        // The failed member becomes `disposed` in one transition.
        final before = root.revision;
        rightOf(await reader.dispose());
        expect(root.revision, before + 1);
        expect(reader.state.phase, NodePhase.disposed);
        expect(reader.state.activationFailure.isNone(), isTrue);
        expect(leaf.state.nodeStates.single.phase, NodePhase.disposed);
        expect(leaf.findNode<int>(key: b), isA<None>());
      },
    );
  });

  group('a release', () {
    test('withdraws the keys in the transition that starts it', () async {
      // from: runtime_state_test.dart: withdraws the keys in the transition
      // that starts it
      final gate = Completer<void>();
      final root = Scope(
        components: [
          Component<int>(
            key: a,
            dependency: Dependency<int>(
              create: () => 1,
              dispose: (_) => gate.future,
            ),
          ),
          number(b, 2),
        ],
      );
      final mid = root.kid(
        components: [
          Component<int>(
            key: const DiKey<int>(name: 'v'),
            dependency: Dependency.require<int>(key: a).map<int>((v) => v),
          ),
          Component<int>(
            key: const DiKey<int>(name: 'n'),
            dependency: (
              Dependency.require<int>(key: a),
              Dependency.require<int>(key: b),
            ).zip.mapN<int>((x, y) => x + y),
          ),
        ],
      );
      // A child that publishes one of the two keys itself.
      final leaf = mid.kid(components: [number(a, 9)]);
      rightOf(await root.run());
      rightOf(await mid.run());
      rightOf(await leaf.run());
      final publisher = rightOf(root.node<int>(key: a));
      final reader = mid.nodes[0];
      final waiting = mid.nodes[1];
      // The second key leaves, so the node of the two keys waits for it.
      rightOf(await rightOf(root.node<int>(key: b)).dispose());
      expect(waiting.state.phase, NodePhase.waiting);
      expect(waiting.state.missing, [b]);

      final recorder = Recorder(root, leaf);
      final gone = publisher.dispose();
      await pause(1);

      // The release waits on its gate.
      expect(publisher.state.phase, NodePhase.deactivating);
      expect(publisher.isActive, isFalse);
      expect(leftOf(publisher.value), isA<InactiveNodeFailure>());
      // `whenActive` completes at once only in the phase `active`.
      var completed = false;
      unawaited(publisher.whenActive.run().then((_) => completed = true));
      await pause(1);
      expect(completed, isFalse);
      expect(root.getOption<int>(key: a), isA<None>());
      expect(mid.getOption<int>(key: a), isA<None>());
      expect(publisher.state.missing, isEmpty);
      // The first value of the release shows the withdrawn key in the
      // missing keys of the waiting node.
      final start = recorder.values.first;
      expect(start.nodeStates[0].phase, NodePhase.deactivating);
      expect(start.childStates.single.nodeStates[1].missing, [a, b]);
      expect(start.childStates.single.nodeStates[0].phase, NodePhase.active);
      expect(reader.state.phase, NodePhase.waiting);
      expect(reader.state.missing, [a]);
      // The scope that publishes the key itself still answers.
      expect(rightOf(leaf.get<int>(key: a)), 9);

      gate.complete();
      rightOf(await gone);
      expect(publisher.state.phase, NodePhase.disposed);
    });

    test('moves the answer of a key to the node of the parent', () async {
      // from: runtime_state_test.dart: moves the answer of a key to the node
      // of the parent
      final gate = Completer<void>();
      final root = Scope(components: [number(a, 1)]);
      rightOf(await root.run());
      final child = root.kid(
        components: [
          Component<int>(
            key: a,
            dependency: Dependency<int>(
              create: () => 2,
              dispose: (_) => gate.future,
            ),
          ),
        ],
      );
      rightOf(await child.run());
      final near = child.findNode<int>(key: a).toNullable()!.state;
      expect(near.id, child.state.nodeStates.single.id);
      expect(rightOf(child.get<int>(key: a)), 2);

      final gone = child.nodes.single.dispose();
      await pause(1);
      final far = child.findNode<int>(key: a).toNullable()!.state;
      expect(far.id, root.state.nodeStates.single.id);
      expect(far, isNot(near));
      expect(rightOf(child.get<int>(key: a)), 1);
      gate.complete();
      rightOf(await gone);
      expect(
        child.findNode<int>(key: a).toNullable()!.state.id,
        root.state.nodeStates.single.id,
      );
      rightOf(await root.dispose());
    });
  });

  group('lookups', () {
    test('agree with the phase of the scope and of each node', () async {
      // from: runtime_state_test.dart: agree with the phase of the scope and
      // of each node
      final root = Scope(components: [number(a, 1), reading(b, a)]);
      final gate = Completer<void>();
      final child = root.kid(
        components: [
          Component<int>(
            key: c,
            dependency: Dependency<int>(
              create: () => 3,
              dispose: (_) => gate.future,
            ),
          ),
        ],
      );
      void expectAgree(Scope scope) {
        final phase = scope.state.phase;
        for (final key in [a, b, c]) {
          final value = scope.getOption<int>(key: key);
          final node = scope.findNode<int>(key: key);
          if (phase == ScopePhase.disposing || phase == ScopePhase.disposed) {
            expect(
              leftOf(scope.get<int>(key: key)),
              isA<DisposedScopeFailure>(),
            );
            expect(node, isA<None>());
            continue;
          }
          expect(
            value.isSome(),
            node
                .map((n) => n.state.phase == NodePhase.active)
                .getOrElse(() => false),
            reason: '$key in the phase ${phase.name}',
          );
        }
      }

      for (final scope in [root, child]) {
        expectAgree(scope);
      }
      rightOf(await root.run());
      rightOf(await child.run());
      for (final scope in [root, child]) {
        expectAgree(scope);
      }
      final disposal = root.dispose();
      for (final scope in [root, child]) {
        expectAgree(scope);
      }
      await pause(1);
      for (final scope in [root, child]) {
        expectAgree(scope);
      }
      gate.complete();
      rightOf(await disposal);
      for (final scope in [root, child]) {
        expectAgree(scope);
      }
    });

    test('node and nodes follow the phase table', () async {
      final root = Scope(components: [number(a, 1)]);
      expect(root.nodes, isEmpty);
      expect(
        leftOf(root.node<int>(key: a)),
        isA<ScopePhaseFailure>().having(
          (f) => f.phase,
          'phase',
          ScopePhase.declared,
        ),
      );
      rightOf(await root.run());
      expect(root.nodes, hasLength(1));
      expect(rightOf(root.node<int>(key: a)).isActive, isTrue);
      expect(leftOf(root.node<int>(key: b)), isA<UnavailableKeyFailure>());
      final disposal = root.dispose();
      // A requested disposal still answers.
      expect(root.nodes, hasLength(1));
      expect(root.node<int>(key: a).isRight(), isTrue);
      expect(rightOf(root.get<int>(key: a)), 1);
      rightOf(await disposal);
      expect(leftOf(root.node<int>(key: a)), isA<DisposedScopeFailure>());
      expect(root.nodes, hasLength(1), reason: 'the handles stay');
      expect(root.nodes.single.state.phase, NodePhase.disposed);
    });
  });

  group('disposal of a scope', () {
    test('goes through disposeRequested, disposing, and disposed', () async {
      // from: runtime_state_test.dart: goes through disposeRequested,
      // disposing, and disposed
      final root = Scope(components: []);
      rightOf(await root.run());
      final child = root.kid(components: [number(a, 1), reading(b, a)]);
      rightOf(await child.run());
      final grandchild = child.kid();
      rightOf(await grandchild.run());
      final states = <ScopeState>[];
      final ofGrandchild = <ScopePhase>[];
      rightOf(
        root.addListener(() {
          states.add(child.state);
          ofGrandchild.add(grandchild.state.phase);
        }),
      );
      var calls = 0;
      var phaseAtLastCall = ScopePhase.declared;
      rightOf(
        child.addListener(() {
          calls++;
          phaseAtLastCall = child.state.phase;
        }),
      );

      final gone = child.dispose();
      // Inside the accepted call, the scope and each descendant have the
      // phase `disposeRequested`.
      expect(states.single.phase, ScopePhase.disposeRequested);
      expect(ofGrandchild.single, ScopePhase.disposeRequested);
      expect(root.state.childStates.single.phase, ScopePhase.disposeRequested);
      expect(root.isDisposed, isFalse);
      rightOf(await gone);

      expect(runs(states.map((state) => state.phase)), [
        ScopePhase.disposeRequested,
        ScopePhase.disposing,
        ScopePhase.disposed,
      ]);
      expect(runs(ofGrandchild), [
        ScopePhase.disposeRequested,
        ScopePhase.disposing,
        ScopePhase.disposed,
      ]);
      // The first transition of the disposal mutation makes the phase
      // `disposing`, before a node changes.
      final first = states.firstWhere(
        (state) => state.phase == ScopePhase.disposing,
      );
      expect(first.nodeStates.map((node) => node.phase), [
        NodePhase.active,
        NodePhase.active,
      ]);
      // The value of a disposed scope: each node is disposed, and the parent
      // does not hold the scope. The read does not throw.
      expect(child.state.phase, ScopePhase.disposed);
      expect(
        child.state.nodeStates.map((node) => node.phase),
        everyElement(NodePhase.disposed),
      );
      expect(child.state.childStates, isEmpty);
      expect(root.state.childStates, isEmpty);

      // The listeners of the scope ran for its last transition, and for no
      // later transition of the root.
      expect(phaseAtLastCall, ScopePhase.disposed);
      final atDisposal = calls;
      rightOf(root.child());
      expect(calls, atDisposal);
      rightOf(await root.dispose());
    });

    test('addListener rejects a scope from disposing', () async {
      // from: runtime_state_test.dart: addListener rejects a scope from
      // disposing
      final root = Scope(components: []);
      rightOf(await root.run());
      final child = root.kid();
      rightOf(await child.run());
      void listener() {}
      rightOf(child.addListener(listener));
      final gone = child.dispose();
      expect(child.state.phase, ScopePhase.disposeRequested);
      // A requested disposal still answers, so a listener added now hears the
      // start and the end of the disposal.
      final heard = <ScopePhase>[];
      void late() => heard.add(child.state.phase);
      rightOf(child.addListener(late));
      child.removeListener(listener);
      rightOf(await gone);
      expect(
        heard,
        containsAllInOrder([ScopePhase.disposing, ScopePhase.disposed]),
      );
      expect(
        leftOf(child.addListener(() {})),
        isA<DisposedScopeFailure>().having(
          (f) => f.operation,
          'operation',
          'addListener',
        ),
      );
      child.removeListener(listener);
      // A listener on the parent is not affected.
      rightOf(root.addListener(listener));
      root.removeListener(listener);
      rightOf(await root.dispose());
    });

    test('a listener that calls dispose joins the accepted call', () async {
      // from: runtime_state_test.dart: a listener that calls dispose joins
      // the accepted call
      final log = <String>[];
      final root = Scope(components: []);
      rightOf(await root.run());
      final target = root.kid(
        components: [
          Component<int>(
            key: a,
            dependency: Dependency<int>(
              create: () => 1,
              dispose: (_) {
                log.add('target dispose');
              },
            ),
          ),
        ],
      );
      rightOf(await target.run());
      final sibling = root.kid(
        components: [
          Component<int>(
            key: b,
            dependency: Dependency<int>(
              create: () {
                log.add('sibling create');
                return 2;
              },
            ),
          ),
        ],
      );
      Future<Exit<DiFailure, Unit>>? joined;
      Future<Exit<DiFailure, Scope>>? requested;
      Object? readInside;
      var acted = false;
      rightOf(
        root.addListener(() {
          if (acted || target.state.phase != ScopePhase.disposeRequested) {
            return;
          }
          acted = true;
          // A lookup still answers in the phase `disposeRequested`.
          readInside = rightOf(target.get<int>(key: a));
          joined = target.dispose();
          requested = sibling.run();
          // A transition that a listener starts.
          root.child();
        }),
      );
      final later = <int>[];
      rightOf(root.addListener(() => later.add(root.revision)));

      final before = root.revision;
      final first = target.dispose();
      expect(acted, isTrue);
      expect(readInside, 1);
      // The later listener read the later state at both of its calls: the
      // calls of the transition of `child()` followed the calls in progress.
      expect(later, [before + 2, before + 2]);
      rightOf(await first);
      rightOf(await joined!);
      rightOf(await requested!);
      // One disposal, and the `run` ran after it.
      expect(log, ['target dispose', 'sibling create']);
      expect(sibling.state.phase, ScopePhase.initialized);
      expect(target.state.phase, ScopePhase.disposed);
      rightOf(await root.dispose());
    });
  });

  group('dispose during a run', () {
    test('a canceled run ends in disposeRequested', () async {
      // from: runtime_state_test.dart: a canceled initialize ends in
      // disposeRequested
      final gate = Completer<void>();
      var releases = 0;
      final root = Scope(components: []);
      rightOf(await root.run());
      final scope = root.kid(
        components: [
          Component<int>(
            key: a,
            dependency: Dependency<int>(
              create: () async {
                await gate.future;
                return 1;
              },
              dispose: (_) {
                releases++;
              },
            ),
          ),
        ],
      );
      final states = <ScopeState>[scope.state];
      final disposedReads = <bool>[scope.isDisposed];
      rightOf(
        root.addListener(() {
          states.add(scope.state);
          disposedReads.add(scope.isDisposed);
        }),
      );
      final done = scope.run();
      await pause(1);
      expect(scope.state.phase, ScopePhase.initializing);
      final gone = scope.dispose();
      expect(scope.state.phase, ScopePhase.disposeRequested);
      // The member in flight keeps `activating`.
      expect(scope.state.nodeStates.single.phase, NodePhase.activating);
      gate.complete();
      final failure = leftOf(await done);
      rightOf(await gone);

      expect(failure.isInterrupted, isTrue);
      expect(runs(states.map((state) => state.phase)), [
        ScopePhase.declared,
        ScopePhase.initializing,
        ScopePhase.disposeRequested,
        ScopePhase.disposing,
        ScopePhase.disposed,
      ]);
      // `isDisposed` does not return to false.
      expect(runs(disposedReads), [false, true]);
      final member = [
        for (final state in states)
          if (state.nodeStates.isNotEmpty) state.nodeStates.single.phase,
      ];
      expect(runs(member), [
        NodePhase.inactive,
        NodePhase.activating,
        NodePhase.disposed,
      ]);
      // The rollback ends in `disposeRequested` and keeps the disposed node.
      final rolledBack = states.indexWhere(
        (state) =>
            state.nodeStates.isNotEmpty &&
            state.nodeStates.every((node) => node.phase == NodePhase.disposed),
      );
      expect(states[rolledBack].phase, ScopePhase.disposeRequested);
      expect(
        leftOf(await scope.run()).only,
        isA<DisposedScopeFailure>(),
        reason: 'a new call after the disposal is rejected',
      );
      expect(releases, 1);
      expect(scope.isInitialized, isFalse);
      rightOf(await root.dispose());
    });

    test('a failed run ends in disposeRequested when the parent is disposed '
        'during its rollback', () async {
      // from: runtime_state_test.dart: a failed initialize ends in
      // disposeRequested when the parent is disposed during its rollback
      final gate = Completer<void>();
      final started = Completer<void>();
      var releases = 0;
      final root = Scope(components: []);
      rightOf(await root.run());
      final scope = root.kid(
        components: [
          Component<int>(
            key: a,
            dependency: Dependency<int>(
              create: () => 1,
              dispose: (_) async {
                started.complete();
                await gate.future;
                releases++;
              },
            ),
          ),
          Component<int>(
            key: b,
            dependency: Dependency.require<int>(
              key: a,
            ).map<int>((_) => throw StateError('boom')),
          ),
        ],
      );
      final states = <ScopeState>[scope.state];
      final disposedReads = <bool>[scope.isDisposed];
      rightOf(
        root.addListener(() {
          states.add(scope.state);
          disposedReads.add(scope.isDisposed);
        }),
      );
      final done = scope.run();
      await started.future;
      // The rollback waits on the gate, and the failed member is disposed.
      expect(scope.state.phase, ScopePhase.initializing);
      expect(scope.isDisposed, isFalse);
      expect(scope.state.nodeStates[0].phase, NodePhase.deactivating);
      expect(scope.state.nodeStates[1].phase, NodePhase.disposed);
      final gone = root.dispose();
      expect(scope.state.phase, ScopePhase.disposeRequested);
      gate.complete();
      final failure = leftOf(await done);
      rightOf(await gone);

      // The call keeps the failure of its member, and no interruption.
      expect(failure.only, isA<ActivationFailure>());
      expect(failure.isInterrupted, isFalse);
      expect(runs(states.map((state) => state.phase)), [
        ScopePhase.declared,
        ScopePhase.initializing,
        ScopePhase.disposeRequested,
        ScopePhase.disposing,
        ScopePhase.disposed,
      ]);
      expect(runs(disposedReads), [false, true]);
      final failed = [
        for (final state in states)
          if (state.nodeStates.isNotEmpty) state.nodeStates[1].phase,
      ];
      expect(runs(failed), [
        NodePhase.waiting,
        NodePhase.inactive,
        NodePhase.activating,
        NodePhase.disposed,
      ]);
      expect(releases, 1);
    });

    test('a run whose members committed completes with success in '
        'disposeRequested', () async {
      // from: runtime_state_test.dart: an initialize whose members committed
      // completes with success in disposeRequested
      final gate = Completer<void>();
      final started = Completer<void>();
      final root = Scope(components: []);
      rightOf(await root.run());
      final scope = root.kid(components: [number(a, 1)]);
      // A node of a child scope wakes in the last reconciliation of the call,
      // and its create function waits.
      final leaf = scope.kid(
        components: [
          Component<int>(
            key: b,
            dependency: Dependency.require<int>(key: a).mapTask<int>(
              (v) => Task(() async {
                started.complete();
                await gate.future;
                return v;
              }),
            ),
          ),
        ],
      );
      rightOf(await leaf.run());
      final phases = <ScopePhase>[scope.state.phase];
      rightOf(root.addListener(() => phases.add(scope.state.phase)));
      final done = scope.run();
      await started.future;
      expect(scope.state.phase, ScopePhase.initializing);
      expect(scope.state.nodeStates.single.phase, NodePhase.active);
      final gone = scope.dispose();
      expect(scope.state.phase, ScopePhase.disposeRequested);
      gate.complete();
      // No member failed, so the call completes with success.
      expect(rightOf(await done), same(scope));
      expect(scope.isInitialized, isTrue);
      expect(scope.nodes, hasLength(1));
      expect(scope.state.phase, ScopePhase.disposeRequested);
      expect(scope.nodes.single.state, scope.state.nodeStates.single);
      rightOf(await gone);
      // The scope does not have the phase `initialized`.
      expect(runs(phases), [
        ScopePhase.declared,
        ScopePhase.initializing,
        ScopePhase.disposeRequested,
        ScopePhase.disposing,
        ScopePhase.disposed,
      ]);
      expect(leaf.state.nodeStates.single.commits, 0);
      rightOf(await root.dispose());
    });
  });

  group('listeners', () {
    test('one function on two scopes is a listener of each', () async {
      // from: runtime_state_test.dart: one function on two scopes is a
      // listener of each
      final root = Scope(components: []);
      rightOf(await root.run());
      final child = root.kid();
      rightOf(await child.run());
      var calls = 0;
      void listener() => calls++;
      rightOf(root.addListener(listener));
      rightOf(child.addListener(listener));
      // A second call on one scope adds nothing.
      rightOf(root.addListener(listener));
      root.child();
      expect(calls, 2);
      child.removeListener(listener);
      root.child();
      expect(calls, 3);
      root.removeListener(listener);
      root.child();
      expect(calls, 3);
      rightOf(await root.dispose());
    });

    test('a listener that throws is removed and reported', () async {
      // from: runtime_state_test.dart: a listener that throws is removed and
      // reported
      final root = Scope(components: []);
      rightOf(await root.run());
      final reported = <Cause<DiFailure>>[];
      root.errors.listen(reported.add);
      var before = 0;
      var throwing = 0;
      var after = 0;
      var afterAtReport = -1;
      rightOf(root.addListener(() => before++));
      rightOf(
        root.addListener(() {
          throwing++;
          throw StateError('listener failed');
        }),
      );
      rightOf(root.addListener(() => after++));
      root.errors.listen((_) => afterAtReport = after);
      root.child();
      expect([before, throwing, after], [1, 1, 1]);
      expect(reported.single.only, isA<ListenerFailure>());
      // The report followed the calls of the transition.
      expect(afterAtReport, 1);
      root.child();
      expect([before, throwing, after], [2, 1, 2]);
      expect(reported, hasLength(1));
      rightOf(await root.dispose());
    });

    test('a failure during a report of errors is reported after it', () async {
      // from: runtime_state_test.dart: a failure during a report of errors is
      // reported after it
      const source = DiKey<int>(name: 'source');
      final root = Scope(components: [number(source, 1)]);
      // The reader fails when its key appears, so `errors` reports it.
      final child = root.kid(
        components: [
          Component<String>(
            key: const DiKey<String>(name: 'bad'),
            dependency: Dependency.require<int>(
              key: source,
            ).map<String>((_) => throw StateError('activation')),
          ),
        ],
      );
      rightOf(await child.run());
      final reported = <Cause<DiFailure>>[];
      var running = 0;
      root.errors.listen((error) {
        // A report does not start while another report runs.
        expect(running, 0);
        running++;
        reported.add(error);
        if (error.failures.single is ActivationFailure) {
          // The subscriber starts a transition, and a listener of that
          // transition throws.
          rightOf(root.addListener(() => throw StateError('listener')));
          root.child();
        }
        running--;
      });
      rightOf(await root.run());
      await pause(1);
      expect(reported.map((r) => r.only), [
        isA<ActivationFailure>(),
        isA<ListenerFailure>(),
      ]);
      rightOf(await root.dispose());
    });

    test('a mutation from a listener inside a mutation is rejected', () async {
      // from: runtime_state_test.dart: a mutation from a listener inside a
      // mutation is rejected
      final root = Scope(components: [number(a, 1)]);
      final other = root.kid();
      final failures = <Cause<DiFailure>>[];
      var requested = false;
      rightOf(
        root.addListener(() {
          if (requested || root.state.phase != ScopePhase.initializing) return;
          requested = true;
          unawaited(
            other.run().then((exit) => exit.match(failures.add, (_) {})),
          );
        }),
      );
      rightOf(await root.run());
      await pause(1);
      expect(requested, isTrue);
      expect(failures.single.only, isA<ReentrantMutationFailure>());
      expect(other.state.phase, ScopePhase.declared);
      rightOf(await root.dispose());
    });

    test('the listeners of the root hear the closing transitions, and the '
        'errors stream closes', () async {
      final root = Scope(components: []);
      var closed = false;
      root.errors.listen((_) {}, onDone: () => closed = true);
      rightOf(await root.dispose());
      await pause(1);
      expect(closed, isTrue);
      expect(root.phase, ScopePhase.disposed);
    });
  });
}
