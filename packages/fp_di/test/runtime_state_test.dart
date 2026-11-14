// The state of the runtime as an immutable value (V-T-RT-LC-031).
import 'dart:async';

import 'package:fp_di/fp_di.dart';
import 'package:test/test.dart';

final class _A {
  _A([this.tag = '']);
  final String tag;
}

final class _B {}

final class _C {}

final class _V {}

final class _N {}

final class _Service {}

const _services = DiSetKey<_Service>(name: 'services');

const _numbers = DiSetKey<int>(name: 'numbers');

/// A contribution to [_numbers] that reads [from].
Component<int> _contribution(DiKey<int> from) => Component<int>.into(
  key: _numbers,
  dependency: Dependency.require<int>(key: from).map((value) => value),
);

/// A strict reader of [_numbers] that publishes the number of its elements.
Component<int> _counter(DiKey<int> key) => Component<int>(
  key: key,
  dependency: Dependency.requireSet<int>(
    key: _numbers,
  ).map((values) => values.length),
);

/// Lets pending microtasks and timers run.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

/// Every member of [state] as a text. A value does not change, so the text
/// of a kept value stays the same.
String _print(ScopeState state, [String indent = '']) {
  final out = StringBuffer('$indent${state.phase.name}');
  for (final node in state.nodeStates) {
    out.write(
      '\n$indent  ${node.id} ${node.label} ${node.key} ${node.phase.name} '
      '${node.missing} ${identityHashCode(node.activationException)} '
      '${node.commits}',
    );
  }
  for (final child in state.childStates) {
    out.write('\n${_print(child, '$indent  ')}');
  }
  return '$out';
}

/// A listener on [scope] that keeps the state of [root] at each call.
final class _Recorder {
  _Recorder(this.root, Scope scope) {
    scope.addListener(call);
  }

  final Scope root;
  final List<ScopeState> values = [];
  final List<int> revisions = [];
  final List<String> copies = [];

  void call() {
    final value = root.state;
    values.add(value);
    revisions.add(root.revision);
    copies.add(_print(value));
  }

  /// No kept value changed after the runtime returned it.
  void expectValuesKept() {
    for (var i = 0; i < values.length; i++) {
      expect(_print(values[i]), copies[i], reason: 'kept value $i');
    }
  }
}

/// [items] without an item that equals the item before it.
List<T> _runs<T>(Iterable<T> items) {
  final result = <T>[];
  for (final item in items) {
    if (result.isEmpty || result.last != item) result.add(item);
  }
  return result;
}

/// The lookups of [scope] agree with its phase and with the phase of the
/// node of each key.
void _expectLookupsAgree(Scope scope, List<DiKey<Object>> keys) {
  final phase = scope.state.phase;
  if (phase == ScopePhase.disposing || phase == ScopePhase.disposed) {
    final rejects = throwsA(isA<DisposedScopeError>());
    for (final key in keys) {
      expect(() => scope.get<Object>(key: key), rejects);
      expect(() => scope.maybeGet<Object>(key: key), rejects);
      expect(() => scope.findNode<Object>(key: key), rejects);
    }
    expect(scope.describe, rejects);
    return;
  }
  for (final key in keys) {
    final value = scope.maybeGet<Object>(key: key);
    final node = scope.findNode<Object>(key: key);
    expect(
      value != null,
      node?.state.phase == NodePhase.active,
      reason: '$key in the phase ${phase.name}',
    );
    if (value != null) expect(identical(value, node!.value), isTrue);
  }
}

