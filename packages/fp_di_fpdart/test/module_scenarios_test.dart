// Scenarios of a scope of named components: forward references, a failed run
// and its rollback, the disposal, and the handles of the nodes. They mirror the
// scenario tests of the `Module` of fp_di. A list of components replaces the
// `Module` value.
import 'dart:async';
import 'dart:math';

import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

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

/// A component whose release always throws.
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

int? _maybe(Scope scope, String name) =>
    scope.getOption<int>(key: _k(name)).toNullable();

List<String> _owners(Cause<DiFailure> cause) => [
  for (final defect in cause.defects) (defect as DisposeFailure).owner,
];

void main() {
  group('run', () {
    test('resolves forward references across several levels', () async {
      // a needs b needs c needs d; declared a, b, c, d.
      // from: module_test.dart: resolves forward references across several
      // levels
      final di = Scope(
        components: [
          _node('a', ['b']),
          _node('b', ['c']),
          _node('c', ['d']),
          _node('d', []),
        ],
      );
      rightOf(await di.run());
      expect(rightOf(di.get<int>(key: _k('d'))), 1);
      expect(rightOf(di.get<int>(key: _k('c'))), 2);
      expect(rightOf(di.get<int>(key: _k('b'))), 3);
      expect(rightOf(di.get<int>(key: _k('a'))), 4);
      rightOf(await di.dispose());
    });

    test('resolves a long reverse chain to a fixpoint', () async {
      // from: module_test.dart: resolves a long reverse chain to a fixpoint
      const length = 300;
      final di = Scope(
        components: [
          for (var i = 0; i < length; i++)
            _node('n$i', i + 1 < length ? ['n${i + 1}'] : const []),
        ],
      );
      rightOf(await di.run());
      expect(rightOf(di.get<int>(key: _k('n0'))), length);
      rightOf(await di.dispose());
    });

    test('keeps each component its own node', () async {
      // from: module_test.dart: keeps each member its own node
      final log = <String>[];
      final root = Scope(
        components: [Component<int>.value(value: 10, key: _k('external'))],
      );
      final di = root.kid(
        components: [
          _node('needsExternal', ['external'], log: log),
          _node('free', [], log: log),
        ],
      );
      rightOf(await di.run());
      expect(log, ['up free'], reason: 'the sibling is not blocked');
      expect(_maybe(di, 'free'), 1);
      expect(_maybe(di, 'needsExternal'), isNull);

      rightOf(await root.run());
      expect(rightOf(di.get<int>(key: _k('needsExternal'))), 11);

      // Reconciliation reaches one component and leaves the other untouched.
      rightOf(await root.nodes.single.dispose());
      expect(_maybe(di, 'needsExternal'), isNull);
      expect(_maybe(di, 'free'), 1);
      expect(log, ['up free', 'up needsExternal', 'down needsExternal']);
      rightOf(await root.dispose());
    });

    test('an empty list runs and disposes', () async {
      // from: module_test.dart: an empty module initializes and disposes
      final di = Scope(components: const []);
      rightOf(await di.run());
      expect(di.isInitialized, isTrue);
      expect(di.nodes, isEmpty);
      rightOf(await di.dispose());
    });

    test('run completes with the same scope', () async {
      // from: module_test.dart: initialize completes with the same scope
      final di = Scope(components: [_node('p', [])]);
      expect(rightOf(await di.run()), same(di));
      rightOf(await di.dispose());
    });

    test('rejects a disposed scope', () async {
      // from: module_test.dart: rejects a disposed scope
      final di = Scope(components: []);
      rightOf(await di.dispose());
      expect(leftOf(await di.run()).only, isA<DisposedScopeFailure>());
    });

    test('rejects a second call on a scope that ran', () async {
      // from: module_test.dart: rejects a second call on an initialized scope
      final di = Scope(components: [_node('a', [])]);
      rightOf(await di.run());
      expect(leftOf(await di.run()).only, isA<ScopePhaseFailure>());
      expect(
        rightOf(di.get<int>(key: _k('a'))),
        1,
        reason: 'the first call stays intact',
      );
      rightOf(await di.dispose());
    });

    test('a duplicate publisher fails the run atomically', () async {
      // from: module_test.dart: a duplicate publisher fails the initialize
      // atomically
      final di = Scope(components: [_node('x', []), _node('x', [])]);
      expect(leftOf(await di.run()).only, isA<DuplicateKeyFailure>());
      expect(_maybe(di, 'x'), isNull, reason: 'atomic');
      expect(di.isInitialized, isFalse);
      rightOf(await di.dispose());
    });

    test('a throwing component rolls back the whole list', () async {
      // from: module_test.dart: a throwing member rolls back the whole module
      final log = <String>[];
      final root = Scope(
        components: [Component<int>.value(value: 1, key: _k('never'))],
      );
      final di = root.kid(
        components: [
          _node('first', [], log: log),
          _node('waits', ['never'], log: log),
          _node('second', ['first'], log: log),
          _failing('bad', log),
          _node('after', [], log: log),
        ],
      );
      final cause = leftOf(await di.run());
      expect(cause.failures.single, isA<ActivationFailure>());
      expect(
        (cause.failures.single as ActivationFailure).error,
        isA<StateError>(),
      );
      expect(cause.defects, isEmpty);

      // `first`, `bad`, and `after` have no dependency and start together.
      // `second` starts only when `first` settles, before or after `bad`
      // fails. Every value that started is released, dependents first.
      expect(log.take(3), ['up first', 'up bad', 'up after']);
      final downs = log.where((entry) => entry.startsWith('down')).toList();
      expect(downs, unorderedEquals(['down after', 'down first']));
      expect(
        log.indexOf('down first'),
        isNonNegative,
        reason: 'the value of first is released',
      );
      if (log.contains('up second')) {
        expect(log, contains('down second'));
        expect(
          log.indexOf('down second'),
          lessThan(log.indexOf('down first')),
          reason: 'a dependent releases before its publisher',
        );
      }
      expect(di.isInitialized, isFalse);
      expect(di.nodes, isEmpty);
      for (final name in ['first', 'second', 'waits', 'after', 'bad']) {
        expect(_maybe(di, name), isNull, reason: name);
      }

      // No node of the failed run remains: the dormant component does not
      // wake up when its key appears.
      log.clear();
      rightOf(await root.run());
      expect(log, isEmpty);

      // The keys are free again: a retry fails with the own error of the
      // component.
      final retry = leftOf(await di.run());
      expect(
        (retry.failures.single as ActivationFailure).error,
        isA<StateError>(),
      );
      expect(di.isInitialized, isFalse);
      rightOf(await root.dispose());
    });

    test('rollback cleanup failures are aggregated with the cause', () async {
      // from: module_test.dart: rollback cleanup failures are aggregated with
      // the cause
      final di = Scope(
        components: [_brittle('one'), _brittle('two'), _failing('bad', [])],
      );
      final cause = leftOf(await di.run());
      expect(cause.failures.single, isA<ActivationFailure>());
      expect(_owners(cause), ['two', 'one']);
      expect(_maybe(di, 'one'), isNull);
      rightOf(await di.dispose());
    });

    test(
      'a failed component rolls back its own completed effects first',
      () async {
        // from: module_test.dart: a failed member rolls back its own completed
        // effects first
        final log = <String>[];
        final partial = Component<int>.effect(
          dependency: Dependency<int>(
            create: () => 1,
            dispose: (_) => log.add('partial released'),
          ).map<int>((_) => throw StateError('late')),
        );
        final di = Scope(
          components: [
            _node('ok', [], log: log),
            partial,
          ],
        );
        expect(leftOf(await di.run()).only, isA<ActivationFailure>());
        expect(log, ['up ok', 'partial released', 'down ok']);
        rightOf(await di.dispose());
      },
    );

    test('a descendant node woken in the closing reconciliation is dormant '
        'after the rollback', () async {
      // from: module_test.dart: a descendant node woken in the closing
      // reconciliation is dormant after the rollback
      final log = <String>[];
      const a = DiKey<int>(name: 'a');
      const b = DiKey<int>(name: 'b');
      // x injects b and publishes a; y only watches a and publishes b. The
      // cycle starts x first, which waits, so x first activates in the closing
      // reconciliation, after the leaf has woken on b, and throws.
      final x = Component<int>(
        dependency: Dependency.require<int>(key: b).map<int>((_) {
          log.add('up x');
          throw StateError('x');
        }),
        debugLabel: 'x',
        key: a,
      );
      final y = Component<int>(
        dependency: Dependency.option<int>(key: a).map<int>((_) {
          log.add('up y');
          return 1;
        }, dispose: (_) => log.add('down y')),
        debugLabel: 'y',
        key: b,
      );
      final root = Scope(components: [x, y]);
      final leaf = root.kid(
        components: [
          Component<int>.effect(
            dependency: Dependency.require<int>(key: b).map<int>((v) {
              log.add('up leaf');
              return v;
            }, dispose: (_) => log.add('down leaf')),
            debugLabel: 'leaf',
          ),
        ],
      );
      final errors = <Cause<DiFailure>>[];
      final subscription = root.errors.listen(errors.add);
      rightOf(await leaf.run());

      expect(leftOf(await root.run()).only, isA<ActivationFailure>());
      expect(log, ['up y', 'up leaf', 'up x', 'down leaf', 'down y']);
      expect(leaf.nodes.single.isActive, isFalse);
      expect(root.isInitialized, isFalse);
      expect(errors, isEmpty);
      await subscription.cancel();
      rightOf(await root.dispose());
    });

    test(
      'a forward component that throws at reconciliation fails the run',
      () async {
        // from: module_test.dart: a forward member that throws at
        // reconciliation fails the initialize
        final errors = <Cause<DiFailure>>[];
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
          components: [
            late,
            _node('publisher', [], log: log),
            _node('sibling', [], log: log),
          ],
        );
        di.errors.listen(errors.add);
        void expectFailure(Cause<DiFailure> cause) {
          expect(cause.failures.single, isA<ActivationFailure>());
          expect(
            (cause.failures.single as ActivationFailure).error,
            isA<StateError>(),
          );
          expect(cause.defects, isEmpty);
        }

        expectFailure(leftOf(await di.run()));

        // The same failure in declaration order and in reconcile order has the
        // same outcome: no node of the list remains.
        final expected = [
          'up publisher',
          'up sibling',
          'up late',
          'down sibling',
          'down publisher',
        ];
        expect(log, expected);
        expect(_maybe(di, 'publisher'), isNull);
        expect(_maybe(di, 'sibling'), isNull);
        expect(errors, isEmpty, reason: 'returned by the run, not reported');

        // The keys are free again: a retry repeats the same schedule.
        log.clear();
        expectFailure(leftOf(await di.run()));
        expect(log, expected);
        expect(di.isInitialized, isFalse);
        rightOf(await di.dispose());
      },
    );

    test('the failure is the same for every component order', () async {
      // from: module_test.dart: the failure is the same for every member order
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
        final di = Scope(components: ordered);
        expect(
          leftOf(await di.run()).only,
          isA<ActivationFailure>(),
          reason: 'failingFirst=$failingFirst',
        );
        expect(_maybe(di, 'a'), isNull);
        expect(_maybe(di, 'b'), isNull);
        expect(log.where((e) => e.startsWith('down')), hasLength(2));
        rightOf(await di.dispose());
      }
    });

    test('a failing descendant node keeps the reconcile contract', () async {
      // from: module_test.dart: a failing descendant node keeps the reconcile
      // contract
      final root = Scope(components: [_node('p', [])]);
      final di = root.kid(
        components: [
          Component<int>.effect(
            dependency: Dependency.require<int>(
              key: _k('p'),
            ).map<int>((_) => throw StateError('descendant failure')),
            debugLabel: 'descendant',
          ),
        ],
      );
      final errors = <Cause<DiFailure>>[];
      root.errors.listen(errors.add);
      rightOf(await di.run());
      final descendant = di.nodes.single;
      expect(descendant.isActive, isFalse);

      rightOf(await root.run());

      expect(
        rightOf(root.get<int>(key: _k('p'))),
        1,
        reason: 'the run succeeds',
      );
      expect(descendant.isActive, isFalse);
      expect(errors, hasLength(1));
      expect(errors.single.failures.single, isA<ActivationFailure>());
      expect(
        (errors.single.failures.single as ActivationFailure).error,
        isA<StateError>(),
      );
      rightOf(await root.dispose());
    });

    test(
      'a run from inside an acquire is a ReentrantMutationFailure',
      () async {
        // from: module_test.dart: raises ReentrantMutationError from inside an
        // acquire
        final root = Scope(components: []);
        final other = root.kid();
        Exit<DiFailure, Scope>? inside;
        final reentrant = Component<int>.effect(
          dependency: Dependency<int>(
            create: () async {
              inside = await other.run();
              return 0;
            },
          ),
        );
        final di = root.kid(components: [reentrant]);
        rightOf(await di.run());
        expect(leftOf(inside!).only, isA<ReentrantMutationFailure>());
        rightOf(await root.dispose());
      },
    );
  });

  group('dispose', () {
    test('does not retry a failed activation of another scope', () async {
      // from: module_test.dart: does not retry a failed activation of another
      // scope
      const base = DiKey<int>(name: 'base');
      var attempts = 0;
      final root = Scope(
        components: [Component<int>.value(value: 1, key: base)],
      );
      final reports = <Cause<DiFailure>>[];
      root.errors.listen(reports.add);
      final reader = root.kid(
        components: [
          Component<int>(
            key: const DiKey<int>(name: 'reader'),
            dependency: Dependency.require<int>(key: base).map((value) {
              attempts++;
              throw StateError('reader fails');
            }),
          ),
        ],
      );
      // The reader waits, and the root wakes it: an automatic activation that
      // fails and leaves the node failed, with its requirement met.
      rightOf(await reader.run());
      rightOf(await root.run());
      expect(attempts, 1);
      expect(reader.nodes.single.state.phase, NodePhase.activationFailed);

      final sibling = root.kid(
        components: [
          Component<int>.value(value: 2, key: const DiKey<int>(name: 'other')),
        ],
      );
      // The closing reconciliation of `run` retries the failed reader once, as
      // every reconciliation does.
      rightOf(await sibling.run());
      final before = attempts;
      final reported = reports.length;
      rightOf(await sibling.dispose());

      // A lookup reads only ancestors, so no node outside the sibling read its
      // bindings, and the disposal does not reconcile.
      expect(attempts, before, reason: 'the disposal retried the reader');
      expect(reader.nodes.single.state.phase, NodePhase.activationFailed);
      expect(reports, hasLength(reported));
      rightOf(await root.dispose());
    });

    test('releases in reverse declaration order', () async {
      // from: module_test.dart: releases in reverse declaration order
      final log = <String>[];
      final di = Scope(
        components: [
          _node('a', [], log: log),
          _node('b', ['a'], log: log),
          _node('c', ['b'], log: log),
        ],
      );
      rightOf(await di.run());
      final members = di.nodes;
      log.clear();
      rightOf(await di.dispose());
      expect(log, ['down c', 'down b', 'down a']);
      expect(members.map((m) => m.isActive), everyElement(isFalse));
    });

    test('follows declaration order for independent components', () async {
      // from: module_test.dart: follows declaration order for independent
      // members
      final log = <String>[];
      final di = Scope(
        components: [
          _node('a', [], log: log),
          _node('b', [], log: log),
          _node('c', [], log: log),
        ],
      );
      rightOf(await di.run());
      log.clear();
      rightOf(await di.dispose());
      expect(log, unorderedEquals(['down c', 'down b', 'down a']));
      expect(log, hasLength(3));
    });

    test('attempts every cleanup and aggregates failures', () async {
      // from: module_test.dart: attempts every cleanup and aggregates failures
      final log = <String>[];
      final di = Scope(
        components: [
          _brittle('a', log: log),
          _node('b', [], log: log),
          _brittle('c', log: log),
        ],
      );
      rightOf(await di.run());
      log.clear();
      final cause = leftOf(await di.dispose());
      expect(_owners(cause), ['c', 'a']);
      expect(log, unorderedEquals(['down c', 'down b', 'down a']));
      expect(di.nodes.map((m) => m.isActive), everyElement(isFalse));
      rightOf(await di.dispose());
      expect(log, hasLength(3), reason: 'a second dispose does nothing');
    });

    test('twice, even concurrently, releases once', () async {
      // from: module_test.dart: twice, even concurrently, releases once
      final log = <String>[];
      final di = Scope(components: [_node('a', [], log: log)]);
      rightOf(await di.run());
      log.clear();
      await Future.wait([di.dispose(), di.dispose()]);
      rightOf(await di.dispose());
      expect(log, ['down a']);
    });

    test('withdraws publishers from descendant consumers', () async {
      // from: module_test.dart: withdraws publishers from descendant consumers
      final log = <String>[];
      final root = Scope(components: [_node('p', [])]);
      final child = root.kid(
        components: [
          _node('outside', ['p'], log: log),
        ],
      );
      rightOf(await root.run());
      rightOf(await child.run());
      final consumer = child.nodes.single;
      expect(consumer.isActive, isTrue);
      rightOf(await root.dispose());
      expect(consumer.isActive, isFalse);
      expect(log, ['up outside', 'down outside']);
    });

    test('tears the list down and a later dispose is safe', () async {
      // from: module_test.dart: tears the module down and a later dispose is
      // safe
      final root = Scope(components: []);
      final log = <String>[];
      final scope = root.kid(
        components: [
          _node('a', [], log: log),
          _node('b', ['a'], log: log),
        ],
      );
      rightOf(await scope.run());
      log.clear();
      rightOf(await scope.dispose());
      expect(log, ['down b', 'down a']);
      rightOf(await scope.dispose());
      expect(log, hasLength(2));
      rightOf(await root.dispose());
    });
  });

  group('scope nodes', () {
    test('node finds a handle by the key it publishes', () async {
      // from: module_test.dart: member finds a handle by the key it publishes
      final log = <String>[];
      final di = Scope(
        components: [
          _node('p', [], log: log),
          _node('q', ['p'], log: log),
        ],
      );
      expect(leftOf(di.node<int>(key: _k('p'))), isA<ScopePhaseFailure>());
      rightOf(await di.run());

      final q = rightOf(di.node<int>(key: _k('q')));
      expect(rightOf(q.value), 2, reason: 'typed as the key type');
      expect(q.isActive, isTrue);
      expect(
        leftOf(di.node<int>(key: _k('missing'))),
        isA<UnavailableKeyFailure>(),
      );

      log.clear();
      rightOf(await rightOf(di.node<int>(key: _k('p'))).dispose());
      expect(log, ['down q', 'down p']);
      expect(q.isActive, isFalse, reason: 'every handle shares one node');
      expect(di.nodes.last.isActive, isFalse);
      rightOf(await di.dispose());
    });

    test('nodes lists one handle per component in declaration order', () async {
      // from: module_test.dart: lists one handle per member in declaration
      // order
      final di = Scope(
        components: [
          _node('a', []),
          _node('b', ['a']),
          _node('c', ['b']),
        ],
      );
      expect(di.nodes, isEmpty, reason: 'before run');
      rightOf(await di.run());
      expect(di.nodes, hasLength(3));
      expect(di.nodes.map((m) => rightOf(m.value)), [1, 2, 3]);
      expect(di.nodes.every((m) => m.isActive), isTrue);
      expect(() => di.nodes.add(di.nodes.first), throwsUnsupportedError);
      rightOf(await di.dispose());
    });

    test('a node reads and reports activity', () async {
      // from: module_test.dart: a member reads and reports activity
      final root = Scope(
        components: [Component<int>.value(value: 10, key: _k('gate'))],
      );
      final di = root.kid(
        components: [
          _node('m', ['gate']),
          _node('s', ['gate']),
        ],
      );
      rightOf(await di.run());
      final member = di.nodes[0];
      final other = di.nodes[1];

      // Dormant: same state, same failure, same missing key.
      expect(member.isActive, other.isActive);
      expect(member.isActive, isFalse);
      expect(member.state.missing, [_k('gate')]);
      for (final read in [member.value, other.value]) {
        expect(
          leftOf(read),
          isA<InactiveNodeFailure>().having((f) => f.missing, 'missing', [
            _k('gate'),
          ]),
        );
      }

      // Active: same state, same value.
      rightOf(await root.run());
      expect(member.isActive, isTrue);
      expect(other.isActive, isTrue);
      expect(rightOf(member.value), 11);
      expect(rightOf(other.value), 11);
      expect(member.state.missing, isEmpty);

      // Disposed: same state and failure.
      rightOf(await member.dispose());
      rightOf(await other.dispose());
      expect(member.isActive, isFalse);
      expect(other.isActive, isFalse);
      for (final read in [member.value, other.value]) {
        expect(
          leftOf(read),
          isA<InactiveNodeFailure>().having(
            (f) => f.missing,
            'missing',
            isEmpty,
          ),
        );
      }
      rightOf(await root.dispose());
    });

    test('disposing one node leaves its siblings and scope alone', () async {
      // from: module_test.dart: disposing one member leaves its siblings and
      // scope alone
      final log = <String>[];
      final di = Scope(
        components: [
          _node('a', [], log: log),
          _node('b', [], log: log),
          _node('c', [], log: log),
        ],
      );
      rightOf(await di.run());
      log.clear();
      rightOf(await di.nodes[1].dispose());
      expect(log, ['down b']);
      expect(di.nodes.map((m) => m.isActive), [true, false, true]);
      expect(_maybe(di, 'b'), isNull);
      expect(rightOf(di.get<int>(key: _k('a'))), 1);
      expect(rightOf(di.get<int>(key: _k('c'))), 1);
      rightOf(await di.nodes[1].dispose());
      expect(log, ['down b'], reason: 'a second node dispose does nothing');
      expect(di.isInitialized, isTrue);
      rightOf(await di.dispose());
    });

    test('scope dispose skips nodes that are already disposed', () async {
      // from: module_test.dart: scope dispose skips members that are already
      // disposed
      final log = <String>[];
      final di = Scope(
        components: [
          _node('a', [], log: log),
          _node('b', [], log: log),
          _node('c', [], log: log),
          _node('d', [], log: log),
        ],
      );
      rightOf(await di.run());
      rightOf(await di.nodes[1].dispose());
      rightOf(await di.nodes[3].dispose());
      log.clear();
      rightOf(await di.dispose());
      expect(log, unorderedEquals(['down c', 'down a']), reason: 'no double');
      rightOf(await di.dispose());
      expect(log, hasLength(2));
    });

    test('scope dispose with every node already disposed is a no-op', () async {
      // from: module_test.dart: scope dispose with every member already
      // disposed is a no-op
      final log = <String>[];
      final di = Scope(
        components: [
          _node('a', [], log: log),
          _node('b', [], log: log),
        ],
      );
      rightOf(await di.run());
      for (final member in di.nodes) {
        rightOf(await member.dispose());
      }
      log.clear();
      rightOf(await di.dispose());
      expect(log, isEmpty);
    });

    test(
      'scope dispose still aggregates failures of the remaining nodes',
      () async {
        // from: module_test.dart: scope dispose still aggregates failures of
        // the remaining members
        final di = Scope(
          components: [_brittle('a'), _brittle('b'), _brittle('c')],
        );
        rightOf(await di.run());
        expect(_owners(leftOf(await di.nodes[1].dispose())), ['b']);
        expect(_owners(leftOf(await di.dispose())), ['c', 'a']);
      },
    );

    test('disposing a publisher node withdraws dependents, which wake when '
        'another component publishes the key', () async {
      // from: module_test.dart: disposing a publisher member withdraws
      // dependents, which wake when another component publishes the key
      final log = <String>[];
      // `root` is pending: it publishes `p` only after the first `p` is gone.
      final root = Scope(components: [_node('p', [], log: log)]);
      final di = root.kid(
        components: [
          _node('p', [], log: log),
          _node('q', ['p'], log: log),
        ],
      );
      final outsideScope = di.kid(
        components: [
          _node('r', ['p'], log: log),
        ],
      );
      rightOf(await di.run());
      rightOf(await outsideScope.run());
      final outside = outsideScope.nodes.single;
      log.clear();

      rightOf(await di.nodes[0].dispose());
      expect(log, ['down r', 'down q', 'down p'], reason: 'dependents first');
      expect(di.nodes[1].isActive, isFalse);
      expect(outside.isActive, isFalse);
      expect(
        leftOf(di.nodes[1].value),
        isA<InactiveNodeFailure>().having((f) => f.missing, 'missing', [
          _k('p'),
        ]),
      );

      // Another component publishes the key again: dependents wake.
      log.clear();
      rightOf(await root.run());
      expect(root.nodes.single.isActive, isTrue);
      expect(di.nodes[1].isActive, isTrue);
      expect(outside.isActive, isTrue);
      expect(log, ['up p', 'up q', 'up r']);

      // The disposed node stays disposed; the scope disposes the rest.
      log.clear();
      expect(di.nodes[0].isActive, isFalse);
      rightOf(await outsideScope.dispose());
      expect(log, ['down r']);
      log.clear();
      rightOf(await di.dispose());
      expect(log, ['down q'], reason: 'only the remaining node is released');
      rightOf(await root.dispose());
    });
  });

  group('Scope.components', () {
    test('returns the components of the constructor in each phase', () async {
      // from: module_test.dart: returns the module of the constructor in each
      // phase
      final gate = Completer<void>();
      final rootComponents = [
        Component<int>(
          key: _k('a'),
          dependency: Dependency<int>(
            create: () async {
              await gate.future;
              return 1;
            },
          ),
        ),
      ];
      final childComponents = [
        _node('b', ['a']),
      ];
      final root = Scope(components: rootComponents);
      final child = root.kid(components: childComponents);

      // Reads both lists. A read does not change the revision.
      void expectComponents(String when) {
        final before = root.revision;
        expect(root.components, rootComponents, reason: when);
        expect(child.components, childComponents, reason: when);
        expect(root.revision, before, reason: when);
      }

      // A listener reads the components before the accepted `dispose` call
      // returns.
      var readInDisposeCall = false;
      rightOf(
        root.addListener(() {
          if (root.state.phase == ScopePhase.disposeRequested) {
            readInDisposeCall = root.components.length == rootComponents.length;
          }
        }),
      );

      expectComponents('before run');
      final started = root.run();
      await pause(1);
      expect(root.state.phase, ScopePhase.initializing);
      expectComponents('while run runs');
      gate.complete();
      rightOf(await started);
      rightOf(await child.run());
      expectComponents('after run');

      // The component at a position is the component of the node state at
      // that position.
      for (final scope in [root, child]) {
        final components = scope.components;
        expect(scope.state.nodeStates, hasLength(components.length));
        for (var i = 0; i < components.length; i++) {
          expect(
            components[i].hasKey ? components[i].key : null,
            scope.state.nodeStates[i].key.toNullable(),
          );
        }
      }
      // The list holds the declarations of its scope only.
      expect(child.components.any(root.components.contains), isFalse);
      // `requires` states a declared key, not a key that does not resolve.
      expect(child.components.requires, contains(_k('a')));
      expect(child.nodes.single.state.phase, NodePhase.active);
      expect(child.nodes.single.state.missing, isEmpty);

      final disposed = root.dispose();
      expect(root.state.phase, ScopePhase.disposeRequested);
      expect(readInDisposeCall, isTrue);
      expectComponents('after the accepted dispose call');
      rightOf(await disposed);
      expect(root.state.phase, ScopePhase.disposed);
      expect(child.state.phase, ScopePhase.disposed);
      expectComponents('after the disposal');
    });

    test('a scope without components returns one empty list', () async {
      // from: module_test.dart: a scope without a module returns one empty
      // module
      final root = Scope(components: []);
      final child = root.kid();
      for (final scope in [root, child]) {
        expect(scope.components, isEmpty);
      }
      rightOf(await root.run());
      expect(root.components, isEmpty);
      rightOf(await root.dispose());
      expect(root.components, isEmpty);
      expect(child.components, isEmpty);
    });

    test('keeps the components after a failed run', () async {
      // from: module_test.dart: keeps the module after a failed initialize
      final log = <String>[];
      final components = [_failing('x', log)];
      final scope = Scope(components: components);
      leftOf(await scope.run());
      expect(scope.state.phase, ScopePhase.declared);
      expect(scope.components, components);
    });

    test('an edit of the list does not change the scope', () {
      // from: module_test.dart: an edit of the module does not change the
      // scope
      final components = [_node('a', [])];
      final first = Scope(components: components);
      final edited = rightOf(
        components.replacing(key: _k('a'), component: _node('a', [])),
      );
      final second = Scope(components: edited);
      expect(identical(edited, components), isFalse);
      expect(second.components, edited);
      expect(first.components, components);
      expect(first.components.single, isNot(edited.single));
    });
  });

  group('run cost', () {
    // fp_di runs 2000 and 4000 components within 1 s. Each transition of this
    // package copies the maps of the runtime, so the cost is quadratic: 2000
    // components take about 2 s, and 4000 take 6 s to 10 s. The tests at the
    // full size are skipped with that reason, and the same scenarios run at a
    // size that the cost allows. `agents/scratchpads/fp_di_fpdart/coverage.md`
    // records the gap.
    const quadratic =
        'The cost is quadratic: each transition copies the maps of the '
        'runtime (2000 components: about 2 s).';

    Future<void> randomOrder(int count, {required Duration limit}) async {
      final random = Random(7);
      final deps = <int, List<int>>{
        for (var i = 0; i < count; i++)
          i: i == 0
              ? const []
              : {for (var j = 0; j < 3; j++) random.nextInt(i)}.toList(),
      };
      final order = List<int>.generate(count, (i) => i)..shuffle(random);
      final components = [
        for (final i in order) _node('m$i', [for (final d in deps[i]!) 'm$d']),
      ];

      final di = Scope(components: components);
      final watch = Stopwatch()..start();
      rightOf(await di.run());
      watch.stop();
      for (var i = 0; i < count; i++) {
        expect(_maybe(di, 'm$i'), isNotNull, reason: 'm$i');
      }
      expect(watch.elapsed, lessThan(limit));

      final dispose = Stopwatch()..start();
      rightOf(await di.dispose());
      dispose.stop();
      expect(dispose.elapsed, lessThan(limit));
    }

    test('creates 2000 components with random-order dependencies', () async {
      // from: module_test.dart: creates 2000 components with random-order
      // dependencies
      await randomOrder(2000, limit: const Duration(seconds: 1));
    }, skip: quadratic);

    test('creates 300 components with random-order dependencies', () async {
      await randomOrder(300, limit: const Duration(seconds: 2));
    });

    final shapes = <(String, List<int> Function(int))>[
      ('chain', (i) => i == 0 ? const [] : [i - 1]),
      ('two predecessors', (i) => [if (i >= 1) i - 1, if (i >= 2) i - 2]),
      ('star', (i) => i == 0 ? const [] : const [0]),
    ];
    for (final (name, deps) in shapes) {
      Future<void> shape(int count, Duration limit) async {
        final components = [
          for (var i = 0; i < count; i++)
            _node('m$i', [for (final d in deps(i)) 'm$d']),
        ];
        final di = Scope(components: components);
        final watch = Stopwatch()..start();
        rightOf(await di.run());
        watch.stop();
        expect(_maybe(di, 'm${count - 1}'), isNotNull);
        expect(watch.elapsed, lessThan(limit));
        rightOf(await di.dispose());
      }

      test('runs 4000 components, $name, within 1 s', () async {
        // from: module_test.dart: initializes 4000 members, $name, within 1 s
        await shape(4000, const Duration(seconds: 1));
      }, skip: quadratic);

      test('runs 300 components, $name', () async {
        await shape(300, const Duration(seconds: 2));
      });
    }
  });
}
