import 'dart:async';

import 'package:fp_di/fp_di.dart';
import 'package:test/test.dart';

/// Publishes [value] under the default `int` key.
Component<int> _number(int value) => Component.value(
  value: value,
  debugLabel: 'number',
  key: DiKey<int>(name: 'count'),
);

/// Reads the `int` key and publishes a text built from it.
Component<String> _text() => Component(
  dependency: Dependency.require<int>(
    key: const DiKey(name: 'count'),
  ).map((value) => 'v$value'),
  debugLabel: 'text',
  key: DiKey<String>(name: 'text'),
);

/// Lets pending microtasks and timers run.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('whenActive', () {
    test('completes when a dormant component activates', () async {
      final di = Scope(module: Module(components: [_number(1)]));
      final child = di.child(module: Module(components: [_text()]));
      await child.initialize();
      final text = child.nodes.single;
      String? value;
      final waiting = text.whenActive.then((v) => value = v as String);
      await _settle();
      expect(value, isNull);

      await di.initialize();
      await waiting;
      expect(value, 'v1');
      await di.dispose();
    });

    test('completes for a dormant member of a child scope', () async {
      final di = Scope(module: Module(components: [_number(3)]));
      final child = di.child(module: Module(components: [_text()]));
      await child.initialize();
      final member = child.nodes.single;
      final waiting = member.whenActive;
      expect(member.missing, [DiKey<int>(name: 'count')]);
      await di.initialize();
      expect(await waiting, 'v3');
      await di.dispose();
    });

    test('completes at once for an active component', () async {
      final di = Scope(module: Module(components: [_number(7)]));
      await di.initialize();
      expect(await di.nodes.single.whenActive, 7);
      await di.dispose();
    });

    test('fails with InactiveNodeException when disposed first', () async {
      // Declares the int key but never initializes, so the text waits.
      final pending = Scope(module: Module(components: [_number(1)]));
      final di = pending.child(module: Module(components: [_text()]));
      await di.initialize();
      final text = di.nodes.single;
      final waiting = expectLater(
        text.whenActive,
        throwsA(isA<InactiveNodeException>()),
      );
      await text.dispose();
      await waiting;
      await expectLater(text.whenActive, throwsA(isA<InactiveNodeException>()));
      await pending.dispose();
    });

    test('fails for every waiter when its scope is disposed', () async {
      // Declares the int key but never initializes, so the text waits.
      final di = Scope(module: Module(components: [_number(1)]));
      final child = di.child(module: Module(components: [_text()]));
      await child.initialize();
      final text = child.nodes.single;
      final first = expectLater(
        text.whenActive,
        throwsA(isA<InactiveNodeException>()),
      );
      final second = expectLater(
        text.whenActive,
        throwsA(isA<InactiveNodeException>()),
      );
      await child.dispose();
      await first;
      await second;
      await di.dispose();
    });

    test('stays pending after a failed automatic activation', () async {
      final di = Scope(module: Module(components: [_number(1)]));
      final errors = <DiException>[];
      final subscription = di.errors.listen(errors.add);
      final child = di.child(
        module: Module(
          components: [
            Component.effect(
              dependency: Dependency.require<int>(
                key: const DiKey(name: 'count'),
              ).map<String>((_) => throw StateError('boom')),
              debugLabel: 'failing',
            ),
          ],
        ),
      );
      await child.initialize();
      final failing = child.nodes.single;
      var completed = false;
      unawaited(
        failing.whenActive.then(
          (_) => completed = true,
          onError: (Object _) => completed = true,
        ),
      );

      await di.initialize();
      await _settle();
      expect(errors, hasLength(1));
      expect(errors.single, isA<ActivationException>());
      expect(completed, isFalse);
      expect(failing.missing, isEmpty);
      await subscription.cancel();
      await di.dispose();
    });
  });

  group('missing', () {
    test('lists missing keys while inactive and is empty after', () async {
      final di = Scope();
      final ints = di.child(module: Module(components: [_number(1)]));
      final doubles = ints.child(
        module: Module(
          components: [
            Component.value(value: 2.0, key: DiKey<double>(name: 'ratio')),
          ],
        ),
      );
      final consumer = doubles.child(
        module: Module(
          components: [
            Component.effect(
              dependency: Dependency.require2<int, double>(
                key1: const DiKey(name: 'count'),
                key2: const DiKey(name: 'ratio'),
              ).mapN((i, d) => i + d),
              debugLabel: 'pair',
            ),
          ],
        ),
      );
      await consumer.initialize();
      final pair = consumer.nodes.single;
      expect(pair.missing, [
        DiKey<int>(name: 'count'),
        DiKey<double>(name: 'ratio'),
      ]);
      expect(
        () => pair.missing.add(DiKey<bool>(name: 'enabled')),
        throwsUnsupportedError,
      );

      await ints.initialize();
      expect(pair.missing, [DiKey<double>(name: 'ratio')]);

      await doubles.initialize();
      expect(pair.isActive, isTrue);
      expect(pair.missing, isEmpty);

      await pair.dispose();
      expect(pair.missing, isEmpty);
      await di.dispose();
    });

    test('matches InactiveNodeException.missing', () async {
      // Declares the int key but never initializes, so the text waits.
      final pending = Scope(module: Module(components: [_number(1)]));
      final di = pending.child(module: Module(components: [_text()]));
      await di.initialize();
      final text = di.nodes.single;
      final error = () {
        try {
          text.value;
        } on InactiveNodeException catch (error) {
          return error;
        }
        return null;
      }();
      expect(error?.missing, text.missing);
      await pending.dispose();
    });
  });

  group('describe', () {
    test('labels a node by its key unless it has a debugLabel', () async {
      final di = await Scope(
        module: Module(
          components: [
            Component<int>.value(key: DiKey<int>(name: 'port'), value: 1),
            Component<int>.effect(dependency: Dependency(create: () => 2)),
            Component<bool>.value(
              key: DiKey<bool>(name: 'enabled'),
              value: true,
              debugLabel: 'flag',
            ),
          ],
        ),
      ).initialize();
      final lines = di.describe().split('\n');
      expect(lines[1], '  - DiKey<int>(port): active');
      expect(lines[2], matches(RegExp(r'^  - Component<int>#\d+: active$')));
      expect(lines[3], '  - flag (DiKey<bool>(enabled)): active');
      expect(di.nodes.first.toString(), isNotEmpty);
      await di.dispose();
    });

    test('lists nodes and child scopes with their state', () async {
      // Declares the bool key but never initializes, so `flagged` waits.
      final outer = Scope(
        module: Module(
          components: [
            Component.value(value: true, key: DiKey<bool>(name: 'enabled')),
          ],
        ),
      );
      final di = outer.child(
        module: Module(
          components: [
            Component.value(
              value: 'hi',
              debugLabel: 'greeting',
              key: DiKey<String>(name: 'greeting'),
            ),
            _number(1),
          ],
        ),
      );
      final child = di.child(
        module: Module(
          components: [
            Component(
              dependency: Dependency.require<bool>(
                key: const DiKey(name: 'enabled'),
              ).map((flag) => '$flag'),
              debugLabel: 'flagged',
              key: DiKey<String>(name: 'flag'),
            ),
            Component.effect(
              dependency: Dependency.require<int>(
                key: const DiKey(name: 'count'),
              ).map((v) => v * 2),
              debugLabel: 'twice',
            ),
          ],
        ),
      );
      await di.initialize();
      await child.initialize();

      expect(
        di.describe(),
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
        child.describe(),
        startsWith('scope\n  - flagged (DiKey<String>(flag)): waiting'),
      );
      await outer.dispose();
    });

    test('lists declared components before initialize', () async {
      final di = Scope(module: Module(components: [_number(1), _text()]));
      expect(
        di.describe(),
        [
          'scope (not initialized)',
          '  - number (DiKey<int>(count)): declared',
          '  - text (DiKey<String>(text)): declared',
        ].join('\n'),
      );

      await di.initialize();
      expect(
        di.describe(),
        [
          'scope',
          '  - number (DiKey<int>(count)): active',
          '  - text (DiKey<String>(text)): active',
        ].join('\n'),
      );
      await di.dispose();
    });

    test('names a dispose-failed and an activation-failed node', () async {
      final di = Scope(module: Module(components: [_number(1)]));
      final errors = <DiException>[];
      final subscription = di.errors.listen(errors.add);
      // `later` sits between the publisher and the leaf. It initializes after
      // the publisher is withdrawn.
      final later = di.child(module: Module(components: [_number(2)]));
      final leaf = later.child(
        module: Module(
          components: [
            // Dormant until the first number appears, so its activation fails
            // automatically.
            Component.effect(
              dependency: Dependency.require<int>(
                key: const DiKey(name: 'count'),
              ).map<int>((_) => throw StateError('boom')),
              debugLabel: 'failing',
            ),
            Component.effect(
              dependency: Dependency.require<int>(
                key: const DiKey(name: 'count'),
              ).map<int>((v) => v, dispose: (_) => throw StateError('release')),
              debugLabel: 'brittle',
            ),
          ],
        ),
      );
      await leaf.initialize();
      await di.initialize();
      await expectLater(
        di.nodes.single.dispose(),
        throwsA(isA<DisposeException>()),
      );
      await later.initialize();

      final text = leaf.describe();
      expect(text, contains('  - brittle: dispose failed'));
      expect(text, contains('  - failing: activation failed'));
      expect(leaf.nodes.map((node) => node.state.phase), [
        NodePhase.activationFailed,
        NodePhase.disposeFailed,
      ]);
      expect(errors, everyElement(isA<ActivationException>()));
      await subscription.cancel();
      await di.dispose();
    });

    test('lists each component once while initialize runs', () async {
      final gate = Completer<void>();
      final di = Scope(
        module: Module(
          components: [
            _number(1),
            Component.effect(
              dependency:
                  Dependency.require<int>(
                    key: const DiKey(name: 'count'),
                  ).map<int>((v) async {
                    await gate.future;
                    return v;
                  }),
              debugLabel: 'slow',
            ),
          ],
        ),
      );
      final pending = di.initialize();
      await _settle();
      // The nodes exist, so no component is also listed as `declared`.
      expect(
        di.describe(),
        [
          'scope (not initialized)',
          '  - number (DiKey<int>(count)): active',
          '  - slow: activating',
        ].join('\n'),
      );

      gate.complete();
      await pending;
      expect(
        di.describe(),
        [
          'scope',
          '  - number (DiKey<int>(count)): active',
          '  - slow: active',
        ].join('\n'),
      );
      await di.dispose();
    });

    test('names a node activating while its setup is in flight', () async {
      final gate = Completer<void>();
      var started = false;
      final di = Scope(module: Module(components: [_number(1)]));
      final child = di.child(
        module: Module(
          components: [
            Component.effect(
              dependency:
                  Dependency.require<int>(
                    key: const DiKey(name: 'count'),
                  ).map<int>((v) async {
                    started = true;
                    await gate.future;
                    return v;
                  }),
              debugLabel: 'slow',
            ),
          ],
        ),
      );
      // The reader waits, because the publisher is not initialized.
      await child.initialize();
      expect(child.describe(), contains('  - slow: waiting'));
      final slow = child.nodes.single;
      expect(slow.state.phase, NodePhase.waiting);

      final setup = di.initialize();
      await _settle();
      expect(started, isTrue);
      expect(child.describe(), contains('  - slow: activating'));
      expect(slow.state.phase, NodePhase.activating);

      gate.complete();
      await setup;
      expect(child.describe(), contains('  - slow: active'));
      expect(slow.state.phase, NodePhase.active);
      await di.dispose();
    });

    group('after a failed automatic activation', () {
      final count = DiKey<int>(name: 'count');

      /// A child scope with a reader that throws until [failures] is spent.
      Scope failingChild(Scope parent, int Function() nextFailure) {
        return parent.child(
          module: Module(
            components: [
              Component.effect(
                dependency: Dependency.require<int>(key: count).map<int>(
                  (v) => nextFailure() > 0 ? throw StateError('boom') : v,
                ),
                debugLabel: 'flaky',
              ),
            ],
          ),
        );
      }

      test('a later successful attempt clears the failure', () async {
        var attempts = 0;
        final di = Scope(module: Module(components: [_number(1)]));
        final errors = <DiException>[];
        final subscription = di.errors.listen(errors.add);
        final child = failingChild(di, () => attempts++ == 0 ? 1 : 0);
        await child.initialize();
        await di.initialize();
        expect(errors, hasLength(1));
        expect(child.describe(), contains('  - flaky: activation failed'));

        // A later mutation that reconciles makes the runtime try again.
        await di.child(module: Module(components: [_text()])).initialize();
        expect(attempts, 2);
        expect(child.describe(), contains('  - flaky: active'));
        await subscription.cancel();
        await di.dispose();
      });

      test('a missing key outranks the past failure', () async {
        final di = Scope(module: Module(components: [_number(1)]));
        final errors = <DiException>[];
        final subscription = di.errors.listen(errors.add);
        final child = failingChild(di, () => 1);
        await child.initialize();
        await di.initialize();
        expect(child.describe(), contains('  - flaky: activation failed'));

        await di.node(key: count).dispose();
        final text = child.describe();
        expect(text, contains('  - flaky: waiting; missing DiKey<int>(count)'));
        expect(text, isNot(contains('activation failed')));
        await subscription.cancel();
        await di.dispose();
      });
    });

    test('a canceled activation is not named a failure', () async {
      final count = DiKey<int>(name: 'count');
      final readerGate = Completer<void>();
      final rollbackGate = Completer<void>();
      final withdrawalGate = Completer<void>();
      final root = Scope(
        module: Module(components: [Component.value(value: 2, key: count)]),
      );
      final errors = <DiException>[];
      final subscription = root.errors.listen(errors.add);
      // The publisher holds its own withdrawal open.
      final mid = root.child(
        module: Module(
          components: [
            Component<int>(
              key: count,
              dependency: Dependency<int>(
                create: () => 1,
                dispose: (_) => withdrawalGate.future,
              ),
            ),
          ],
        ),
      );
      // The reader holds its own rollback open, and waits for the gate or the
      // cancellation.
      final child = mid.child(
        module: Module(
          components: [
            Component.effect(
              dependency:
                  (
                    Dependency.require<int>(
                      key: count,
                    ).map<int>((v) => v, dispose: (_) => rollbackGate.future),
                    Dependency.cancellation(),
                  ).zip.mapN((v, token) async {
                    await Future.any([readerGate.future, token.whenCanceled]);
                    return v;
                  }),
              debugLabel: 'reader',
            ),
          ],
        ),
      );
      // The entry of the reader.
      String state() => child
          .describe()
          .split('\n')
          .lastWhere((line) => line.contains('- reader:'));
      var setupDone = false;

      await root.initialize();
      await mid.initialize();
      final setup = child.initialize().whenComplete(() => setupDone = true);
      await _settle();
      expect(state(), '  - reader: activating');

      final withdrawal = mid.node(key: count).dispose();
      await _settle();
      // The token is canceled, and the rollback waits for its dispose function.
      expect(setupDone, isFalse);
      expect(state(), '  - reader: activating');

      rollbackGate.complete();
      await setup;
      await _settle();
      // The node waits for the withdrawal to end. Nothing failed.
      expect(state(), '  - reader: inactive');
      expect(child.nodes.single.state.phase, NodePhase.inactive);

      readerGate.complete();
      withdrawalGate.complete();
      await withdrawal;
      expect(state(), '  - reader: active');
      expect(child.nodes.single.state.phase, NodePhase.active);
      expect(errors, isEmpty);
      await subscription.cancel();
      await root.dispose();
    });

    test('a disposed node has the state disposed and no entry', () async {
      final di = await Scope(
        module: Module(components: [_number(1)]),
      ).initialize();
      final node = di.nodes.single;
      expect(node.state.phase, NodePhase.active);
      expect(node.isActive, isTrue);

      await node.dispose();
      expect(node.state.phase, NodePhase.disposed);
      expect(node.isActive, isFalse);
      expect(di.describe(), 'scope');
      await di.dispose();
      // The node of a disposed scope is disposed, and the read does not throw.
      expect(node.state.phase, NodePhase.disposed);
    });

    test('rejects a disposed scope', () async {
      final di = Scope();
      final child = di.child();
      await child.dispose();
      expect(child.describe, throwsA(isA<DisposedScopeError>()));
      await di.dispose();
    });
  });

  group('isDisposed', () {
    test('is true from the dispose call and stays true', () async {
      final gate = Completer<void>();
      final di = await Scope(
        module: Module(
          components: [
            Component<int>(
              key: const DiKey(name: 'count'),
              dependency: Dependency<int>(
                create: () => 1,
                dispose: (_) => gate.future,
              ),
            ),
          ],
        ),
      ).initialize();
      final child = di.child();
      expect(di.isDisposed, isFalse);
      expect(child.isDisposed, isFalse);

      final disposal = di.dispose();
      // The disposal has not run, and both scopes already report it.
      expect(di.isDisposed, isTrue);
      expect(child.isDisposed, isTrue);
      await _settle();
      // The release waits on the gate.
      expect(di.isDisposed, isTrue);

      gate.complete();
      await disposal;
      expect(di.isDisposed, isTrue);
      expect(child.isDisposed, isTrue);
      expect(di.isInitialized, isTrue);
    });

    test('is false for a scope whose child is disposed', () async {
      final di = Scope();
      final child = di.child();
      await child.dispose();
      expect(child.isDisposed, isTrue);
      expect(di.isDisposed, isFalse);
      await di.dispose();
    });
  });

  group('activationException', () {
    const count = DiKey<int>(name: 'count');

    /// A child scope with one reader of [count] whose `create` runs [body].
    Scope readerChild(Scope parent, int Function(int value) body) {
      return parent.child(
        module: Module(
          components: [
            Component<int>.effect(
              dependency: Dependency.require<int>(key: count).map<int>(body),
              debugLabel: 'reader',
            ),
          ],
        ),
      );
    }

    test('holds the failure that errors reported', () async {
      final di = Scope(module: Module(components: [_number(1)]));
      final errors = <DiException>[];
      final subscription = di.errors.listen(errors.add);
      final child = readerChild(di, (_) => throw StateError('boom'));
      await child.initialize();
      final node = child.nodes.single;
      expect(node.activationException, isNull);

      await di.initialize();
      expect(node.state.phase, NodePhase.activationFailed);
      final failure = node.activationException!;
      expect(failure, same(errors.single));
      expect(failure.cause, isA<StateError>());
      expect('${failure.stackTrace}', contains('observation_test.dart'));
      // A second read returns the same failure.
      expect(node.activationException, same(failure));
      await subscription.cancel();
      await di.dispose();
    });

    test('keeps a failure that no listener of errors received', () async {
      final di = Scope(module: Module(components: [_number(1)]));
      final child = readerChild(di, (_) => throw StateError('boom'));
      await child.initialize();
      await di.initialize();

      expect(child.nodes.single.activationException?.cause, isA<StateError>());
      await di.dispose();
    });

    test('keeps the cause and the stack trace of a DiException', () async {
      final thrown = UnavailableKeyException(DiKey<String>(name: 'text'));
      final di = Scope(module: Module(components: [_number(1)]));
      final errors = <DiException>[];
      final subscription = di.errors.listen(errors.add);
      final child = readerChild(di, (_) => throw thrown);
      await child.initialize();
      await di.initialize();

      // `errors` reports the exception itself, which has no stack trace.
      expect(errors.single, same(thrown));
      final failure = child.nodes.single.activationException!;
      expect(failure.cause, same(thrown));
      expect('${failure.stackTrace}', contains('observation_test.dart'));
      await subscription.cancel();
      await di.dispose();
    });

    test('keeps the cause of a DiError in its own object', () async {
      final thrown = DisposedScopeError();
      final di = Scope(module: Module(components: [_number(1)]));
      final errors = <DiException>[];
      final subscription = di.errors.listen(errors.add);
      final child = readerChild(di, (_) => throw thrown);
      await child.initialize();
      await di.initialize();

      // `errors` reports the error in an `ActivationException` of its own.
      final reported = errors.single as ActivationException;
      final failure = child.nodes.single.activationException!;
      expect(reported.cause, same(thrown));
      expect(failure.cause, same(thrown));
      expect(failure, isNot(same(reported)));
      await subscription.cancel();
      await di.dispose();
    });

    test('is null after a later successful activation', () async {
      var attempts = 0;
      final di = Scope(module: Module(components: [_number(1)]));
      final child = readerChild(
        di,
        (v) => attempts++ == 0 ? throw StateError('boom') : v,
      );
      await child.initialize();
      await di.initialize();
      final node = child.nodes.single;
      expect(node.activationException, isNotNull);

      // A later mutation that reconciles makes the runtime try again.
      await di.child(module: Module(components: [_text()])).initialize();
      expect(node.state.phase, NodePhase.active);
      expect(node.activationException, isNull);
      await di.dispose();
    });

    test('is null while the node waits for a key', () async {
      final di = Scope(module: Module(components: [_number(1)]));
      final child = readerChild(di, (_) => throw StateError('boom'));
      await child.initialize();
      await di.initialize();
      final node = child.nodes.single;
      expect(node.activationException, isNotNull);

      await di.node(key: count).dispose();
      expect(node.state.phase, NodePhase.waiting);
      expect(node.activationException, isNull);
      await di.dispose();
    });

    test('is null for a disposed node', () async {
      final di = Scope(module: Module(components: [_number(1)]));
      final child = readerChild(di, (_) => throw StateError('boom'));
      await child.initialize();
      await di.initialize();
      final node = child.nodes.single;
      expect(node.activationException, isNotNull);

      await node.dispose();
      expect(node.state.phase, NodePhase.disposed);
      expect(node.activationException, isNull);
      await di.dispose();
    });
  });

  group('findNode', () {
    const count = DiKey<int>(name: 'count');
    const text = DiKey<String>(name: 'text');

    test('is null for a key that no node publishes', () async {
      final di = await Scope(
        module: Module(components: [_number(1)]),
      ).initialize();
      expect(di.findNode<String>(key: text), isNull);
      expect(di.findNode<_Service>(), isNull);
      await di.dispose();
    });

    test('does not count a scope that is not initialized', () async {
      final di = Scope(module: Module(components: [_number(1)]));
      final child = di.child();
      expect(di.findNode<int>(key: count), isNull);
      expect(child.findNode<int>(key: count), isNull);

      await di.initialize();
      expect(di.findNode<int>(key: count)?.value, 1);
      expect(child.findNode<int>(key: count)?.value, 1);
      await di.dispose();
    });

    test('returns a waiting node that get cannot read', () async {
      final di = Scope(module: Module(components: [_number(1)]));
      final child = await di
          .child(module: Module(components: [_text()]))
          .initialize();

      expect(child.maybeGet<String>(key: text), isNull);
      final node = child.findNode<String>(key: text)!;
      expect(node.state.phase, NodePhase.waiting);
      expect(node.missing, [count]);
      // The parent does not see the node of its child.
      expect(di.findNode<String>(key: text), isNull);

      await di.initialize();
      expect(node.state.phase, NodePhase.active);
      expect(child.findNode<String>(key: text)?.value, 'v1');
      await di.dispose();
    });

    test('prefers the node whose value get returns', () async {
      final di = await Scope(
        module: Module(components: [_number(1)]),
      ).initialize();
      // `gap` declares the text key and stays uninitialized, so the nearer
      // publisher of the count key waits.
      final gap = di.child(
        module: Module(
          components: [Component<String>.value(value: 't', key: text)],
        ),
      );
      final child = await gap
          .child(
            module: Module(
              components: [
                Component<int>(
                  dependency: Dependency.require<String>(
                    key: text,
                  ).map<int>((value) => value.length),
                  key: count,
                  debugLabel: 'nearer',
                ),
              ],
            ),
          )
          .initialize();

      expect(child.get<int>(key: count), 1);
      final far = child.findNode<int>(key: count)!;
      expect(far.state.phase, NodePhase.active);
      expect(far.value, 1);

      // Without an active publisher, the nearest node answers.
      await di.node(key: count).dispose();
      final near = child.findNode<int>(key: count)!;
      expect(near.state.phase, NodePhase.waiting);
      expect(near.missing, [text]);
      await di.dispose();
    });

    test('leads from a waiting node to the failure behind it', () async {
      final di = Scope(module: Module(components: [_number(1)]));
      final child = await di
          .child(
            module: Module(
              components: [
                Component<String>(
                  dependency: Dependency.require<int>(
                    key: count,
                  ).map<String>((_) => throw StateError('boom')),
                  key: text,
                ),
                Component<int>.effect(
                  dependency: Dependency.require<String>(
                    key: text,
                  ).map<int>((value) => value.length),
                  debugLabel: 'reader',
                ),
              ],
            ),
          )
          .initialize();
      // No listener of `errors` exists when the activation fails.
      await di.initialize();

      final reader = child.nodes.last;
      expect(reader.state.phase, NodePhase.waiting);
      final behind = [
        for (final key in reader.missing)
          if (key is DiKey<Object?>) child.findNode<Object?>(key: key),
      ];
      expect(behind.single?.state.phase, NodePhase.activationFailed);
      expect(behind.single?.activationException?.cause, isA<StateError>());
      await di.dispose();
    });

    test('does not count a member that was disposed alone', () async {
      final di = await Scope(
        module: Module(components: [_number(1)]),
      ).initialize();
      final child = await di
          .child(module: Module(components: [_number(2)]))
          .initialize();
      expect(child.findNode<int>(key: count)?.value, 2);

      await child.node(key: count).dispose();
      expect(child.findNode<int>(key: count)?.value, 1);
      await di.node(key: count).dispose();
      expect(child.findNode<int>(key: count), isNull);
      await di.dispose();
    });

    test('returns the nodes of a scope while initialize runs', () async {
      final gate = Completer<void>();
      final di = Scope(
        module: Module(
          components: [
            _number(1),
            Component<String>(
              dependency: Dependency<String>(
                create: () => gate.future.then((_) => 't'),
              ),
              key: text,
            ),
          ],
        ),
      );
      final initialization = di.initialize();
      await _settle();

      expect(di.isInitialized, isFalse);
      expect(di.findNode<int>(key: count)?.state.phase, NodePhase.active);
      expect(di.findNode<String>(key: text)?.state.phase, NodePhase.activating);
      gate.complete();
      await initialization;
      expect(di.findNode<String>(key: text)?.value, 't');
      await di.dispose();
    });

    test('rejects a disposed scope', () async {
      final di = Scope();
      final child = di.child();
      await child.dispose();
      expect(
        () => child.findNode<int>(key: count),
        throwsA(isA<DisposedScopeError>()),
      );
      await di.dispose();
    });
  });

  test('reads do not change the revision', () async {
    final pending = Scope(module: Module(components: [_number(1)]));
    final di = pending.child(module: Module(components: [_text()]));
    await di.initialize();
    final text = di.nodes.single;
    final before = di.revision;
    di.describe();
    text.missing;
    text.state;
    text.activationException;
    di.findNode<String>(key: const DiKey(name: 'text'));
    di.isDisposed;
    unawaited(text.whenActive.then((_) {}, onError: (Object _) {}));
    expect(di.revision, before);
    await pending.dispose();
  });
  group('cause of an unavailable key (V-T-RT-LC-035)', () {
    const gate = DiKey<int>(name: 'gate');
    const first = DiKey<String>(name: 'first');
    const second = DiKey<String>(name: 'second');
    const third = DiKey<String>(name: 'third');
    const other = DiKey<int>(name: 'other');

    /// Reads [gate] and publishes [key]. Its `create` runs [body].
    Component<String> gated(DiKey<String> key, String Function() body) =>
        Component<String>(
          dependency: Dependency.require<int>(key: gate).map((_) => body()),
          key: key,
        );

    /// Reads [from] and publishes [key].
    Component<String> behind(DiKey<String> key, DiKey<String> from) =>
        Component<String>(
          dependency: Dependency.require<String>(
            key: from,
          ).map((value) => '$value>'),
          key: key,
        );

    /// A root scope that publishes [gate] and [other].
    Scope rootScope() => Scope(
      module: Module(
        components: [
          Component.value(value: 1, key: gate),
          Component.value(value: 2, key: other),
        ],
      ),
    );

    /// The exception of `get` for [key]. `maybeGet` returns null, and the
    /// revision of the runtime stays the same.
    UnavailableKeyException thrownBy(Scope scope, DiKey<String> key) {
      final before = scope.revision;
      try {
        scope.get<String>(key: key);
      } on UnavailableKeyException catch (error) {
        expect(scope.maybeGet<String>(key: key), isNull);
        expect(scope.revision, before);
        return error;
      }
      fail('get returned a value for $key');
    }

    test('holds the failed node of each key behind a failure', () async {
      final root = Scope(
        module: Module(components: [Component.value(value: 1, key: gate)]),
      );
      final child = root.child(
        module: Module(
          components: [
            gated(first, () => throw StateError('boom')),
            behind(second, first),
            behind(third, second),
          ],
        ),
      );
      await child.initialize();
      // Before the root initializes, each node only waits.
      final waitsFor = <DiKeyBase, DiKeyBase>{
        first: gate,
        second: first,
        third: second,
      };
      for (final MapEntry(:key, value: missing) in waitsFor.entries) {
        final waiting = thrownBy(child, key as DiKey<String>);
        expect(waiting.failedNodeStates, isEmpty);
        expect(waiting.message, contains('waits for $missing'));
      }

      final errors = <DiException>[];
      final subscription = root.errors.listen(errors.add);
      await root.initialize();
      final node = child.findNode<String>(key: first)!;
      expect(node.state.phase, NodePhase.activationFailed);
      for (final key in [first, second, third]) {
        final error = thrownBy(child, key);
        expect(error.key, key);
        final failed = error.failedNodeStates.single;
        expect(failed.phase, NodePhase.activationFailed);
        expect(failed.key, first);
        expect(failed.activationException, same(node.activationException));
        expect(error.message, contains('boom'));
        expect(child.maybeGet<String>(key: key), isNull);
      }
      await subscription.cancel();
      await root.dispose();
    });

    test('holds two failed nodes in the order of the missing keys', () async {
      const both = DiKey<String>(name: 'both');
      final root = rootScope();
      final child = root.child(
        module: Module(
          components: [
            gated(first, () => throw StateError('one')),
            gated(second, () => throw ArgumentError('two')),
            Component<String>(
              dependency: Dependency.require2<String, String>(
                key1: first,
                key2: second,
              ).map((v) => '${v.$1}${v.$2}'),
              key: both,
            ),
          ],
        ),
      );
      await child.initialize();
      final errors = <DiException>[];
      final subscription = root.errors.listen(errors.add);
      await root.initialize();
      final error = thrownBy(child, both);
      expect(error.failedNodeStates.map((state) => state.key), [first, second]);
      expect(
        error.failedNodeStates.first.activationException!.cause,
        isStateError,
      );
      expect(
        error.failedNodeStates.last.activationException!.cause,
        isArgumentError,
      );
      expect(error.message, contains('one'));
      expect(error.message, contains('1 more failed'));
      expect(error.message, isNot(contains('two')));
      await subscription.cancel();
      await root.dispose();
    });

    test('holds the failed contributor behind a strict reader', () async {
      const names = DiSetKey<String>(name: 'names');
      final root = rootScope();
      final child = root.child(
        module: Module(
          components: [
            Component<String>.into(
              key: names,
              debugLabel: 'contributor',
              dependency: Dependency.require<int>(
                key: gate,
              ).map<String>((_) => throw StateError('no member')),
            ),
            Component<String>(
              dependency: Dependency.requireSet(
                key: names,
              ).map((set) => set.join(',')),
              key: first,
            ),
          ],
        ),
      );
      await child.initialize();
      final errors = <DiException>[];
      final subscription = root.errors.listen(errors.add);
      await root.initialize();
      expect(child.findNode<String>(key: first)!.state.missing, [names]);
      final error = thrownBy(child, first);
      final failed = error.failedNodeStates.single;
      expect(failed.phase, NodePhase.activationFailed);
      expect(failed.key, isNull);
      expect(failed.label, 'contributor');
      expect(failed.activationException!.cause, isStateError);
      expect(error.message, contains('contributor'));
      expect(error.message, contains('no member'));
      await subscription.cancel();
      await root.dispose();
    });

    test('holds the failed entry behind a strict map reader', () async {
      const pages = DiMapKey<String>(name: 'pages');
      final root = rootScope();
      final child = root.child(
        module: Module(
          components: [
            Component<String>(
              key: pages.entryKey('home'),
              debugLabel: 'home',
              dependency: Dependency.require<int>(
                key: gate,
              ).map<String>((_) => throw StateError('no page')),
            ),
            Component<String>(
              dependency: Dependency.requireMap(
                key: pages,
              ).map((map) => map.keys.join(',')),
              key: first,
            ),
          ],
        ),
      );
      await child.initialize();
      final errors = <DiException>[];
      final subscription = root.errors.listen(errors.add);
      await root.initialize();
      expect(child.findNode<String>(key: first)!.state.missing, [pages]);
      final error = thrownBy(child, first);
      final failed = error.failedNodeStates.single;
      expect(failed.key, pages.entryKey('home'));
      expect(failed.label, 'home');
      expect(failed.activationException!.cause, isStateError);
      expect(error.message, contains('no page'));
      await subscription.cancel();
      await root.dispose();
    });

    test(
      'is empty without a publisher and differs for a declared key',
      () async {
        final root = rootScope();
        final child = root.child(
          module: Module(
            components: [gated(first, () => throw StateError('boom'))],
          ),
        );
        final declared = root.child(
          module: Module(
            components: [Component.value(value: 'x', key: second)],
          ),
        );
        await child.initialize();
        final errors = <DiException>[];
        final subscription = root.errors.listen(errors.add);
        await root.initialize();
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
        await root.dispose();
      },
    );

    test('gives the same failed nodes from a child of the child', () async {
      final root = rootScope();
      final child = root.child(
        module: Module(
          components: [
            gated(first, () => throw StateError('boom')),
            behind(second, first),
          ],
        ),
      );
      await child.initialize();
      final grandchild = child.child(module: Module(components: const []));
      await grandchild.initialize();
      final errors = <DiException>[];
      final subscription = root.errors.listen(errors.add);
      await root.initialize();
      for (final key in [first, second]) {
        final fromChild = thrownBy(child, key);
        final fromGrandchild = thrownBy(grandchild, key);
        expect(fromChild.failedNodeStates, hasLength(1));
        expect(fromGrandchild.failedNodeStates, fromChild.failedNodeStates);
        expect(fromGrandchild.message, fromChild.message);
      }
      await subscription.cancel();
      await root.dispose();
    });

    test('is empty for a node that waits for a disposed root member', () async {
      final root = rootScope();
      final child = root.child(
        module: Module(
          components: [
            Component<String>(
              dependency: Dependency.require<int>(
                key: other,
              ).map((value) => 'v$value'),
              key: first,
            ),
          ],
        ),
      );
      await child.initialize();
      await root.initialize();
      expect(child.node(key: first).isActive, isTrue);

      await root.node(key: other).dispose();
      final error = thrownBy(child, first);
      expect(error.failedNodeStates, isEmpty);
      expect(error.message, contains('waits for $other'));
      await root.dispose();
    });

    test('returns the value again after the runtime retries', () async {
      var failing = true;
      final root = rootScope();
      final child = root.child(
        module: Module(
          components: [
            gated(first, () => failing ? throw StateError('boom') : 'ok'),
            behind(second, first),
            behind(third, second),
          ],
        ),
      );
      await child.initialize();
      final errors = <DiException>[];
      final subscription = root.errors.listen(errors.add);
      await root.initialize();
      expect(thrownBy(child, third).failedNodeStates, hasLength(1));

      failing = false;
      await root
          .child(
            module: Module(
              components: [
                Component.value(value: 3, key: const DiKey<int>(name: 'spare')),
              ],
            ),
          )
          .initialize();
      expect(child.get<String>(key: first), 'ok');
      expect(child.get<String>(key: second), 'ok>');
      expect(child.get<String>(key: third), 'ok>>');
      await subscription.cancel();
      await root.dispose();
    });

    test('searches a chain of 2000 waiting nodes in linear time', () async {
      const length = 2000;
      final keys = [
        for (var i = 0; i < length; i++) DiKey<String>(name: 'c$i'),
      ];
      final root = rootScope();
      final chain = root.child(
        module: Module(
          components: [
            gated(keys.first, () => throw StateError('boom')),
            for (var i = 1; i < length; i++) behind(keys[i], keys[i - 1]),
          ],
        ),
      );
      await chain.initialize();
      final errors = <DiException>[];
      final subscription = root.errors.listen(errors.add);
      await root.initialize();

      final watch = Stopwatch()..start();
      for (var i = 0; i < 100; i++) {
        expect(thrownBy(chain, keys.last).failedNodeStates, hasLength(1));
      }
      watch.stop();
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      await subscription.cancel();
      await root.dispose();
    });
  });
}

final class _Service {}