void main() {
  group('transitions and listener calls', () {
    test('each listener is called once at each transition, in order', () async {
      final root = Scope(
        module: Module(
          components: [Component<_A>(dependency: Dependency(create: _A.new))],
        ),
      );
      final onRoot = _Recorder(root, root);
      final before = root.revision;
      final child = root.child(
        module: Module(
          components: [
            Component<_B>(dependency: Dependency1<_A, _B>(create: (_) => _B())),
          ],
        ),
      );
      // The creation of a child scope is a transition.
      expect(root.revision, before + 1);
      expect(root.state.childStates.single.phase, ScopePhase.declared);
      final onChild = _Recorder(root, child);
      final grandchild = child.child(
        module: Module(
          components: [
            Component<_C>(dependency: Dependency1<_B, _C>(create: (_) => _C())),
          ],
        ),
      );
      final sibling = root.child();
      final onGrandchild = _Recorder(root, grandchild);
      final onSibling = _Recorder(root, sibling);

      await grandchild.initialize();
      // The value of the root holds the child of a scope that is `declared`.
      expect(root.state.childStates.first.phase, ScopePhase.declared);
      expect(
        root.state.childStates.first.childStates.single.phase,
        ScopePhase.initialized,
      );
      await root.initialize();
      await child.initialize();
      await sibling.initialize();
      expect(grandchild.get<_C>(), isA<_C>());

      // Two reads without a transition between them return one object.
      expect(identical(root.state, root.state), isTrue);
      expect(identical(child.state, child.state), isTrue);
      expect(identical(root.state.childStates.first, child.state), isTrue);

      await root.dispose();

      final recorders = [onRoot, onChild, onGrandchild, onSibling];
      for (final recorder in recorders) {
        expect(recorder.revisions, isNotEmpty);
        for (var i = 1; i < recorder.revisions.length; i++) {
          expect(recorder.revisions[i], recorder.revisions[i - 1] + 1);
        }
        recorder.expectValuesKept();
      }
      // The listener of the root is called for every transition.
      expect(onRoot.revisions.first, before + 1);
      expect(onRoot.revisions.last, root.revision);
      // Each listener of one transition reads the same object.
      for (final recorder in recorders.skip(1)) {
        for (var i = 0; i < recorder.revisions.length; i++) {
          final at = onRoot.revisions.indexOf(recorder.revisions[i]);
          expect(identical(onRoot.values[at], recorder.values[i]), isTrue);
        }
      }
      // The listeners of a disposed scope leave after its transition.
      expect(onGrandchild.revisions.last, lessThan(onChild.revisions.last));
      expect(onChild.revisions.last, lessThan(onRoot.revisions.last));
    });

    test('a transition keeps the objects that it does not change', () async {
      final gate = Completer<void>();
      final root = Scope(
        module: Module(
          components: [
            Component<_A>(
              dependency: Dependency(
                create: () async {
                  await gate.future;
                  return _A();
                },
              ),
            ),
            Component<_B>(dependency: Dependency(create: _B.new)),
          ],
        ),
      );
      final sibling = await root
          .child(
            module: Module(
              components: [
                Component<_C>(dependency: Dependency(create: _C.new)),
              ],
            ),
          )
          .initialize();
      final recorder = _Recorder(root, root);
      final done = root.initialize();
      await _settle();
      final beforeCommit = root.state;
      expect(beforeCommit.nodeStates[0].phase, NodePhase.activating);
      expect(beforeCommit.nodeStates[1].phase, NodePhase.active);
      gate.complete();
      await done;
      // The first value after the gate shows the commit of the first member.
      final afterCommit =
          recorder.values[recorder.values.indexOf(beforeCommit) + 1];
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
      recorder.expectValuesKept();
    });

    test('a node state is equal by value', () async {
      Scope make() => Scope(
        module: Module(
          components: [Component<_A>(dependency: Dependency(create: _A.new))],
        ),
      );
      final one = await make().initialize();
      final other = await make().initialize();
      // Two roots number their nodes from zero.
      expect(one.state, other.state);
      expect(one.state.hashCode, other.state.hashCode);
      expect(one.state.nodeStates.single, other.state.nodeStates.single);
      expect(identical(one.state, other.state), isFalse);
      await other.dispose();
      expect(one.state, isNot(other.state));
    });
  });

  group('phases', () {
    test('a scope is declared, initializing, and initialized', () async {
      final root = Scope(
        module: Module(
          components: [
            Component<_A>(dependency: Dependency(create: _A.new)),
            Component<_B>(dependency: Dependency1<_A, _B>(create: (_) => _B())),
          ],
        ),
      );
      expect(root.state.phase, ScopePhase.declared);
      expect(root.state.nodeStates, isEmpty);
      final recorder = _Recorder(root, root);
      await root.initialize();
      expect(_runs(recorder.values.map((value) => value.phase)), [
        ScopePhase.initializing,
        ScopePhase.initialized,
      ]);
      // The first value of `initializing` has one state for each component.
      expect(recorder.values.first.nodeStates, hasLength(2));
      expect(recorder.values.first.nodeStates[0].phase, NodePhase.inactive);
      expect(recorder.values.first.nodeStates[1].phase, NodePhase.waiting);
      expect(root.nodes, hasLength(2));
      for (var i = 0; i < 2; i++) {
        expect(
          identical(root.nodes[i].state, root.state.nodeStates[i]),
          isTrue,
        );
      }
      recorder.expectValuesKept();
    });

    test('a failed initialize returns the scope to declared', () async {
      final gate = Completer<void>();
      final root = Scope(
        module: Module(
          components: [
            Component<_A>(
              dependency: Dependency(create: () => throw StateError('boom')),
            ),
            Component<_B>(
              dependency: Dependency(
                create: () async {
                  await gate.future;
                  return _B();
                },
              ),
            ),
          ],
        ),
      );
      final recorder = _Recorder(root, root);
      Object? failure;
      final done = root.initialize().then<void>(
        (_) {},
        onError: (Object error) {
          failure = error;
        },
      );
      await _settle();
      // The failed member keeps `activating` while its sibling settles.
      expect(root.state.phase, ScopePhase.initializing);
      expect(root.state.nodeStates[0].phase, NodePhase.activating);
      expect(root.state.nodeStates[1].phase, NodePhase.activating);
      gate.complete();
      await done;
      expect(failure, isA<ActivationException>());
      expect(_runs(recorder.values.map((value) => value.phase)), [
        ScopePhase.initializing,
        ScopePhase.declared,
      ]);
      expect(root.state.nodeStates, isEmpty);
      expect(root.isInitialized, isFalse);
      final failed = [
        for (final value in recorder.values)
          if (value.nodeStates.isNotEmpty) value.nodeStates[0],
      ];
      expect(_runs(failed.map((node) => node.phase)), [
        NodePhase.inactive,
        NodePhase.activating,
        NodePhase.disposed,
      ]);
      // No node holds the failure: the caller of `initialize` has it.
      expect(
        failed.map((node) => node.activationException),
        everyElement(isNull),
      );
      // A later call can retry.
      expect(root.isDisposed, isFalse);
      recorder.expectValuesKept();
    });

    test('a node goes through its phases, and commits count', () async {
      final createGate = Completer<void>();
      final disposeGate = Completer<void>();
      final root = Scope(
        module: Module(
          components: [
            Component<_A>(
              dependency: Dependency(
                create: () async {
                  await createGate.future;
                  return _A();
                },
                dispose: (_) => disposeGate.future,
              ),
            ),
          ],
        ),
      );
      final child = await root
          .child(
            module: Module(
              components: [
                Component<_B>(
                  dependency: Dependency1<_A, _B>(create: (_) => _B()),
                ),
              ],
            ),
          )
          .initialize();
      final reader = child.nodes.single;
      expect(reader.state.phase, NodePhase.waiting);
      expect(reader.state.missing, [const DiKey<_A>()]);
      expect(reader.state.commits, 0);

      final recorder = _Recorder(root, root);
      final done = root.initialize();
      await _settle();
      createGate.complete();
      await done;
      final publisher = root.nodes.single;
      final gone = publisher.dispose();
      await _settle();
      disposeGate.complete();
      await gone;

      final ofPublisher = [
        for (final value in recorder.values) value.nodeStates.single,
      ];
      expect(_runs(ofPublisher.map((node) => node.phase)), [
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
      expect(_runs(ofReader.map((node) => node.phase)), [
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
      recorder.expectValuesKept();
    });

    test('a rebuilt node commits again under the same id', () async {
      final root = await Scope(
        module: Module(
          components: [
            Component<_A>(dependency: Dependency(create: () => _A('root'))),
          ],
        ),
      ).initialize();
      final mid = root.child(
        module: Module(
          components: [
            Component<_A>(dependency: Dependency(create: () => _A('mid'))),
          ],
        ),
      );
      final leaf = await mid
          .child(
            module: Module(
              components: [
                Component<String>(
                  key: const DiKey<String>(name: 'tag'),
                  dependency: Dependency1<_A, String>(create: (a) => a.tag),
                ),
              ],
            ),
          )
          .initialize();
      final reader = leaf.nodes.single;
      final first = reader.state;
      expect(first.commits, 1);
      expect(reader.value, 'root');
      await mid.initialize();
      expect(reader.value, 'mid');
      expect(reader.state.commits, 2);
      expect(reader.state.id, first.id);
      expect(reader.state, isNot(first));
    });

    test('labels and keys are those of describe', () async {
      final scope = Scope(
        module: Module(
          components: [
            Component<_Service>(
              dependency: Dependency<_Service>(create: _Service.new),
            ),
            Component.value(
              value: 1,
              debugLabel: 'number',
              key: const DiKey<int>(name: 'count'),
            ),
            Component.effect(
              dependency: Dependency1<_Service, void>(create: (_) {}),
            ),
            Component<_Service>.into(
              key: _services,
              dependency: Dependency<_Service>(create: _Service.new),
            ),
          ],
        ),
      );
      await scope.initialize();
      final nodes = scope.state.nodeStates;
      // The key, the debugLabel, and the type with the node number for the
      // effect and the set contribution.
      expect(nodes.map((node) => node.label), [
        equals('DiKey<_Service>'),
        equals('number'),
        matches(r'^Component<void>#\d+$'),
        matches(
          r'^Component<_Service> into DiSetKey<_Service>\(services\)#\d+$',
        ),
      ]);
      for (final node in nodes) {
        expect(scope.describe(), contains(node.label));
      }
      expect(nodes.map((node) => node.key), [
        const DiKey<_Service>(),
        const DiKey<int>(name: 'count'),
        null,
        null,
      ]);
      expect(nodes.map((node) => node.id).toSet(), hasLength(4));
    });
  });

  group('failures', () {
    test('an automatic activation failure is in the state, then in '
        'errors', () async {
      final root = await Scope().initialize();
      final mid = root.child(
        module: Module(
          components: [Component<_A>(dependency: Dependency(create: _A.new))],
        ),
      );
      final leaf = await mid
          .child(
            module: Module(
              components: [
                Component<_B>(
                  dependency: Dependency.maybe<_A>().map(
                    (a) => a == null ? _B() : throw StateError('boom'),
                  ),
                ),
              ],
            ),
          )
          .initialize();
      final reader = leaf.nodes.single;
      expect(reader.state.phase, NodePhase.active);

      final onRoot = _Recorder(root, root);
      final onLeaf = _Recorder(root, leaf);
      final reported = <DiException>[];
      // What each listener had kept last when the subscriber ran.
      final seenAtReport = <NodeState>[];
      var revisionAtReport = -1;
      root.errors.listen((error) {
        reported.add(error);
        revisionAtReport = root.revision;
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
      await mid.initialize();

      expect(reported, hasLength(1));
      expect(reader.state.phase, NodePhase.activationFailed);
      expect(
        identical(reader.state.activationException, reported.single),
        isTrue,
      );
      expect(identical(reader.activationException, reported.single), isTrue);
      // The subscriber ran after every listener of the transition that shows
      // the failure.
      expect(seenAtReport, hasLength(2));
      for (final node in seenAtReport) {
        expect(node.phase, NodePhase.activationFailed);
        expect(identical(node.activationException, reported.single), isTrue);
      }
      expect(revisionAtReport, greaterThan(0));

      // The failed member becomes `disposed` in one transition.
      final before = root.revision;
      await reader.dispose();
      expect(root.revision, before + 1);
      expect(reader.state.phase, NodePhase.disposed);
      expect(reader.state.activationException, isNull);
      expect(leaf.state.nodeStates.single.phase, NodePhase.disposed);
      expect(leaf.findNode<_B>(), isNull);
      onRoot.expectValuesKept();
    });
  });

  group('a release', () {
    test('withdraws the keys in the transition that starts it', () async {
      const k1 = DiKey<_A>();
      const k2 = DiKey<_B>();
      final gate = Completer<void>();
      final root = Scope(
        module: Module(
          components: [
            Component<_A>(
              key: k1,
              dependency: Dependency(
                create: () => _A('root'),
                dispose: (_) => gate.future,
              ),
            ),
            Component<_B>(
              key: k2,
              dependency: Dependency(create: _B.new),
            ),
          ],
        ),
      );
      final mid = root.child(
        module: Module(
          components: [
            Component<_V>(dependency: Dependency1<_A, _V>(create: (_) => _V())),
            Component<_N>(
              dependency: Dependency2<_A, _B, _N>(create: (_, _) => _N()),
            ),
          ],
        ),
      );
      // A child that publishes one of the two keys itself.
      final leaf = mid.child(
        module: Module(
          components: [
            Component<_A>(
              key: k1,
              dependency: Dependency(create: () => _A('leaf')),
            ),
            Component<_C>(dependency: Dependency1<_A, _C>(create: (_) => _C())),
          ],
        ),
      );
      await root.initialize();
      await mid.initialize();
      await leaf.initialize();
      final publisher = root.node<_A>(key: k1);
      final reader = mid.nodes[0];
      final waiting = mid.nodes[1];
      // The second key leaves, so the node of the two keys waits for it.
      await root.node<_B>(key: k2).dispose();
      expect(waiting.state.phase, NodePhase.waiting);
      expect(waiting.state.missing, [k2]);

      final recorder = _Recorder(root, leaf);
      final before = root.state;
      final gone = publisher.dispose();
      await _settle();

      // The release waits on its gate.
      final during = root.state;
      expect(publisher.state.phase, NodePhase.deactivating);
      expect(publisher.isActive, isFalse);
      expect(() => publisher.value, throwsA(isA<InactiveNodeException>()));
      // `whenActive` completes at once only in the phase `active`.
      var completed = false;
      unawaited(
        publisher.whenActive.then<void>((_) {
          completed = true;
        }, onError: (Object _) {}),
      );
      await _settle();
      expect(completed, isFalse);
      expect(root.describe(), contains('DiKey<_A>: deactivating'));
      expect(root.maybeGet<_A>(key: k1), isNull);
      expect(mid.maybeGet<_A>(key: k1), isNull);
      expect(publisher.state.missing, isEmpty);
      // The first value of the release shows the withdrawn key in the
      // missing keys of the waiting node.
      final start = recorder.values.first;
      expect(start.nodeStates[0].phase, NodePhase.deactivating);
      expect(start.childStates.single.nodeStates[1].missing, [k1, k2]);
      expect(start.childStates.single.nodeStates[0].phase, NodePhase.active);
      expect(reader.state.phase, NodePhase.waiting);
      expect(reader.state.missing, [k1]);

      // The pairs of the publisher, the reader, and the waiting node.
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
      expect(leaf.get<_A>(key: k1).tag, 'leaf');

      gate.complete();
      await gone;
      expect(publisher.state.phase, NodePhase.disposed);
      recorder.expectValuesKept();
    });

    test('moves the answer of a key to the node of the parent', () async {
      final gate = Completer<void>();
      final root = await Scope(
        module: Module(
          components: [
            Component<_A>(dependency: Dependency(create: () => _A('root'))),
          ],
        ),
      ).initialize();
      final child = await root
          .child(
            module: Module(
              components: [
                Component<_A>(
                  dependency: Dependency(
                    create: () => _A('child'),
                    dispose: (_) => gate.future,
                  ),
                ),
              ],
            ),
          )
          .initialize();
      final near = child.findNode<_A>()!.state;
      expect(near.id, child.state.nodeStates.single.id);
      expect(child.get<_A>().tag, 'child');

      final gone = child.nodes.single.dispose();
      await _settle();
      final far = child.findNode<_A>()!.state;
      expect(far.id, root.state.nodeStates.single.id);
      expect(far, isNot(near));
      expect(child.get<_A>().tag, 'root');
      gate.complete();
      await gone;
      expect(child.findNode<_A>()!.state.id, root.state.nodeStates.single.id);
    });

    test('changedSince pairs a created node and a node that left', () async {
      final root = await Scope().initialize();
      final empty = root.state;
      final child = root.child(
        module: Module(
          components: [Component<_A>(dependency: Dependency(create: _A.new))],
        ),
      );
      await child.initialize();
      final created = root.state.changedSince(empty);
      expect(created, hasLength(1));
      expect(created.single.$1, isNull);
      expect(created.single.$2!.phase, NodePhase.active);

      final full = root.state;
      await child.dispose();
      final left = root.state.changedSince(full);
      expect(left, hasLength(1));
      expect(left.single.$1!.phase, NodePhase.active);
      expect(left.single.$2, isNull);
    });
  });

  group('a strict collection read', () {
    test('waits until each contribution resolves or leaves', () async {
      const count = DiKey<int>(name: 'count');
      final sources = [for (var i = 0; i < 3; i++) DiKey<int>(name: 'k$i')];
      final root = await Scope().initialize();
      final failures = <DiException>[];
      root.errors.listen(failures.add);
      // Each source has its own scope, so the test chooses the order in
      // which the contributions resolve.
      final providers = <Scope>[];
      var parent = root;
      for (var i = 0; i < 3; i++) {
        parent = parent.child(
          module: Module(
            components: [Component.value(value: i, key: sources[i])],
          ),
        );
        providers.add(parent);
      }
      final scope = await parent
          .child(
            module: Module(
              components: [
                for (final source in sources) _contribution(source),
                _counter(count),
              ],
            ),
          )
          .initialize();
      final reader = scope.node<int>(key: count);
      void expectWaits(String when) {
        expect(reader.state.phase, NodePhase.waiting, reason: when);
        expect(reader.state.missing, [_numbers], reason: when);
      }

      expectWaits('no contribution resolves');
      // The contributions resolve in reverse declaration order.
      await providers[2].initialize();
      expectWaits('the last contribution resolves');
      await providers[1].initialize();
      expectWaits('two contributions resolve');
      // A resolved contribution is withdrawn while the reader waits for
      // another one.
      await providers[2].nodes.single.dispose();
      expect(scope.nodes[2].state.phase, NodePhase.waiting);
      expectWaits('a resolved contribution is withdrawn');
      await providers[0].initialize();
      expect(scope.nodes[0].state.phase, NodePhase.active);
      expectWaits('the first contribution resolves');
      // The contributor that the reader waits for is disposed alone, so its
      // contribution leaves the set.
      await scope.nodes[2].dispose();
      expect(reader.state.phase, NodePhase.active);
      expect(reader.state.missing, isEmpty);
      expect(reader.value, 2);
      expect(failures, isEmpty);
      await root.dispose();
    });
  });

  group('lookups', () {
    test('agree with the phase of the scope and of each node', () async {
      final createGate = Completer<void>();
      final disposeGate = Completer<void>();
      final keys = <DiKey<Object>>[const DiKey<_A>(), const DiKey<_B>()];
      final root = Scope(
        module: Module(
          components: [
            Component<_A>(
              dependency: Dependency(
                create: () async {
                  await createGate.future;
                  return _A();
                },
              ),
            ),
          ],
        ),
      );
      final child = root.child(
        module: Module(
          components: [
            Component<_B>(
              dependency: Dependency1<_A, _B>(
                create: (_) => _B(),
                dispose: (_) => disposeGate.future,
              ),
            ),
          ],
        ),
      );
      final seen = <ScopePhase>{};
      void check() {
        for (final scope in [root, child]) {
          seen.add(scope.state.phase);
          _expectLookupsAgree(scope, keys);
          for (final member in scope.nodes) {
            expect(member.isActive, member.state.phase == NodePhase.active);
          }
        }
      }

      root.addListener(check);
      check();
      await child.initialize();
      final done = root.initialize();
      await _settle();
      check();
      createGate.complete();
      await done;
      final gone = child.dispose();
      // Before the accepted call returns, a lookup still answers.
      expect(child.state.phase, ScopePhase.disposeRequested);
      expect(child.isDisposed, isTrue);
      expect(child.get<_B>(), isA<_B>());
      await _settle();
      expect(child.state.phase, ScopePhase.disposing);
      check();
      disposeGate.complete();
      await gone;
      check();
      expect(seen, ScopePhase.values.toSet());
      await root.dispose();
    });
  });

  group('disposal of a scope', () {
    test('goes through disposeRequested, disposing, and disposed', () async {
      final root = await Scope().initialize();
      final child = await root
          .child(
            module: Module(
              components: [
                Component<_A>(dependency: Dependency(create: _A.new)),
                Component<_B>(
                  dependency: Dependency1<_A, _B>(create: (_) => _B()),
                ),
              ],
            ),
          )
          .initialize();
      final grandchild = await child.child().initialize();
      final states = <ScopeState>[];
      final ofGrandchild = <ScopePhase>[];
      root.addListener(() {
        states.add(child.state);
        ofGrandchild.add(grandchild.state.phase);
      });
      var calls = 0;
      var phaseAtLastCall = ScopePhase.declared;
      child.addListener(() {
        calls++;
        phaseAtLastCall = child.state.phase;
      });

      final gone = child.dispose();
      // Inside the accepted call, the scope and each descendant have the
      // phase `disposeRequested`.
      expect(states.single.phase, ScopePhase.disposeRequested);
      expect(ofGrandchild.single, ScopePhase.disposeRequested);
      expect(root.state.childStates.single.phase, ScopePhase.disposeRequested);
      expect(root.isDisposed, isFalse);
      await gone;

      expect(_runs(states.map((state) => state.phase)), [
        ScopePhase.disposeRequested,
        ScopePhase.disposing,
        ScopePhase.disposed,
      ]);
      expect(_runs(ofGrandchild), [
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
      expect(identical(child.state, child.state), isTrue);

      // The listeners of the scope ran for its last transition, and for no
      // later transition of the root.
      expect(phaseAtLastCall, ScopePhase.disposed);
      final atDisposal = calls;
      root.child();
      expect(calls, atDisposal);
    });

    test('addListener rejects a scope from disposeRequested', () async {
      final root = await Scope().initialize();
      final child = await root.child().initialize();
      void listener() {}
      child.addListener(listener);
      final gone = child.dispose();
      expect(child.state.phase, ScopePhase.disposeRequested);
      expect(
        () => child.addListener(() {}),
        throwsA(isA<DisposedScopeError>()),
      );
      child.removeListener(listener);
      await gone;
      expect(
        () => child.addListener(() {}),
        throwsA(isA<DisposedScopeError>()),
      );
      child.removeListener(listener);
      // A listener on the parent is not affected.
      root.addListener(listener);
      root.removeListener(listener);
    });

    test('a listener that calls dispose joins the accepted call', () async {
      final log = <String>[];
      final root = await Scope().initialize();
      final target = await root
          .child(
            module: Module(
              components: [
                Component<_A>(
                  dependency: Dependency(
                    create: _A.new,
                    dispose: (_) {
                      log.add('target dispose');
                    },
                  ),
                ),
              ],
            ),
          )
          .initialize();
      final sibling = root.child(
        module: Module(
          components: [
            Component<_B>(
              dependency: Dependency(
                create: () {
                  log.add('sibling create');
                  return _B();
                },
              ),
            ),
          ],
        ),
      );
      Future<void>? joined;
      Future<Scope>? requested;
      Object? readInside;
      var acted = false;
      root.addListener(() {
        if (acted || target.state.phase != ScopePhase.disposeRequested) return;
        acted = true;
        // A lookup still answers in the phase `disposeRequested`.
        readInside = target.get<_A>();
        joined = target.dispose();
        requested = sibling.initialize();
        // A transition that a listener starts.
        root.child();
      });
      final later = <int>[];
      root.addListener(() => later.add(root.revision));

      final before = root.revision;
      final first = target.dispose();
      expect(acted, isTrue);
      expect(readInside, isA<_A>());
      // The later listener read the later state at both of its calls: the
      // calls of the transition of `child()` followed the calls in progress.
      expect(later, [before + 2, before + 2]);
      await first;
      await joined;
      await requested;
      // One disposal, and the `initialize` ran after it.
      expect(log, ['target dispose', 'sibling create']);
      expect(sibling.state.phase, ScopePhase.initialized);
      expect(target.state.phase, ScopePhase.disposed);
    });
  });

  group('dispose during initialize', () {
    test('a canceled initialize ends in disposeRequested', () async {
      final gate = Completer<void>();
      var releases = 0;
      final root = await Scope().initialize();
      final scope = root.child(
        module: Module(
          components: [
            Component<_A>(
              dependency: Dependency(
                create: () async {
                  await gate.future;
                  return _A();
                },
                dispose: (_) {
                  releases++;
                },
              ),
            ),
          ],
        ),
      );
      final states = <ScopeState>[scope.state];
      final disposedReads = <bool>[scope.isDisposed];
      root.addListener(() {
        states.add(scope.state);
        disposedReads.add(scope.isDisposed);
      });
      Object? failure;
      final done = scope.initialize().then<void>(
        (_) {},
        onError: (Object error) {
          failure = error;
        },
      );
      await _settle();
      expect(scope.state.phase, ScopePhase.initializing);
      final gone = scope.dispose();
      expect(scope.state.phase, ScopePhase.disposeRequested);
      // The member in flight keeps `activating`.
      expect(scope.state.nodeStates.single.phase, NodePhase.activating);
      gate.complete();
      await done;
      await gone;

      expect(failure, isA<ActivationCanceledException>());
      expect(_runs(states.map((state) => state.phase)), [
        ScopePhase.declared,
        ScopePhase.initializing,
        ScopePhase.disposeRequested,
        ScopePhase.disposing,
        ScopePhase.disposed,
      ]);
      // `isDisposed` does not return to false.
      expect(_runs(disposedReads), [false, true]);
      final member = [
        for (final state in states)
          if (state.nodeStates.isNotEmpty) state.nodeStates.single.phase,
      ];
      expect(_runs(member), [
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
      final next = states
          .skip(rolledBack + 1)
          .firstWhere((state) => !identical(state, states[rolledBack]));
      expect(next.phase, ScopePhase.disposing);
      expect(scope.initialize, throwsA(isA<DisposedScopeError>()));
      // The value read was the result of a commit that did not occur.
      expect(releases, 1);
      expect(scope.isInitialized, isFalse);
    });

    test('a failed initialize ends in disposeRequested when the parent is '
        'disposed during its rollback', () async {
      final gate = Completer<void>();
      final started = Completer<void>();
      var releases = 0;
      final root = await Scope().initialize();
      final scope = root.child(
        module: Module(
          components: [
            Component<_A>(
              dependency: Dependency(
                create: _A.new,
                dispose: (_) async {
                  started.complete();
                  await gate.future;
                  releases++;
                },
              ),
            ),
            Component<_B>(
              dependency: Dependency1<_A, _B>(
                create: (_) => throw StateError('boom'),
              ),
            ),
          ],
        ),
      );
      final states = <ScopeState>[scope.state];
      final disposedReads = <bool>[scope.isDisposed];
      root.addListener(() {
        states.add(scope.state);
        disposedReads.add(scope.isDisposed);
      });
      Object? failure;
      final done = scope.initialize().then<void>(
        (_) {},
        onError: (Object error) {
          failure = error;
        },
      );
      await started.future;
      // The rollback waits on the gate, and the failed member is disposed.
      expect(scope.state.phase, ScopePhase.initializing);
      expect(scope.isDisposed, isFalse);
      expect(scope.state.nodeStates[0].phase, NodePhase.deactivating);
      expect(scope.state.nodeStates[1].phase, NodePhase.disposed);
      final gone = root.dispose();
      expect(scope.state.phase, ScopePhase.disposeRequested);
      gate.complete();
      await done;
      await gone;

      // The call rethrows the failure of its member.
      expect(failure, isA<ActivationException>());
      expect(failure, isNot(isA<ActivationCanceledException>()));
      expect(_runs(states.map((state) => state.phase)), [
        ScopePhase.declared,
        ScopePhase.initializing,
        ScopePhase.disposeRequested,
        ScopePhase.disposing,
        ScopePhase.disposed,
      ]);
      expect(_runs(disposedReads), [false, true]);
      final failed = [
        for (final state in states)
          if (state.nodeStates.isNotEmpty) state.nodeStates[1].phase,
      ];
      expect(_runs(failed), [
        NodePhase.waiting,
        NodePhase.inactive,
        NodePhase.activating,
        NodePhase.disposed,
      ]);
      final rolledBack = states.indexWhere(
        (state) =>
            state.nodeStates.isNotEmpty &&
            state.nodeStates.every((node) => node.phase == NodePhase.disposed),
      );
      expect(states[rolledBack].phase, ScopePhase.disposeRequested);
      final next = states
          .skip(rolledBack + 1)
          .firstWhere((state) => !identical(state, states[rolledBack]));
      expect(next.phase, ScopePhase.disposing);
      expect(scope.initialize, throwsA(isA<DisposedScopeError>()));
      expect(releases, 1);
    });
  });

  group('dispose after the last commit of initialize', () {
    test('an initialize whose members committed completes with success in '
        'disposeRequested', () async {
      final gate = Completer<void>();
      final started = Completer<void>();
      final root = await Scope().initialize();
      final scope = root.child(
        module: Module(
          components: [Component<_A>(dependency: Dependency(create: _A.new))],
        ),
      );
      // A node of a child scope wakes in the last reconciliation of the
      // call, and its create function waits.
      final leaf = await scope
          .child(
            module: Module(
              components: [
                Component<_B>(
                  dependency: Dependency1<_A, _B>(
                    create: (_) async {
                      started.complete();
                      await gate.future;
                      return _B();
                    },
                  ),
                ),
              ],
            ),
          )
          .initialize();
      final phases = <ScopePhase>[scope.state.phase];
      root.addListener(() => phases.add(scope.state.phase));
      final done = scope.initialize();
      await started.future;
      expect(scope.state.phase, ScopePhase.initializing);
      expect(scope.state.nodeStates.single.phase, NodePhase.active);
      final gone = scope.dispose();
      expect(scope.state.phase, ScopePhase.disposeRequested);
      gate.complete();
      // No member failed, so the call completes with success.
      expect(await done, same(scope));
      expect(scope.isInitialized, isTrue);
      expect(scope.nodes, hasLength(1));
      expect(scope.state.phase, ScopePhase.disposeRequested);
      expect(
        identical(scope.nodes.single.state, scope.state.nodeStates.single),
        isTrue,
      );
      await gone;
      // The scope does not have the phase `initialized`.
      expect(_runs(phases), [
        ScopePhase.declared,
        ScopePhase.initializing,
        ScopePhase.disposeRequested,
        ScopePhase.disposing,
        ScopePhase.disposed,
      ]);
      expect(leaf.state.nodeStates.single.commits, 0);
    });
  });

  group('listeners', () {
    test('one function on two scopes is a listener of each', () async {
      final root = await Scope().initialize();
      final child = await root.child().initialize();
      var calls = 0;
      void listener() => calls++;
      root.addListener(listener);
      child.addListener(listener);
      // A second call on one scope adds nothing.
      root.addListener(listener);
      root.child();
      expect(calls, 2);
      child.removeListener(listener);
      root.child();
      expect(calls, 3);
      root.removeListener(listener);
      root.child();
      expect(calls, 3);
    });

    test('a listener that throws is removed and reported', () async {
      final root = await Scope().initialize();
      final reported = <DiException>[];
      root.errors.listen(reported.add);
      var before = 0;
      var throwing = 0;
      var after = 0;
      var afterAtReport = -1;
      root.addListener(() => before++);
      root.addListener(() {
        throwing++;
        throw StateError('listener failed');
      });
      root.addListener(() => after++);
      root.errors.listen((_) => afterAtReport = after);
      root.child();
      expect([before, throwing, after], [1, 1, 1]);
      expect(reported.single, isA<DiListenerException>());
      // The report followed the calls of the transition.
      expect(afterAtReport, 1);
      root.child();
      expect([before, throwing, after], [2, 1, 2]);
      expect(reported, hasLength(1));
    });

    test('a failure during a report of errors is reported after it', () async {
      const source = DiKey<int>(name: 'source');
      final root = Scope(
        module: Module(components: [Component.value(value: 1, key: source)]),
      );
      // The reader fails when its key appears, so `errors` reports it.
      final child = root.child(
        module: Module(
          components: [
            Component<String>(
              key: const DiKey<String>(name: 'bad'),
              dependency: Dependency.require<int>(
                key: source,
              ).map((_) => throw StateError('activation')),
            ),
          ],
        ),
      );
      await child.initialize();
      final reported = <DiException>[];
      var running = 0;
      root.errors.listen((error) {
        // A report does not start while another report runs.
        expect(running, 0);
        running++;
        reported.add(error);
        if (error is ActivationException) {
          // The subscriber starts a transition, and a listener of that
          // transition throws.
          root
            ..addListener(() => throw StateError('listener'))
            ..child();
        }
        running--;
      });
      await root.initialize();
      await _settle();
      expect(reported, [
        isA<ActivationException>(),
        isA<DiListenerException>(),
      ]);
      await root.dispose();
    });

    test('the indexes of the state do not keep a disposed scope', () async {
      const count = DiKey<int>(name: 'count');
      final plain = [for (var i = 0; i < 20; i++) DiKey<int>(name: 'plain $i')];
      final root = await Scope().initialize();
      final failures = <DiException>[];
      root.errors.listen(failures.add);
      // Each scope has a set contribution with its own internal key, a
      // strict reader of the set, and a reader of a key of its own. The
      // self-check `StateCurrent` reads the indexes at each transition.
      for (var i = 0; i < 20; i++) {
        final session = root.child(
          module: Module(
            components: [
              Component<int>.into(
                key: _numbers,
                dependency: Dependency(create: () => i),
              ),
              _counter(count),
              Component.value(value: i, key: plain[i]),
              Component<String>(
                key: DiKey<String>(name: 'text $i'),
                dependency: Dependency.require<int>(
                  key: plain[i],
                ).map((value) => '$value'),
              ),
            ],
          ),
        );
        await session.initialize();
        expect(session.get<int>(key: count), 1);
        await session.dispose();
      }
      expect(root.state.childStates, isEmpty);
      expect(failures, isEmpty);
      await root.dispose();
    });

    test('a mutation from a listener inside a mutation is rejected', () async {
      final root = Scope(
        module: Module(
          components: [Component<_A>(dependency: Dependency(create: _A.new))],
        ),
      );
      final other = root.child();
      final failures = <Object>[];
      var requested = false;
      root.addListener(() {
        if (requested || root.state.phase != ScopePhase.initializing) return;
        requested = true;
        unawaited(
          other.initialize().then<void>(
            (_) {},
            onError: (Object error) {
              failures.add(error);
            },
          ),
        );
      });
      await root.initialize();
      await _settle();
      expect(requested, isTrue);
      expect(failures.single, isA<ReentrantMutationError>());
      expect(other.state.phase, ScopePhase.declared);
    });

    test('reads of the state do not change the revision', () async {
      final root = await Scope(
        module: Module(
          components: [Component<_A>(dependency: Dependency(create: _A.new))],
        ),
      ).initialize();
      final before = root.revision;
      root.state;
      root.nodes.single.state;
      root.findNode<_A>();
      root.describe();
      expect(root.revision, before);
    });
  });

  group('cost', () {
    test('initializes a chain of 4000 members with a read at each '
        'transition', () async {
      final keys = [
        for (var i = 0; i < 4000; i++) DiKey<int>(name: 'member $i'),
      ];
      // Each member reads the member before it, as the cost fixtures of
      // module_test.dart do.
      final root = Scope(
        module: Module(
          components: [
            for (var i = 0; i < 4000; i++)
              Component<int>(
                key: keys[i],
                dependency: i == 0
                    ? Dependency(create: () => 0)
                    : Dependency.require<int>(key: keys[i - 1]).map((_) => i),
              ),
          ],
        ),
      );
      var reads = 0;
      ScopeState? last;
      root.addListener(() {
        last = root.state;
        reads++;
      });
      final watch = Stopwatch()..start();
      await root.initialize();
      watch.stop();
      // ignore: avoid_print
      print(
        'initialize(4000) with $reads reads of the state: '
        '${watch.elapsedMilliseconds} ms',
      );
      expect(last!.phase, ScopePhase.initialized);
      expect(last!.nodeStates, hasLength(4000));
      expect(reads, greaterThanOrEqualTo(8000));
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    for (final (name, reversed) in [
      ('declaration order', false),
      ('reverse order', true),
    ]) {
      test('initializes 1000 set contributors and 20 strict readers, '
          '$name', () async {
        const contributors = 1000;
        DiKey<int> link(int i) => DiKey<int>(name: 'link $i');
        // A chain of links fixes the order in which the contributions
        // commit.
        Dependency<int> after(int i) {
          final first = reversed ? contributors - 1 : 0;
          return i == first
              ? Dependency(create: () => i)
              : Dependency.require<int>(
                  key: link(reversed ? i + 1 : i - 1),
                ).map((_) => i);
        }

        final root = Scope(
          module: Module(
            components: [
              for (var i = 0; i < contributors; i++) ...[
                Component<int>(key: link(i), dependency: after(i)),
                Component<int>.into(
                  key: _numbers,
                  dependency: Dependency.require<int>(key: link(i)),
                ),
              ],
              for (var i = 0; i < 20; i++)
                _counter(DiKey<int>(name: 'reader $i')),
            ],
          ),
        );
        final watch = Stopwatch()..start();
        await root.initialize();
        watch.stop();
        // ignore: avoid_print
        print(
          'initialize($contributors contributors, 20 readers, $name): '
          '${watch.elapsedMilliseconds} ms',
        );
        expect(root.get<int>(key: const DiKey<int>(name: 'reader 0')), 1000);
        expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
        await root.dispose();
      });
    }
  });
}
