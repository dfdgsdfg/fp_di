import 'dart:async';
import 'dart:math';

import 'package:fp_di/fp_di.dart';
import 'package:test/test.dart';

DiKey<int> _k(String name) => DiKey<int>(name: name);

/// Reads `deps`, publishes `name`, and reports through [log] when it builds.
Component<int> _node(String name, List<String> deps, {List<String>? log}) {
  int up(int sum) {
    log?.add('up $name');
    return sum + 1;
  }

  void Function(int)? down = log == null ? null : (_) => log.add('down $name');
  if (deps.isEmpty) {
    return Component<int>(
      dependency: Dependency<int>(create: () => up(0), dispose: down),
      debugLabel: name,
      key: _k(name),
    );
  }
  final sum = deps
      .map((dep) => Dependency.require<int>(key: _k(dep)))
      .reduce((left, right) => (left, right).zip.map((v) => v.$1 + v.$2));
  return Component<int>(
    dependency: sum.map(up, dispose: down),
    debugLabel: name,
    key: _k(name),
  );
}

Component<int> _failing(String name, List<String> log) => Component<int>(
  dependency: Dependency<int>(
    create: () {
      log.add('up $name');
      throw StateError('boom $name');
    },
  ),
  debugLabel: name,
  key: _k(name),
);

/// A member whose release always throws.
Component<int> _brittle(String name, {List<String>? log}) => Component<int>(
  dependency: Dependency<int>(
    create: () => 1,
    dispose: (_) {
      log?.add('down $name');
      throw StateError('release $name');
    },
  ),
  debugLabel: name,
  key: _k(name),
);

void main() {
  group('Module value', () {
    test('keeps its components in order and is immutable', () {
      final source = [
        Component.effect(dependency: Dependency(create: () => 1)),
        Component.effect(dependency: Dependency(create: () => 2)),
      ];
      final module = Module(components: source, debugLabel: 'core');
      source.add(Component.effect(dependency: Dependency(create: () => 3)));
      expect(module.components, hasLength(2));
      expect(module.debugLabel, 'core');
      expect(
        () => module.components.add(
          Component.effect(dependency: Dependency(create: () => 4)),
        ),
        throwsUnsupportedError,
      );
    });

    test('all and + concatenate in order', () {
      final a = Component.effect(dependency: Dependency(create: () => 1));
      final b = Component.effect(dependency: Dependency(create: () => 2));
      final c = Component.effect(dependency: Dependency(create: () => 3));
      final d = Component.effect(dependency: Dependency(create: () => 4));
      final left = Module(components: [a, b]);
      final right = Module(components: [c, d]);
      expect(Module.all(modules: [left, right]).components, [a, b, c, d]);
      expect(Module.all(modules: [right, left]).components, [c, d, a, b]);
      expect((left + right).components, [a, b, c, d]);
      expect(Module.all(modules: const []).components, isEmpty);
      expect(left.components, [a, b], reason: 'operands are unchanged');
    });

    test('origins name the module that listed each member, through all, '
        '+, and every edit', () {
      Component<int> value(String name) =>
          Component<int>.value(value: 0, key: DiKey<int>(name: name));
      final a = value('a');
      final b = value('b');
      final c = value('c');
      final d = value('d');
      final core = Module(components: [a, b], debugLabel: 'core');
      final plain = Module(components: [c]);
      final feature = Module(components: [d], debugLabel: 'feature');
      expect(core.origins, ['core', 'core']);
      expect(plain.origins, [null]);
      expect(() => core.origins.add('x'), throwsUnsupportedError);

      // A concatenation has no label and keeps the origin of each member,
      // also through a second concatenation.
      final all = Module.all(modules: [core, plain + feature]);
      expect(all.debugLabel, isNull);
      expect(all.components, [a, b, c, d]);
      expect(all.origins, ['core', 'core', null, 'feature']);
      expect(() => all.origins.add('x'), throwsUnsupportedError);
      expect(core.origins, ['core', 'core'], reason: 'operands are unchanged');

      // A label of the concatenation is its label and no origin.
      final labeled = Module.all(modules: [all, core], debugLabel: 'app');
      expect(labeled.debugLabel, 'app');
      expect('$labeled', 'Module(app)');
      expect(labeled.origins, [...all.origins, 'core', 'core']);
      expect(Module.all(modules: [labeled]).debugLabel, isNull);
      expect(Module.all(modules: [labeled]).origins, labeled.origins);
      expect(labeled.where((_) => true).debugLabel, 'app');

      // An edit keeps the origin of each position.
      final kept = all.where((member) => member != b);
      expect(kept.components, [a, c, d]);
      expect(kept.origins, ['core', null, 'feature']);
      expect(all.without(key: a.key!).origins, ['core', null, 'feature']);
      final fake = value('d');
      final replaced = all.replacing(key: d.key!, component: fake);
      expect(replaced.components[3], same(fake));
      expect(replaced.origins, all.origins);
      final fakes = Module(components: [value('a'), fake], debugLabel: 'fakes');
      expect(all.overriddenBy(fakes).origins, all.origins);

      // The unnamed constructor lists the members again, under its own label.
      final again = Module(components: all.components, debugLabel: 'app');
      expect(again.origins, ['app', 'app', 'app', 'app']);
      expect(Module(components: all.components).origins, List.filled(4, null));
    });

    test('derives publishes, requires, and reads', () {
      final a = Component<int>(
        dependency: Dependency.require<int>(key: _k('x')).map((v) => v),
        key: _k('a'),
      );
      final b = Component<int>(
        dependency: (
          Dependency.require<int>(key: _k('a')),
          Dependency.maybe<int>(key: _k('y')),
        ).zip.mapN((v, _) => v),
        key: _k('b'),
      );
      // Injects the key that it publishes itself, so it still needs another
      // publisher of that key.
      final c = Component<int>(
        dependency: Dependency.require<int>(key: _k('c')).map((v) => v),
        key: _k('c'),
      );
      final module = Module(components: [a, b, c]);
      expect(module.publishes, {_k('a'), _k('b'), _k('c')});
      expect(module.requires, {_k('x'), _k('c')});
      expect(module.reads, {_k('x'), _k('y'), _k('c')});
      expect(() => module.requires.add(_k('z')), throwsUnsupportedError);
      expect(Module(components: const []).requires, isEmpty);
    });

    test('replacing keeps the position and the ordering rule', () {
      final p = _node('p', []);
      final q = _node('q', []);
      final r = _node('r', []);
      final fake = Component<int>(
        dependency: Dependency<int>(create: () => 99),
        debugLabel: 'fake',
        key: _k('q'),
      );
      final module = Module(components: [p, q, r], debugLabel: 'core');
      final edited = module.replacing(key: _k('q'), component: fake);
      expect(edited.components, [p, fake, r]);
      expect(edited.debugLabel, 'core');
      expect(module.components, [p, q, r], reason: 'the source is unchanged');
    });

    test('replacing and without reject an ambiguous or absent key', () {
      final p = _node('p', []);
      final twin = Component<int>(
        dependency: Dependency<int>(create: () => 2),
        key: _k('p'),
      );
      final other = _node('o', []);
      expect(
        () =>
            Module(components: [p, twin]).replacing(key: _k('p'), component: p),
        throwsArgumentError,
      );
      expect(
        () => Module(components: [p]).without(key: _k('missing')),
        throwsArgumentError,
      );
      expect(
        () => Module(components: [p]).replacing(key: _k('p'), component: other),
        throwsArgumentError,
        reason: 'the replacement must publish the key',
      );
    });

    test('without and where keep the declaration order', () {
      final p = _node('p', []);
      final q = _node('q', []);
      final r = _node('r', []);
      final s = _node('s', []);
      final module =
          Module(components: [p, q], debugLabel: 'core') +
          Module(components: [r, s]);
      expect(module.without(key: _k('p')).components, [q, r, s]);
      final labeled = Module(components: [p, q, r], debugLabel: 'core');
      final kept = labeled.where((member) => member != q);
      expect(kept.components, [p, r]);
      expect(kept.debugLabel, 'core');
    });

    test('overriddenBy replaces each member that a fake publishes', () async {
      final p = _node('p', []);
      final q = _node('q', ['p']);
      final r = _node('r', []);
      Component<int> fake(String name, int value) => Component<int>.value(
        value: value,
        key: _k(name),
        debugLabel: 'fake $name',
      );
      final fakeP = fake('p', 10);
      final fakeR = fake('r', 30);
      final module = Module(components: [p, q, r], debugLabel: 'core');
      final edited = module.overriddenBy(Module(components: [fakeR, fakeP]));
      expect(edited.components, [fakeP, q, fakeR], reason: 'positions stay');
      expect(edited.debugLabel, 'core');
      expect(module.components, [p, q, r], reason: 'the source is unchanged');
      final di = await Scope(module: edited).initialize();
      expect(di.get(key: _k('q')), 11, reason: 'q reads the fake p');
      await di.dispose();
    });

    test('overriddenBy rejects a fake that replaces nothing', () {
      final p = _node('p', []);
      final twin = Component<int>.value(value: 2, key: _k('p'));
      final module = Module(components: [p]);
      expect(
        () => module.overriddenBy(Module(components: [_node('missing', [])])),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('nothing to override'),
          ),
        ),
      );
      expect(
        () => module.overriddenBy(
          Module(
            components: [
              Component<int>.effect(dependency: Dependency(create: () => 1)),
            ],
          ),
        ),
        throwsArgumentError,
        reason: 'a fake without a key',
      );
      expect(
        () => module.overriddenBy(Module(components: [twin, twin])),
        throwsArgumentError,
        reason: 'two fakes of one key',
      );
      expect(
        () => Module(
          components: [p, twin],
        ).overriddenBy(Module(components: [twin])),
        throwsArgumentError,
        reason: 'an ambiguous source key',
      );
    });

    test('a replaced member is what the scope creates', () async {
      final log = <String>[];
      final module = Module(
        components: [
          _node('api', [], log: log),
          _node('repo', ['api'], log: log),
        ],
      );
      final fake = Component<int>(
        dependency: Dependency<int>(
          create: () {
            log.add('up fake');
            return 41;
          },
        ),
        debugLabel: 'fake',
        key: _k('api'),
      );
      final di = await Scope(
        module: module.replacing(key: _k('api'), component: fake),
      ).initialize();
      expect(log, ['up fake', 'up repo']);
      expect(di.get(key: _k('repo')), 42);
      await di.dispose();
    });

    test('initialize completes with the same scope', () async {
      final di = Scope(module: Module(components: [_node('p', [])]));
      expect(await di.initialize(), same(di));
      await di.dispose();
    });
  });

  group('initialize', () {
    test('resolves forward references across several levels', () async {
      // a needs b needs c needs d; declared a, b, c, d.
      final di = Scope(
        module: Module(
          components: [
            _node('a', ['b']),
            _node('b', ['c']),
            _node('c', ['d']),
            _node('d', []),
          ],
        ),
      );
      await di.initialize();
      expect(di.get(key: _k('d')), 1);
      expect(di.get(key: _k('c')), 2);
      expect(di.get(key: _k('b')), 3);
      expect(di.get(key: _k('a')), 4);
      await di.dispose();
    });

    test('resolves a long reverse chain to a fixpoint', () async {
      const length = 300;
      final di = Scope(
        module: Module(
          components: [
            for (var i = 0; i < length; i++)
              _node('n$i', i + 1 < length ? ['n${i + 1}'] : const []),
          ],
        ),
      );
      await di.initialize();
      expect(di.get(key: _k('n0')), length);
      await di.dispose();
    });

    test('keeps each member its own node', () async {
      final log = <String>[];
      final root = Scope(
        module: Module(
          components: [Component.value(value: 10, key: _k('external'))],
        ),
      );
      final di = root.child(
        module: Module(
          components: [
            _node('needsExternal', ['external'], log: log),
            _node('free', [], log: log),
          ],
        ),
      );
      await di.initialize();
      expect(log, ['up free'], reason: 'the sibling is not blocked');
      expect(di.maybeGet(key: _k('free')), 1);
      expect(di.maybeGet(key: _k('needsExternal')), isNull);

      await root.initialize();
      expect(di.get(key: _k('needsExternal')), 11);

      // Reconciliation reaches one member and leaves the other untouched.
      await root.nodes.single.dispose();
      expect(di.maybeGet(key: _k('needsExternal')), isNull);
      expect(di.maybeGet(key: _k('free')), 1);
      expect(log, ['up free', 'up needsExternal', 'down needsExternal']);
      await root.dispose();
    });

    test('an empty module initializes and disposes', () async {
      final di = Scope(module: Module(components: const []));
      await di.initialize();
      expect(di.isInitialized, isTrue);
      expect(di.nodes, isEmpty);
      await di.dispose();
    });

    test('rejects a disposed scope', () async {
      final di = Scope();
      await di.dispose();
      expect(() => di.initialize(), throwsA(isA<DisposedScopeError>()));
    });

    test('rejects a second call on an initialized scope', () async {
      final di = Scope(module: Module(components: [_node('a', [])]));
      await di.initialize();
      await expectLater(di.initialize(), throwsA(isA<StateError>()));
      expect(di.get(key: _k('a')), 1, reason: 'the first call stays intact');
      await di.dispose();
    });

    test('a duplicate publisher fails the initialize atomically', () async {
      final di = Scope(
        module: Module(components: [_node('x', []), _node('x', [])]),
      );
      await expectLater(di.initialize(), throwsA(isA<DuplicateKeyError>()));
      expect(di.maybeGet(key: _k('x')), isNull, reason: 'atomic');
      expect(di.isInitialized, isFalse);
      await di.dispose();
    });

    test('a throwing member rolls back the whole module', () async {
      final log = <String>[];
      final root = Scope(
        module: Module(
          components: [Component.value(value: 1, key: _k('never'))],
        ),
      );
      final di = root.child(
        module: Module(
          components: [
            _node('first', [], log: log),
            _node('waits', ['never'], log: log),
            _node('second', ['first'], log: log),
            _failing('bad', log),
            _node('after', [], log: log),
          ],
        ),
      );
      await expectLater(
        di.initialize(),
        throwsA(
          isA<ActivationException>()
              .having((e) => e.cause, 'cause', isA<StateError>())
              .having((e) => e.rollbackFailures, 'rollbackFailures', isEmpty),
        ),
      );

      // `first`, `bad`, and `after` have no dependency and start together.
      // `second` starts only when `first` settles, before or after `bad`
      // fails; the log below is the order of this microtask schedule.
      expect(log, [
        'up first',
        'up bad',
        'up after',
        'up second',
        'down after',
        'down second',
        'down first',
      ]);
      expect(di.isInitialized, isFalse);
      expect(di.nodes, isEmpty);
      for (final name in ['first', 'second', 'waits', 'after', 'bad']) {
        expect(di.maybeGet(key: _k(name)), isNull, reason: name);
      }

      // No node of the failed module remains: the dormant member
      // does not wake up when its key appears.
      log.clear();
      await root.initialize();
      expect(log, isEmpty);

      // The keys are free again: a retry fails with the member's own error.
      await expectLater(
        di.initialize(),
        throwsA(
          isA<ActivationException>().having(
            (e) => e.cause,
            'cause',
            isA<StateError>(),
          ),
        ),
      );
      expect(di.isInitialized, isFalse);
      await root.dispose();
    });

    test('rollback cleanup failures are aggregated with the cause', () async {
      final di = Scope(
        module: Module(
          components: [_brittle('one'), _brittle('two'), _failing('bad', [])],
        ),
      );
      await expectLater(
        di.initialize(),
        throwsA(
          isA<ActivationException>()
              .having((e) => e.cause, 'cause', isA<StateError>())
              .having(
                (e) => e.rollbackFailures.map((i) => i.owner).toList(),
                'failures',
                ['two', 'one'],
              ),
        ),
      );
      expect(di.maybeGet(key: _k('one')), isNull);
      await di.dispose();
    });

    test(
      'a failed member rolls back its own completed effects first',
      () async {
        final log = <String>[];
        final partial = Component<int>.effect(
          dependency: Dependency<int>(
            create: () => 1,
            dispose: (_) => log.add('partial released'),
          ).map<int>((_) => throw StateError('late')),
        );
        final di = Scope(
          module: Module(
            components: [
              _node('ok', [], log: log),
              partial,
            ],
          ),
        );
        await expectLater(di.initialize(), throwsA(isA<ActivationException>()));
        expect(log, ['up ok', 'partial released', 'down ok']);
        await di.dispose();
      },
    );

    test('a descendant node woken in the closing reconciliation is dormant '
        'after the rollback', () async {
      final log = <String>[];
      const a = DiKey<int>(name: 'a');
      const b = DiKey<int>(name: 'b');
      // x injects b and publishes a; y only watches a and publishes b. The
      // cycle starts x first, which waits, so x first activates in the
      // closing reconciliation, after the leaf has woken on b, and throws.
      final x = Component<int>(
        dependency: Dependency.require<int>(key: b).map<int>((_) {
          log.add('up x');
          throw StateError('x');
        }),
        debugLabel: 'x',
        key: a,
      );
      final y = Component<int>(
        dependency: Dependency.maybe<int>(key: a).map<int>((_) {
          log.add('up y');
          return 1;
        }, dispose: (_) => log.add('down y')),
        debugLabel: 'y',
        key: b,
      );
      final root = Scope(module: Module(components: [x, y]));
      final leaf = root.child(
        module: Module(
          components: [
            Component<int>.effect(
              dependency: Dependency.require<int>(key: b).map<int>((v) {
                log.add('up leaf');
                return v;
              }, dispose: (_) => log.add('down leaf')),
              debugLabel: 'leaf',
            ),
          ],
        ),
      );
      final errors = <DiException>[];
      final subscription = root.errors.listen(errors.add);
      await leaf.initialize();

      await expectLater(root.initialize(), throwsA(isA<ActivationException>()));
      expect(log, ['up y', 'up leaf', 'up x', 'down leaf', 'down y']);
      expect(leaf.nodes.single.isActive, isFalse);
      expect(root.isInitialized, isFalse);
      expect(errors, isEmpty);
      await subscription.cancel();
      await root.dispose();
    });

    test(
      'a forward member that throws at reconciliation fails the initialize',
      () async {
        final errors = <DiException>[];
        final log = <String>[];
        final late = Component<int>.effect(
          dependency: Dependency.require<int>(key: _k('publisher')).map<int>((
            _,
          ) {
            log.add('up late');
            throw StateError('late failure');
          }),
          debugLabel: 'late',
        );
        final di = Scope(
          module: Module(
            components: [
              late,
              _node('publisher', [], log: log),
              _node('sibling', [], log: log),
            ],
          ),
        );
        di.errors.listen(errors.add);
        final failure = throwsA(
          isA<ActivationException>()
              .having((e) => e.cause, 'cause', isA<StateError>())
              .having((e) => e.rollbackFailures, 'rollbackFailures', isEmpty),
        );
        await expectLater(di.initialize(), failure);

        // The same failure in declaration order and in reconcile order has
        // the same outcome: no node of the module remains.
        final expected = [
          'up publisher',
          'up sibling',
          'up late',
          'down sibling',
          'down publisher',
        ];
        expect(log, expected);
        expect(di.maybeGet(key: _k('publisher')), isNull);
        expect(di.maybeGet(key: _k('sibling')), isNull);
        expect(errors, isEmpty, reason: 'reported by the rethrow, not twice');

        // The keys are free again: a retry repeats the same schedule.
        log.clear();
        await expectLater(di.initialize(), failure);
        expect(log, expected);
        expect(di.isInitialized, isFalse);
        await di.dispose();
      },
    );

    test('the failure is the same for every member order', () async {
      Component<int> boom() => Component<int>.effect(
        dependency: Dependency.require<int>(
          key: _k('a'),
        ).map<int>((_) => throw StateError('boom')),
        debugLabel: 'boom',
      );
      for (final failingFirst in [true, false]) {
        final log = <String>[];
        final members = [
          boom(),
          _node('a', [], log: log),
          _node('b', [], log: log),
        ];
        final ordered = failingFirst ? members : members.reversed.toList();
        final di = Scope(module: Module(components: ordered));
        await expectLater(
          di.initialize(),
          throwsA(isA<ActivationException>()),
          reason: 'failingFirst=$failingFirst',
        );
        expect(di.maybeGet(key: _k('a')), isNull);
        expect(di.maybeGet(key: _k('b')), isNull);
        expect(log.where((e) => e.startsWith('down')), hasLength(2));
        await di.dispose();
      }
    });

    test('a failing descendant node keeps the reconcile contract', () async {
      final root = Scope(module: Module(components: [_node('p', [])]));
      final di = root.child(
        module: Module(
          components: [
            Component<int>.effect(
              dependency: Dependency.require<int>(
                key: _k('p'),
              ).map<int>((_) => throw StateError('descendant failure')),
              debugLabel: 'descendant',
            ),
          ],
        ),
      );
      final errors = <DiException>[];
      root.errors.listen(errors.add);
      await di.initialize();
      final descendant = di.nodes.single;
      expect(descendant.isActive, isFalse);

      await root.initialize();

      expect(root.get(key: _k('p')), 1, reason: 'the initialize succeeds');
      expect(descendant.isActive, isFalse);
      expect(errors, hasLength(1));
      expect(
        errors.single,
        isA<ActivationException>().having(
          (e) => e.cause,
          'cause',
          isA<StateError>(),
        ),
      );
      await root.dispose();
    });

    test('raises ReentrantMutationError from inside an acquire', () async {
      final root = Scope();
      final other = root.child();
      final reentrant = Component<int>.effect(
        dependency: Dependency<int>(
          create: () async {
            await other.initialize();
            return 0;
          },
        ),
      );
      final di = root.child(module: Module(components: [reentrant]));
      await expectLater(
        di.initialize(),
        throwsA(isA<ReentrantMutationError>()),
      );
      await root.dispose();
    });
  });

  group('scope dispose', () {
    test('does not retry a failed activation of another scope', () async {
      const base = DiKey<int>(name: 'base');
      var attempts = 0;
      final root = Scope(
        module: Module(components: [Component<int>.value(value: 1, key: base)]),
      );
      final reports = <DiException>[];
      root.errors.listen(reports.add);
      final reader = root.child(
        module: Module(
          components: [
            Component<int>(
              key: const DiKey<int>(name: 'reader'),
              dependency: Dependency.require<int>(key: base).map((value) {
                attempts++;
                throw StateError('reader fails');
              }),
            ),
          ],
        ),
      );
      // The reader waits, and the root wakes it: an automatic activation
      // that fails and leaves the node failed, with its requirement met.
      await reader.initialize();
      await root.initialize();
      expect(attempts, 1);
      expect(reader.nodes.single.state.phase, NodePhase.activationFailed);

      final sibling = root.child(
        module: Module(
          components: [
            Component<int>.value(
              value: 2,
              key: const DiKey<int>(name: 'other'),
            ),
          ],
        ),
      );
      // The closing reconciliation of `initialize` retries the failed
      // reader once, as every reconciliation does.
      await sibling.initialize();
      final before = attempts;
      final reported = reports.length;
      await sibling.dispose();

      // A lookup reads only ancestors, so no node outside the sibling read
      // its bindings, and the disposal does not reconcile.
      expect(attempts, before, reason: 'the disposal retried the reader');
      expect(reader.nodes.single.state.phase, NodePhase.activationFailed);
      expect(reports, hasLength(reported));
      await root.dispose();
    });

    test('releases in reverse declaration order', () async {
      final log = <String>[];
      final di = Scope(
        module: Module(
          components: [
            _node('a', [], log: log),
            _node('b', ['a'], log: log),
            _node('c', ['b'], log: log),
          ],
        ),
      );
      await di.initialize();
      final members = di.nodes;
      log.clear();
      await di.dispose();
      expect(log, ['down c', 'down b', 'down a']);
      expect(members.map((m) => m.isActive), everyElement(isFalse));
    });

    test('follows declaration order for independent members', () async {
      final log = <String>[];
      final di = Scope(
        module: Module(
          components: [
            _node('a', [], log: log),
            _node('b', [], log: log),
            _node('c', [], log: log),
          ],
        ),
      );
      await di.initialize();
      log.clear();
      await di.dispose();
      expect(log, ['down c', 'down b', 'down a']);
    });

    test('attempts every cleanup and aggregates failures', () async {
      final log = <String>[];
      final di = Scope(
        module: Module(
          components: [
            _brittle('a', log: log),
            _node('b', [], log: log),
            _brittle('c', log: log),
          ],
        ),
      );
      await di.initialize();
      log.clear();
      await expectLater(
        di.dispose(),
        throwsA(
          isA<DisposeException>().having(
            (e) => e.disposeFailures.map((i) => i.owner).toList(),
            'owners',
            ['c', 'a'],
          ),
        ),
      );
      expect(log, ['down c', 'down b', 'down a']);
      expect(di.nodes.map((m) => m.isActive), everyElement(isFalse));
      await di.dispose();
      expect(log, hasLength(3), reason: 'a second dispose does nothing');
    });

    test('twice, even concurrently, releases once', () async {
      final log = <String>[];
      final di = Scope(
        module: Module(components: [_node('a', [], log: log)]),
      );
      await di.initialize();
      log.clear();
      await Future.wait([di.dispose(), di.dispose()]);
      await di.dispose();
      expect(log, ['down a']);
    });

    test('withdraws publishers from descendant consumers', () async {
      final log = <String>[];
      final root = Scope(module: Module(components: [_node('p', [])]));
      final child = root.child(
        module: Module(
          components: [
            _node('outside', ['p'], log: log),
          ],
        ),
      );
      await root.initialize();
      await child.initialize();
      final consumer = child.nodes.single;
      expect(consumer.isActive, isTrue);
      await root.dispose();
      expect(consumer.isActive, isFalse);
      expect(log, ['up outside', 'down outside']);
    });

    test('tears the module down and a later dispose is safe', () async {
      final root = Scope();
      final log = <String>[];
      final scope = root.child(
        module: Module(
          components: [
            _node('a', [], log: log),
            _node('b', ['a'], log: log),
          ],
        ),
      );
      await scope.initialize();
      log.clear();
      await scope.dispose();
      expect(log, ['down b', 'down a']);
      await scope.dispose();
      expect(log, hasLength(2));
      await root.dispose();
    });
  });

  group('scope.nodes', () {
    test('member finds a handle by the key it publishes', () async {
      final log = <String>[];
      final di = Scope(
        module: Module(
          components: [
            _node('p', [], log: log),
            _node('q', ['p'], log: log),
          ],
        ),
      );
      expect(() => di.node(key: _k('p')), throwsStateError);
      await di.initialize();

      final q = di.node(key: _k('q'));
      expect(q.value, 2, reason: 'typed as the key type');
      expect(q.isActive, isTrue);
      expect(() => di.node(key: _k('missing')), throwsArgumentError);

      log.clear();
      await di.node(key: _k('p')).dispose();
      expect(log, ['down q', 'down p']);
      expect(q.isActive, isFalse, reason: 'every handle shares one node');
      expect(di.nodes.last.isActive, isFalse);
      await di.dispose();
    });

    test('lists one handle per member in declaration order', () async {
      final di = Scope(
        module: Module(
          components: [
            _node('a', []),
            _node('b', ['a']),
            _node('c', ['b']),
          ],
        ),
      );
      expect(di.nodes, isEmpty, reason: 'before initialize');
      await di.initialize();
      expect(di.nodes, hasLength(3));
      expect(di.nodes.map((m) => m.value), [1, 2, 3]);
      expect(di.nodes.every((m) => m.isActive), isTrue);
      expect(() => di.nodes.add(di.nodes.first), throwsUnsupportedError);
      await di.dispose();
    });

    test('a member reads and reports activity', () async {
      final root = Scope(
        module: Module(
          components: [Component<int>.value(value: 10, key: _k('gate'))],
        ),
      );
      final di = root.child(
        module: Module(
          components: [
            _node('m', ['gate']),
            _node('s', ['gate']),
          ],
        ),
      );
      await di.initialize();
      final member = di.nodes[0];
      final other = di.nodes[1];

      // Dormant: same state, same error, same missing key.
      expect(member.isActive, other.isActive);
      expect(member.isActive, isFalse);
      expect(member.missing, [_k('gate')]);
      for (final read in [() => member.value, () => other.value]) {
        expect(
          read,
          throwsA(
            isA<InactiveNodeException>().having((e) => e.missing, 'missing', [
              _k('gate'),
            ]),
          ),
        );
      }

      // Active: same state, same value.
      await root.initialize();
      expect(member.isActive, isTrue);
      expect(other.isActive, isTrue);
      expect(member.value, 11);
      expect(other.value, 11);
      expect(member.missing, isEmpty);

      // Disposed: same state and error.
      await member.dispose();
      await other.dispose();
      expect(member.isActive, isFalse);
      expect(other.isActive, isFalse);
      for (final read in [() => member.value, () => other.value]) {
        expect(
          read,
          throwsA(
            isA<InactiveNodeException>().having(
              (e) => e.missing,
              'missing',
              isEmpty,
            ),
          ),
        );
      }
      await root.dispose();
    });

    test('disposing one member leaves its siblings and scope alone', () async {
      final log = <String>[];
      final di = Scope(
        module: Module(
          components: [
            _node('a', [], log: log),
            _node('b', [], log: log),
            _node('c', [], log: log),
          ],
        ),
      );
      await di.initialize();
      log.clear();
      await di.nodes[1].dispose();
      expect(log, ['down b']);
      expect(di.nodes.map((m) => m.isActive), [true, false, true]);
      expect(di.maybeGet(key: _k('b')), isNull);
      expect(di.get(key: _k('a')), 1);
      expect(di.get(key: _k('c')), 1);
      await di.nodes[1].dispose();
      expect(log, ['down b'], reason: 'a second member dispose does nothing');
      expect(di.isInitialized, isTrue);
      await di.dispose();
    });

    test('scope dispose skips members that are already disposed', () async {
      final log = <String>[];
      final di = Scope(
        module: Module(
          components: [
            _node('a', [], log: log),
            _node('b', [], log: log),
            _node('c', [], log: log),
            _node('d', [], log: log),
          ],
        ),
      );
      await di.initialize();
      await di.nodes[1].dispose();
      await di.nodes[3].dispose();
      log.clear();
      await di.dispose();
      expect(log, ['down c', 'down a'], reason: 'no double deactivate');
      await di.dispose();
      expect(log, hasLength(2));
    });

    test(
      'scope dispose with every member already disposed is a no-op',
      () async {
        final log = <String>[];
        final di = Scope(
          module: Module(
            components: [
              _node('a', [], log: log),
              _node('b', [], log: log),
            ],
          ),
        );
        await di.initialize();
        for (final member in di.nodes) {
          await member.dispose();
        }
        log.clear();
        await di.dispose();
        expect(log, isEmpty);
      },
    );

    test(
      'scope dispose still aggregates failures of the remaining members',
      () async {
        final di = Scope(
          module: Module(
            components: [_brittle('a'), _brittle('b'), _brittle('c')],
          ),
        );
        await di.initialize();
        await expectLater(
          di.nodes[1].dispose(),
          throwsA(
            isA<DisposeException>().having(
              (e) => e.disposeFailures.map((i) => i.owner).toList(),
              'owners',
              ['b'],
            ),
          ),
        );
        await expectLater(
          di.dispose(),
          throwsA(
            isA<DisposeException>().having(
              (e) => e.disposeFailures.map((i) => i.owner).toList(),
              'owners',
              ['c', 'a'],
            ),
          ),
        );
      },
    );

    test('disposing a publisher member withdraws dependents, which wake '
        'when another component publishes the key', () async {
      final log = <String>[];
      // `root` is pending: it publishes `p` only after the first `p` is gone.
      final root = Scope(
        module: Module(components: [_node('p', [], log: log)]),
      );
      final di = root.child(
        module: Module(
          components: [
            _node('p', [], log: log),
            _node('q', ['p'], log: log),
          ],
        ),
      );
      final outsideScope = di.child(
        module: Module(
          components: [
            _node('r', ['p'], log: log),
          ],
        ),
      );
      await di.initialize();
      await outsideScope.initialize();
      final outside = outsideScope.nodes.single;
      log.clear();

      await di.nodes[0].dispose();
      expect(log, [
        'down r',
        'down q',
        'down p',
      ], reason: 'dependents go first');
      expect(di.nodes[1].isActive, isFalse);
      expect(outside.isActive, isFalse);
      expect(
        () => di.nodes[1].value,
        throwsA(
          isA<InactiveNodeException>().having((e) => e.missing, 'missing', [
            _k('p'),
          ]),
        ),
      );

      // Another component publishes the key again: dependents wake.
      log.clear();
      await root.initialize();
      expect(root.nodes.single.isActive, isTrue);
      expect(di.nodes[1].isActive, isTrue);
      expect(outside.isActive, isTrue);
      expect(log, ['up p', 'up q', 'up r']);

      // The disposed member stays disposed; the scope disposes the rest.
      log.clear();
      expect(di.nodes[0].isActive, isFalse);
      await outsideScope.dispose();
      expect(log, ['down r']);
      log.clear();
      await di.dispose();
      expect(log, ['down q'], reason: 'only the remaining member is released');
      await root.dispose();
    });
  });

  group('collection shape (V-T-RT-LC-019)', () {
    const features = DiSetKey<int>(name: 'features');
    const tabs = DiSetKey<int>(name: 'tabs');
    const routes = DiMapKey<int>(name: 'routes');
    final shell = DiKey<int>(name: 'shell');
    final audit = DiKey<int>(name: 'audit');

    Component<int> into(DiSetKey<int> key, int value) => Component<int>.into(
      key: key,
      dependency: Dependency<int>(create: () => value),
      debugLabel: '${key.name}$value',
    );
    Component<int> entry(String id, int value) => Component<int>(
      key: routes.entryKey(id),
      dependency: Dependency<int>(create: () => value),
    );
    // Reads the features strictly and the routes optionally.
    final strictShell = Component<int>(
      key: shell,
      dependency: (
        Dependency.requireSet(key: features),
        Dependency.maybeMap(key: routes),
      ).zip.map((v) => v.$1.length + v.$2.length),
    );
    // Reads the routes strictly and the features optionally.
    final optionalAudit = Component<int>(
      key: audit,
      dependency: (
        Dependency.maybeSet(key: features),
        Dependency.requireMap(key: routes),
      ).zip.map((v) => v.$1.length + v.$2.length),
    );
    final mobile = Module(
      debugLabel: 'mobile',
      components: [
        into(features, 1),
        into(features, 2),
        into(tabs, 3),
        entry('home', 10),
        entry('search', 11),
        strictShell,
      ],
    );
    final web = Module(
      debugLabel: 'web',
      components: [
        into(features, 4),
        entry('home', 12),
        entry('admin', 13),
        optionalAudit,
      ],
    );
    final testing = mobile.overriddenBy(
      Module(components: [entry('home', 99)]),
    );

    test('a reader keeps its strict and optional collection reads apart', () {
      expect(strictShell.collectionKeys, {features});
      expect(strictShell.optionalCollectionKeys, {routes});
      expect(optionalAudit.collectionKeys, {routes});
      expect(optionalAudit.optionalCollectionKeys, {features});
      expect(strictShell.requires, isEmpty);
      expect(strictShell.optional, isEmpty);
      expect(strictShell.reads, {features, routes});

      final strict = Dependency.requireSet(key: features);
      final optional = Dependency.maybeMap(key: routes);
      expect(strict.collectionKeys, {features});
      expect(strict.optionalCollectionKeys, isEmpty);
      expect(optional.collectionKeys, isEmpty);
      expect(optional.optionalCollectionKeys, {routes});
      expect(strict.requires, isEmpty);
      expect(optional.optional, isEmpty);
      final composed = strict.map((s) => s.length).lazy();
      expect(composed.collectionKeys, {features});
    });

    test('a set contribution publishes no key and names its set key', () {
      final contribution = into(features, 1);
      expect(contribution.key, isNull);
      expect(contribution.contributesTo, features);
      expect(entry('home', 1).key, routes.entryKey('home'));
      expect(entry('home', 1).contributesTo, isNull);
      expect(strictShell.contributesTo, isNull);
    });

    test('entry keys are in publishes and contributes counts the set '
        'contributors', () {
      expect(mobile.publishes, {
        routes.entryKey('home'),
        routes.entryKey('search'),
        shell,
      });
      expect(web.publishes, {
        routes.entryKey('home'),
        routes.entryKey('admin'),
        audit,
      });
      expect(mobile.contributes, {features: 2, tabs: 1});
      expect(web.contributes, {features: 1});
      expect(testing.contributes, mobile.contributes);
      expect(Module(components: [strictShell]).contributes, isEmpty);
    });

    test('a collection read is in reads and not in requires', () {
      for (final module in [mobile, web, testing]) {
        expect(module.reads, {
          features,
          routes,
        }, reason: '${module.debugLabel}');
        expect(module.requires, isEmpty, reason: '${module.debugLabel}');
        expect(module.reads, isNot(contains(tabs)));
      }
    });

    test('overriddenBy replaces one entry by its entry key', () {
      final keys = [for (final m in testing.components) m.key];
      expect(keys, [
        null,
        null,
        null,
        routes.entryKey('home'),
        routes.entryKey('search'),
        shell,
      ]);
      expect(identical(testing.components[3], mobile.components[3]), isFalse);
      expect(identical(testing.components[4], mobile.components[4]), isTrue);
      expect(testing.publishes, mobile.publishes);
      expect(mobile.components, hasLength(6), reason: 'the source is intact');
      expect(
        () => mobile.overriddenBy(Module(components: [entry('missing', 1)])),
        throwsArgumentError,
      );
    });

    test('only where selects a set contribution', () {
      expect(
        () => mobile.replacing(key: features, component: into(features, 5)),
        throwsArgumentError,
      );
      expect(() => mobile.without(key: features), throwsArgumentError);
      expect(
        () => mobile.overriddenBy(Module(components: [into(features, 5)])),
        throwsArgumentError,
      );

      final fewer = mobile.where((m) => m.contributesTo != features);
      expect(fewer.contributes, {tabs: 1});
      expect(fewer.components, hasLength(4));
      expect(fewer.publishes, mobile.publishes);
      final none = mobile.where((m) => m.contributesTo == null);
      expect(none.contributes, isEmpty);
      expect(none.reads, {features, routes});
      expect(mobile.contributes, {features: 2, tabs: 1}, reason: 'unchanged');
    });

    test('Module.all and + sum the contributors of each set key', () {
      final both = mobile + web;
      expect(both.contributes, {features: 3, tabs: 1});
      expect(both.reads, {features, routes});
      expect(both.requires, isEmpty);
    });

    test('the derived sets reject mutation', () {
      expect(() => mobile.contributes[tabs] = 9, throwsUnsupportedError);
      expect(() => mobile.contributes.remove(tabs), throwsUnsupportedError);
      expect(() => mobile.publishes.add(shell), throwsUnsupportedError);
      expect(() => mobile.reads.add(tabs), throwsUnsupportedError);
      expect(() => mobile.requires.add(shell), throwsUnsupportedError);
      expect(
        () => strictShell.collectionKeys.add(tabs),
        throwsUnsupportedError,
      );
      expect(
        () => strictShell.optionalCollectionKeys.add(tabs),
        throwsUnsupportedError,
      );
      expect(
        () => Dependency.requireSet(key: features).collectionKeys.add(tabs),
        throwsUnsupportedError,
      );
      expect(
        () =>
            Dependency.maybeSet(key: features).optionalCollectionKeys.add(tabs),
        throwsUnsupportedError,
      );
      expect(
        () => Dependency.requireMap(key: routes).collectionKeys.clear(),
        throwsUnsupportedError,
      );
    });
  });

  group('Scope.module (V-T-RT-LC-033)', () {
    test('returns the module of the constructor in each phase', () async {
      final gate = Completer<void>();
      final rootModule = Module(
        components: [
          Component<int>(
            key: _k('a'),
            dependency: Dependency<int>(
              create: () async {
                await gate.future;
                return 1;
              },
            ),
          ),
        ],
      );
      final childModule = Module(
        components: [
          _node('b', ['a']),
        ],
      );
      final root = Scope(module: rootModule);
      final child = root.child(module: childModule);

      /// Reads both modules. A read does not change the revision.
      void expectModules(String when) {
        final before = root.revision;
        expect(identical(root.module, rootModule), isTrue, reason: when);
        expect(identical(child.module, childModule), isTrue, reason: when);
        expect(root.revision, before, reason: when);
      }

      // A listener reads the module before the accepted `dispose` call
      // returns.
      var readInDisposeCall = false;
      root.addListener(() {
        if (root.state.phase == ScopePhase.disposeRequested) {
          readInDisposeCall = identical(root.module, rootModule);
        }
      });

      expectModules('before initialize');
      final initialized = root.initialize();
      await Future<void>.delayed(Duration.zero);
      expect(root.state.phase, ScopePhase.initializing);
      expectModules('while initialize runs');
      gate.complete();
      await initialized;
      await child.initialize();
      expectModules('after initialize');

      // The component at a position is the component of the node state at
      // that position.
      for (final scope in [root, child]) {
        final components = scope.module.components;
        expect(scope.state.nodeStates, hasLength(components.length));
        for (var i = 0; i < components.length; i++) {
          expect(components[i].key, scope.state.nodeStates[i].key);
        }
      }
      // The module holds the declarations of its scope only.
      expect(
        child.module.components.any(root.module.components.contains),
        isFalse,
      );
      // `requires` states a declared key, not a key that does not resolve.
      expect(child.module.requires, contains(_k('a')));
      expect(child.nodes.single.state.phase, NodePhase.active);
      expect(child.nodes.single.missing, isEmpty);

      final disposed = root.dispose();
      expect(root.state.phase, ScopePhase.disposeRequested);
      expect(readInDisposeCall, isTrue);
      expectModules('after the accepted dispose call');
      await disposed;
      expect(root.state.phase, ScopePhase.disposed);
      expect(child.state.phase, ScopePhase.disposed);
      expectModules('after the disposal');
    });

    test('a scope without a module returns one empty module', () async {
      final root = Scope();
      final child = root.child();
      for (final scope in [root, child]) {
        expect(scope.module.components, isEmpty);
        expect(identical(scope.module, scope.module), isTrue);
      }
      await root.initialize();
      expect(root.module.components, isEmpty);
      await root.dispose();
      expect(root.module.components, isEmpty);
      expect(child.module.components, isEmpty);
    });

    test('keeps the module after a failed initialize', () async {
      final log = <String>[];
      final module = Module(components: [_failing('x', log)]);
      final scope = Scope(module: module);
      await expectLater(scope.initialize(), throwsA(anything));
      expect(scope.state.phase, ScopePhase.declared);
      expect(identical(scope.module, module), isTrue);
    });

    test('an edit of the module does not change the scope', () async {
      final module = Module(components: [_node('a', [])]);
      final first = Scope(module: module);
      final edited = module.replacing(key: _k('a'), component: _node('a', []));
      final second = Scope(module: edited);
      expect(identical(edited, module), isFalse);
      expect(identical(second.module, edited), isTrue);
      expect(identical(first.module, module), isTrue);
      expect(first.module.components.single, isNot(edited.components.single));
    });
  });

  group('initialize cost', () {
    test('creates 2000 components with random-order dependencies', () async {
      const count = 2000;
      final random = Random(7);
      final deps = <int, List<int>>{
        for (var i = 0; i < count; i++)
          i: i == 0
              ? const []
              : {for (var j = 0; j < 3; j++) random.nextInt(i)}.toList(),
      };
      final order = List<int>.generate(count, (i) => i)..shuffle(random);
      final module = Module(
        components: [
          for (final i in order)
            _node('m$i', [for (final d in deps[i]!) 'm$d']),
        ],
      );

      final di = Scope(module: module);
      final watch = Stopwatch()..start();
      await di.initialize();
      watch.stop();
      // ignore: avoid_print
      print(
        'initialize($count, random order): ${watch.elapsedMilliseconds} ms',
      );

      for (var i = 0; i < count; i++) {
        expect(di.maybeGet(key: _k('m$i')), isNotNull, reason: 'm$i');
      }
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));

      final dispose = Stopwatch()..start();
      await di.dispose();
      dispose.stop();
      // ignore: avoid_print
      print('dispose($count): ${dispose.elapsedMilliseconds} ms');
      expect(dispose.elapsed, lessThan(const Duration(seconds: 1)));
    });
    // V-T-RT-LC-025: a walk over the committed reads on every read makes
    // these quadratic. A read of a node that no node reads yet needs no walk.
    for (final (name, deps) in <(String, List<int> Function(int))>[
      ('chain', (i) => i == 0 ? const [] : [i - 1]),
      ('two predecessors', (i) => [if (i >= 1) i - 1, if (i >= 2) i - 2]),
      ('star', (i) => i == 0 ? const [] : const [0]),
    ]) {
      test('initializes 4000 members, $name, within 1 s', () async {
        const count = 4000;
        final module = Module(
          components: [
            for (var i = 0; i < count; i++)
              _node('m$i', [for (final d in deps(i)) 'm$d']),
          ],
        );
        final di = Scope(module: module);
        final watch = Stopwatch()..start();
        await di.initialize();
        watch.stop();
        // ignore: avoid_print
        print('initialize($count, $name): ${watch.elapsedMilliseconds} ms');
        expect(di.maybeGet(key: _k('m${count - 1}')), isNotNull);
        expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
        await di.dispose();
      });
    }
    // A scan of every member for each required key, or of every unstarted
    // node after each release, makes this quadratic: the chain then takes
    // seconds.
    test(
      'initializes and disposes a chain of 32000 members within 1 s each',
      () async {
        const count = 32000;
        final module = Module(
          components: [
            for (var i = 0; i < count; i++)
              _node('m$i', [if (i > 0) 'm${i - 1}']),
          ],
        );
        final di = Scope(module: module);
        final watch = Stopwatch()..start();
        await di.initialize();
        final initialized = watch.elapsed;
        watch.reset();
        await di.dispose();
        final disposed = watch.elapsed;
        // ignore: avoid_print
        print(
          'initialize($count, chain): ${initialized.inMilliseconds} ms, '
          'dispose: ${disposed.inMilliseconds} ms',
        );
        expect(initialized, lessThan(const Duration(seconds: 1)));
        expect(disposed, lessThan(const Duration(seconds: 1)));
      },
    );
  });

  group('members that require absent keys (V-T-RT-LC-036)', () {
    // `a` requires nothing. `b` requires `a`. `c` requires `b`. `d` requires
    // the key `gone`, which no member publishes. `e` requires `d`. `f`
    // requires `gone`. `g` reads `gone` optionally.
    Module variant() => Module(
      components: [
        _node('a', []),
        _node('b', ['a']),
        _node('c', ['b']),
        _node('d', ['gone']),
        _node('e', ['d']),
        _node('f', ['gone']),
        Component<int>(
          dependency: Dependency.maybe<int>(
            key: _k('gone'),
          ).map((value) => value ?? 0),
          debugLabel: 'g',
          key: _k('g'),
        ),
      ],
      debugLabel: 'variant',
    );

    List<String> labels(Module module) => [
      for (final member in module.components) member.label,
    ];

    const features = DiSetKey<int>(name: 'features');
    const routes = DiMapKey<int>(name: 'routes');

    // A set contribution and a map entry that each require `gone`, a strict
    // reader of the set key, a strict reader of the map key, and a member
    // that requires the entry key.
    Module secondModule() => Module(
      components: [
        Component<int>.into(
          key: features,
          dependency: Dependency.require<int>(key: _k('gone')),
          debugLabel: 'contribution',
        ),
        Component<int>(
          key: routes.entryKey('home'),
          dependency: Dependency.require<int>(key: _k('gone')),
          debugLabel: 'entry',
        ),
        Component<int>(
          key: _k('setReader'),
          dependency: Dependency.requireSet(
            key: features,
          ).map((set) => set.length),
          debugLabel: 'setReader',
        ),
        Component<int>(
          key: _k('mapReader'),
          dependency: Dependency.requireMap(
            key: routes,
          ).map((map) => map.length),
          debugLabel: 'mapReader',
        ),
        Component<int>(
          key: _k('entryReader'),
          dependency: Dependency.require<int>(key: routes.entryKey('home')),
          debugLabel: 'entryReader',
        ),
      ],
      debugLabel: 'second',
    );

    // `self` requires `gone` and the key that it publishes. `reader`
    // requires that key.
    Module selfModule() => Module(
      components: [
        Component<int>(
          key: _k('self'),
          dependency: (
            Dependency.require<int>(key: _k('gone')),
            Dependency.require<int>(key: _k('self')),
          ).zip.map((v) => v.$1 + v.$2),
          debugLabel: 'self',
        ),
        _node('reader', ['self']),
      ],
    );

    // `p1` and `p2` publish the key `p`. `p1` requires `gone`. `third`
    // requires `p`.
    Module twinModule() => Module(
      components: [
        Component<int>(
          key: _k('p'),
          dependency: Dependency.require<int>(key: _k('gone')),
          debugLabel: 'p1',
        ),
        Component<int>(
          key: _k('p'),
          dependency: Dependency<int>(create: () => 1),
          debugLabel: 'p2',
        ),
        Component<int>(
          key: _k('third'),
          dependency: Dependency.require<int>(key: _k('p')),
          debugLabel: 'third',
        ),
      ],
    );

    // `h` requires `d`. `i` requires `a`. `j` publishes the key of `e`. `k`
    // requires `e`. `m` publishes the key of `f` and requires it.
    Module childModule() => Module(
      components: [
        _node('h', ['d']),
        _node('i', ['a']),
        Component<int>(
          key: _k('e'),
          dependency: Dependency<int>(create: () => 1),
          debugLabel: 'j',
        ),
        _node('k', ['e']),
        Component<int>(
          key: _k('f'),
          dependency: Dependency.require<int>(key: _k('f')),
          debugLabel: 'm',
        ),
      ],
      debugLabel: 'child',
    );

    test('requiring holds the members behind an absent key, in order', () {
      final source = variant();
      final removed = source.requiring(keys: {_k('gone')});
      final rest = source.withoutRequiring(keys: {_k('gone')});

      expect(labels(removed), ['d', 'e', 'f']);
      expect(removed.origins, ['variant', 'variant', 'variant']);
      expect(removed.debugLabel, 'variant');
      expect(labels(rest), ['a', 'b', 'c', 'g']);
      expect(rest.debugLabel, 'variant');
      expect(labels(source), ['a', 'b', 'c', 'd', 'e', 'f', 'g']);
      expect(removed, isNot(same(source)));
      expect(rest, isNot(same(source)));
    });

    // Runs both edits and checks the two properties of `withoutRequiring`,
    // that each source keeps its members, and that each result is a new
    // module. Every case below passes through it.
    ({Module removed, Module rest}) check(
      Module source,
      Iterable<DiKeyBase> keys, {
      Iterable<DiKeyBase> ancestorKeys = const <DiKeyBase>[],
    }) {
      final absent = Set<DiKeyBase>.of(keys);
      final ancestors = Set<DiKeyBase>.of(ancestorKeys);
      final components = List<ComponentBase>.of(source.components);
      final origins = List<String?>.of(source.origins);
      final removed = source.requiring(keys: absent, ancestorKeys: ancestors);
      final rest = source.withoutRequiring(
        keys: absent,
        ancestorKeys: ancestors,
      );

      for (final member in rest.components) {
        expect(
          member.requires.intersection(absent),
          isEmpty,
          reason: '${member.label} requires a key of $absent',
        );
      }
      expect(
        rest.requires.difference({...source.requires, ...ancestors}),
        isEmpty,
        reason: 'the removal adds no required key',
      );
      expect(
        removed.components.length + rest.components.length,
        components.length,
      );
      expect(source.components, orderedEquals(components));
      expect(source.origins, origins);
      expect(removed, isNot(same(source)));
      expect(rest, isNot(same(source)));
      expect(removed, isNot(same(rest)));
      return (removed: removed, rest: rest);
    }

    test('requiring a key of a member holds the members that read it', () {
      final source = variant();
      final (:removed, :rest) = check(source, {_k('a')});
      expect(labels(removed), ['b', 'c']);
      expect(labels(removed), isNot(contains('a')));
      expect(labels(rest), ['a', 'd', 'e', 'f', 'g']);
    });

    test('ancestorKeys keeps the readers of a key that an ancestor holds', () {
      final source = variant();
      final gone = _k('gone');
      final ancestor = check(source, {gone}, ancestorKeys: {_k('d')});
      expect(labels(ancestor.removed), ['d', 'f']);
      expect(labels(ancestor.removed), isNot(contains('e')));
      expect(labels(ancestor.rest), ['a', 'b', 'c', 'e', 'g']);

      final held = check(source, {gone}, ancestorKeys: {gone});
      final plain = check(source, {gone});
      expect(labels(held.removed), labels(plain.removed));
      expect(labels(held.rest), labels(plain.rest));
      expect(held.removed.origins, plain.removed.origins);
      expect(held.removed.debugLabel, plain.removed.debugLabel);
    });

    group('a key that no member requires', () {
      for (final (name, key) in <(String, DiKeyBase)>[
        ('a plain key', _k('nobody')),
        ('a set key', features),
        ('a map key', routes),
      ]) {
        test('$name changes nothing', () {
          for (final source in [variant(), secondModule()]) {
            final (:removed, :rest) = check(source, {key});
            expect(removed.components, isEmpty);
            expect(removed.origins, isEmpty);
            expect(rest.components, orderedEquals(source.components));
            expect(rest.origins, source.origins);
            expect(rest.debugLabel, source.debugLabel);
          }
        });
      }
    });

    test('a contribution and an entry that require a key are in the result, '
        'a strict collection reader is not', () {
      final source = secondModule();
      final (:removed, :rest) = check(source, {_k('gone')});
      expect(labels(removed), ['contribution', 'entry', 'entryReader']);
      expect(labels(rest), ['setReader', 'mapReader']);
      expect(removed.components.first.key, isNull);
      expect(removed.components.first.contributesTo, features);
      expect(removed.components[1].key, routes.entryKey('home'));
    });

    test('a member that requires its own key takes its readers with it, '
        'unless an ancestor holds the key', () {
      final source = selfModule();
      final gone = _k('gone');
      final without = check(source, {gone});
      expect(labels(without.removed), ['self', 'reader']);
      expect(without.rest.components, isEmpty);

      final withAncestor = check(source, {gone}, ancestorKeys: {_k('self')});
      expect(labels(withAncestor.removed), ['self']);
      expect(labels(withAncestor.rest), ['reader']);
    });

    test('a key with two publishers takes the readers of the key', () {
      final source = twinModule();
      final (:removed, :rest) = check(source, {_k('gone')});
      expect(labels(removed), ['p1', 'third']);
      expect(labels(rest), ['p2']);
    });

    test('a composition keeps the origin of each remaining position', () {
      final unlabeled = Module(
        components: [
          _node('x', ['gone']),
          _node('y', []),
        ],
      );
      final source = Module.all(modules: [variant(), unlabeled]);
      expect(source.debugLabel, isNull);
      final (:removed, :rest) = check(source, {_k('gone')});
      expect(labels(removed), ['d', 'e', 'f', 'x']);
      expect(removed.origins, ['variant', 'variant', 'variant', null]);
      expect(labels(rest), ['a', 'b', 'c', 'g', 'y']);
      expect(rest.origins, ['variant', 'variant', 'variant', 'variant', null]);
      expect(removed.debugLabel, isNull);
      expect(rest.debugLabel, isNull);
    });

    test('each source keeps its members and each result is another module', () {
      final source = variant();
      final components = List<ComponentBase>.of(source.components);
      final first = source.requiring(keys: {_k('gone')});
      final second = source.requiring(keys: {_k('gone')});
      source.withoutRequiring(keys: {_k('gone')});
      expect(source.components, orderedEquals(components));
      expect(first, isNot(same(second)));
      expect(first.components, orderedEquals(second.components));
      expect(
        source.requiring(keys: const <DiKeyBase>[]),
        isNot(same(source)),
        reason: 'an empty edit is still another module',
      );
    });

    test('a scope of the variant throws, and a scope of withoutRequiring '
        'initializes the members that remain', () async {
      final gone = _k('gone');
      final broken = Scope(module: variant());
      try {
        await expectLater(
          broken.initialize(),
          throwsA(isA<UndeclaredKeyError>()),
        );
      } finally {
        await broken.dispose();
      }

      final root = await Scope(
        module: variant().withoutRequiring(keys: {gone}),
      ).initialize();
      try {
        expect(root.get(key: _k('a')), 1);
        expect(root.get(key: _k('b')), 2);
        expect(root.get(key: _k('c')), 3);
        expect(root.get(key: _k('g')), 0);
        expect(root.findNode(key: _k('d')), isNull);
      } finally {
        await root.dispose();
      }
    });

    group('the module of a child scope', () {
      final gone = _k('gone');
      final lost = variant().requiring(keys: {gone}).publishes;
      final kept = variant().withoutRequiring(keys: {gone}).publishes;

      test('requiring holds the members behind a lost key, in order', () {
        final source = childModule();
        final (:removed, :rest) = check(source, {
          gone,
          ...lost,
        }, ancestorKeys: kept);
        expect(labels(removed), ['h', 'k', 'm']);
        expect(labels(rest), ['i', 'j']);
      });

      test('without the key of e, k stays', () {
        final source = childModule();
        final (:removed, :rest) = check(source, {
          gone,
          _k('d'),
          _k('f'),
        }, ancestorKeys: kept);
        expect(labels(removed), ['h', 'm']);
        expect(labels(rest), ['i', 'j', 'k']);
      });

      test('a child scope of withoutRequiring initializes below the parent, '
          'and the unedited module throws', () async {
        final source = childModule();
        final (:removed, :rest) = check(source, {
          gone,
          ...lost,
        }, ancestorKeys: kept);
        expect(labels(removed), ['h', 'k', 'm']);
        final root = await Scope(
          module: variant().withoutRequiring(keys: {gone}),
        ).initialize();
        try {
          final session = await root.child(module: rest).initialize();
          expect(session.get(key: _k('i')), 2);
          // `j` publishes the key of `e`.
          expect(session.get(key: _k('e')), 1);
          await session.dispose();

          final unedited = root.child(module: source);
          try {
            await expectLater(
              unedited.initialize(),
              throwsA(isA<UndeclaredKeyError>()),
            );
          } finally {
            await unedited.dispose();
          }
        } finally {
          await root.dispose();
        }
      });
    });

    test('a chain in reverse declaration order is in the result and costs '
        'little', () {
      const length = 2000;
      // Member `n$i` requires `n${i - 1}`, and `n0` requires `gone`. The
      // member that a member requires is declared after it.
      final chain = Module(
        components: [
          for (var i = length - 1; i >= 0; i--)
            _node('n$i', [i == 0 ? 'gone' : 'n${i - 1}']),
        ],
      );
      final (:removed, :rest) = check(chain, {_k('gone')});
      expect(removed.components, orderedEquals(chain.components));
      expect(rest.components, isEmpty);

      final watch = Stopwatch()..start();
      for (var i = 0; i < 100; i++) {
        chain.requiring(keys: {_k('gone')});
      }
      watch.stop();
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });
  });
}
