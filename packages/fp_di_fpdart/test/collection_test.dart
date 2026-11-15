// Collection keys (fp_di R-UC-RT-LC-018). V-T-RT-LC-018 covers membership,
// order, and value, V-T-RT-LC-020 the reads over time, and V-T-RT-LC-021 key
// identity.
import 'dart:async';

import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

/// The interface that the contributors and the entries of the fixtures share.
abstract interface class AppScope {
  String get id;
}

final class Feature implements AppScope {
  Feature(this.id);

  @override
  final String id;

  @override
  bool operator ==(Object other) => other is Feature && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Feature($id)';
}

const features = DiSetKey<AppScope>(name: 'features');
const routes = DiMapKey<AppScope>(name: 'routes');

/// A set contribution that logs its creation and release.
Component<AppScope> contributor(String id, List<String> log) =>
    Component<AppScope>.into(
      key: features,
      debugLabel: id,
      dependency: Dependency<AppScope>(
        create: () {
          log.add('up $id');
          return Feature(id);
        },
        dispose: (_) => log.add('down $id'),
      ),
    );

/// A map entry `routes[id]` of value `value`.
Component<AppScope> entry(String id, String value, List<String> log) =>
    Component<AppScope>(
      key: routes.entryKey(id),
      debugLabel: '$id=$value',
      dependency: Dependency<AppScope>(
        create: () {
          log.add('up $id=$value');
          return Feature(value);
        },
        dispose: (_) => log.add('down $id=$value'),
      ),
    );

DiKey<List<String>> out(String name) => DiKey<List<String>>(name: name);

/// A reader of a set key. It publishes the ids of the elements, in order.
Component<List<String>> setReader(
  String name,
  List<String> log, {
  bool strict = true,
  DiSetKey<AppScope> key = features,
}) => Component<List<String>>(
  key: out(name),
  debugLabel: name,
  dependency:
      (strict
              ? Dependency.requireSet<AppScope>(key: key)
              : Dependency.optionSet<AppScope>(key: key))
          .map<List<String>>((set) {
            log.add('up $name');
            return [for (final element in set) element.id];
          }, dispose: (_) => log.add('down $name')),
);

/// A reader of a map key. It publishes `id=value` for each element, in order.
Component<List<String>> mapReader(
  String name,
  List<String> log, {
  bool strict = true,
  DiMapKey<AppScope> key = routes,
}) => Component<List<String>>(
  key: out(name),
  debugLabel: name,
  dependency:
      (strict
              ? Dependency.requireMap<AppScope>(key: key)
              : Dependency.optionMap<AppScope>(key: key))
          .map<List<String>>((map) {
            log.add('up $name');
            return [for (final e in map.entries) '${e.key}=${e.value.id}'];
          }, dispose: (_) => log.add('down $name')),
);

List<String> read(Scope scope, String name) =>
    rightOf(scope.get<List<String>>(key: out(name)));

/// The node that publishes `out(name)` in [scope].
ComponentNode<List<String>> nodeOf(Scope scope, String name) =>
    rightOf(scope.node<List<String>>(key: out(name)));

void main() {
  group('collection membership, order, and value (V-T-RT-LC-018)', () {
    test('a child read yields the parent elements first and the parent does '
        'not see the child', () async {
      // from: collection_test.dart: a child read yields the parent elements
      // first and the parent does not see the child
      final log = <String>[];
      final parent = Scope(
        components: [
          contributor('a1', log),
          entry('home', 'pHome', log),
          contributor('a2', log),
          entry('settings', 'pSettings', log),
          contributor('b1', log),
          setReader('pSet', log),
          mapReader('pMap', log),
          // A member that implements the interface and does not contribute is
          // not an element.
          Component<AppScope>.value(
            value: Feature('plain'),
            key: const DiKey<AppScope>(),
          ),
        ],
      );
      final child = parent.kid(
        components: [
          contributor('c1', log),
          entry('home', 'cHome', log),
          entry('extra', 'cExtra', log),
          setReader('cSet', log),
          mapReader('cMap', log),
        ],
      );
      rightOf(await parent.run());
      rightOf(await child.run());

      expect(read(parent, 'pSet'), ['a1', 'a2', 'b1']);
      expect(read(child, 'cSet'), ['a1', 'a2', 'b1', 'c1']);
      expect(read(parent, 'pMap'), ['home=pHome', 'settings=pSettings']);
      expect(read(child, 'cMap'), [
        'home=cHome',
        'settings=pSettings',
        'extra=cExtra',
      ], reason: 'the child entry sits at the position of the parent entry');
      rightOf(await parent.dispose());
    });

    test('equal values give one element at the first position', () async {
      // from: collection_test.dart: equal values give one element at the
      // first position
      const names = DiSetKey<String>(name: 'names');
      Component<String> name(String value) => Component<String>.into(
        key: names,
        dependency: Dependency<String>(create: () => value),
      );
      final scope = Scope(
        components: [
          name('b'),
          name('a'),
          name('b'),
          Component<List<String>>(
            key: out('names'),
            dependency: Dependency.requireSet<String>(
              key: names,
            ).map<List<String>>((s) => s.toList()),
          ),
        ],
      );
      rightOf(await scope.run());
      expect(read(scope, 'names'), ['b', 'a']);
      rightOf(await scope.dispose());
    });

    test('an entry reads another entry with Dependency.require', () async {
      // from: collection_test.dart: an entry reads another entry with
      // Dependency.require
      final log = <String>[];
      final scope = Scope(
        components: [
          Component<AppScope>(
            key: routes.entryKey('derived'),
            dependency: Dependency.require<AppScope>(
              key: routes.entryKey('base'),
            ).map<AppScope>((base) => Feature('derived(${base.id})')),
          ),
          entry('base', 'base', log),
          mapReader('reader', log),
        ],
      );
      rightOf(await scope.run());
      expect(read(scope, 'reader'), [
        'derived=derived(base)',
        'base=base',
      ], reason: 'the order is the declaration order');
      rightOf(await scope.dispose());
    });

    test('a reader starts after the contributors of its scope settle and '
        'releases before them', () async {
      // from: collection_test.dart: a reader starts after the contributors of
      // its scope settle and releases before them
      final log = <String>[];
      final scope = Scope(
        components: [
          // The readers are declared first and still start last.
          setReader('setReader', log),
          mapReader('mapReader', log),
          contributor('a1', log),
          entry('home', 'h', log),
          contributor('a2', log),
        ],
      );
      rightOf(await scope.run());
      final firstReader = [
        log.indexOf('up setReader'),
        log.indexOf('up mapReader'),
      ].reduce((a, b) => a < b ? a : b);
      for (final member in ['up a1', 'up a2', 'up home=h']) {
        expect(log.indexOf(member), lessThan(firstReader), reason: member);
      }

      log.clear();
      rightOf(await scope.dispose());
      final pairs = {
        'down setReader': ['down a1', 'down a2'],
        'down mapReader': ['down home=h'],
      };
      for (final MapEntry(key: reader, value: members) in pairs.entries) {
        for (final member in members) {
          expect(
            log.indexOf(reader),
            lessThan(log.indexOf(member)),
            reason: '$reader before $member',
          );
        }
      }
      expect(log, hasLength(5));
    });

    test('two entries of one id in one scope are a DuplicateKeyFailure before '
        'any creation', () async {
      // from: collection_test.dart: two entries of one id in one scope throw
      // DuplicateKeyError before any creation
      final log = <String>[];
      final scope = Scope(
        components: [
          contributor('a1', log),
          entry('home', 'one', log),
          entry('home', 'two', log),
          mapReader('reader', log),
        ],
      );
      final failure = leftOf(await scope.run()).only;
      expect(failure, isA<DuplicateKeyFailure>());
      expect(log, isEmpty);
      expect(scope.isInitialized, isFalse);
    });

    test(
      'an empty collection is an empty value, not UndeclaredKeyFailure',
      () async {
        // from: collection_test.dart: an empty collection is an empty value,
        // not UndeclaredKeyError
        final log = <String>[];
        final scope = Scope(
          components: [
            setReader('strictSet', log),
            mapReader('strictMap', log),
            setReader('optionalSet', log, strict: false),
            mapReader('optionalMap', log, strict: false),
          ],
        );
        rightOf(await scope.run());
        for (final name in [
          'strictSet',
          'strictMap',
          'optionalSet',
          'optionalMap',
        ]) {
          expect(read(scope, name), isEmpty, reason: name);
        }
        expect(scope.nodes.every((m) => m.isActive), isTrue);

        // A child of an empty scope reads an empty collection too.
        final child = scope.kid(components: [setReader('childSet', log)]);
        rightOf(await child.run());
        expect(read(child, 'childSet'), isEmpty);
        rightOf(await scope.dispose());
      },
    );

    test('the only contributor of a set key reads that set strictly and '
        'activates without a wait for itself', () async {
      // from: collection_test.dart: the only contributor of a set key reads
      // that set strictly and activates without a wait for itself
      final seen = <int>[];
      final log = <String>[];
      final scope = Scope(
        components: [
          Component<AppScope>.into(
            key: features,
            debugLabel: 'solo',
            dependency: Dependency.requireSet<AppScope>(key: features)
                .map<AppScope>((others) {
                  seen.add(others.length);
                  return Feature('solo');
                }),
          ),
          setReader('reader', log),
        ],
      );
      rightOf(await scope.run());
      final solo = scope.nodes.first;
      expect(solo.isActive, isTrue);
      expect(solo.missing, isEmpty);
      expect(seen, [0], reason: 'its own contribution is not a member');
      expect(read(scope, 'reader'), ['solo']);
      rightOf(await scope.dispose());
    });

    test(
      'a contribution is not an effect, has no key, and cannot be found',
      () async {
        final log = <String>[];
        final scope = Scope(components: [contributor('a', log)]);
        final component = scope.components.single;
        expect(component.isEffect, isFalse);
        expect(component.hasKey, isFalse);
        expect(component.contributesTo, features);
        expect(component.label, 'a');
        rightOf(await scope.run());
        final node = scope.nodes.single;
        expect(node.key.isNone(), isTrue);
        expect(node.isActive, isTrue);
        expect(
          leftOf(scope.node<AppScope>(key: const DiKey<AppScope>())),
          isA<UnavailableKeyFailure>(),
        );
        expect(scope.findNode<AppScope>(), isA<None>());
        expect(
          described(scope),
          'scope\n  - a: active; contributes to $features',
        );
        rightOf(await scope.dispose());
      },
    );

    test('the label of an unnamed contribution names its set', () {
      final unnamed = Component<AppScope>.into(
        key: features,
        dependency: Dependency<AppScope>.of(Feature('x')),
      );
      expect(unnamed.label, 'Component<AppScope> into $features');
    });
  });

  group('collection reads over time (V-T-RT-LC-020)', () {
    const version = DiKey<int>(name: 'version');

    test('a strict reader waits for the contributor of a later parent and an '
        'optional reader never waits', () async {
      // from: collection_test.dart: a strict reader waits for the contributor
      // of a later parent and an optional reader never waits
      final log = <String>[];
      final root = Scope(
        components: [Component<int>.value(value: 1, key: version)],
      );
      final child = root.kid(
        components: [
          Component<AppScope>.into(
            key: features,
            debugLabel: 'c',
            dependency: Dependency.require<int>(
              key: version,
            ).map<AppScope>((v) => Feature('c$v')),
          ),
          contributor('d', log),
          setReader('strictSet', log),
          setReader('optionalSet', log, strict: false),
        ],
      );
      rightOf(await child.run());
      final strict = nodeOf(child, 'strictSet');
      final optional = nodeOf(child, 'optionalSet');
      expect(strict.isActive, isFalse, reason: 'c is dormant');
      expect(strict.missing, [features]);
      expect(
        optional.isActive,
        isTrue,
        reason: 'the optional read never waits',
      );
      expect(rightOf(optional.value), ['d']);

      rightOf(await root.run());
      expect(strict.isActive, isTrue);
      expect(rightOf(strict.value), ['c1', 'd']);
      expect(rightOf(optional.value), ['c1', 'd']);
      rightOf(await root.dispose());
    });

    test('a strict reader waits for a contributor that a scope that did not '
        'run declares', () async {
      // from: collection_test.dart: a strict reader waits for a contributor
      // that an uninitialized ancestor declares
      final log = <String>[];
      final root = Scope(components: []);
      final mid = root.kid(
        components: [contributor('m', log), entry('home', 'm', log)],
      );
      final leaf = mid.kid(
        components: [
          contributor('l', log),
          entry('own', 'l', log),
          setReader('strictSet', log),
          setReader('optionalSet', log, strict: false),
          mapReader('strictMap', log),
          mapReader('optionalMap', log, strict: false),
        ],
      );
      rightOf(await root.run());
      rightOf(await leaf.run());
      expect(nodeOf(leaf, 'strictSet').isActive, isFalse);
      expect(nodeOf(leaf, 'strictMap').isActive, isFalse);
      expect(read(leaf, 'optionalSet'), ['l']);
      expect(read(leaf, 'optionalMap'), ['own=l']);

      rightOf(await mid.run());
      expect(read(leaf, 'strictSet'), ['m', 'l']);
      expect(read(leaf, 'optionalSet'), ['m', 'l']);
      expect(read(leaf, 'strictMap'), ['home=m', 'own=l']);
      expect(read(leaf, 'optionalMap'), ['home=m', 'own=l']);
      rightOf(await root.dispose());
    });

    test('the strict reader deactivates while a withdrawn contributor is '
        'dormant and activates again when it returns', () async {
      // from: collection_test.dart: the strict reader deactivates while a
      // withdrawn contributor is dormant and activates again when it returns
      final log = <String>[];
      final root = Scope(
        components: [Component<int>.value(value: 1, key: version)],
      );
      // This scope stays not run: it holds the replacement publisher.
      final replacement = root.kid(
        components: [Component<int>.value(value: 2, key: version)],
      );
      final leaf = replacement.kid(
        components: [
          Component<AppScope>.into(
            key: features,
            debugLabel: 'c',
            dependency: Dependency.require<int>(key: version).map<AppScope>(
              (v) => Feature('c$v'),
              dispose: (_) => log.add('down c'),
            ),
          ),
          contributor('d', log),
          Component<AppScope>(
            key: routes.entryKey('e'),
            dependency: Dependency.require<int>(
              key: version,
            ).map<AppScope>((v) => Feature('e$v')),
          ),
          setReader('strictSet', log),
          setReader('optionalSet', log, strict: false),
          mapReader('strictMap', log),
          mapReader('optionalMap', log, strict: false),
        ],
      );
      rightOf(await root.run());
      rightOf(await leaf.run());
      final strictSet = nodeOf(leaf, 'strictSet');
      final strictMap = nodeOf(leaf, 'strictMap');
      final optionalSet = nodeOf(leaf, 'optionalSet');
      final optionalMap = nodeOf(leaf, 'optionalMap');
      expect(rightOf(strictSet.value), ['c1', 'd']);
      expect(rightOf(strictMap.value), ['e=e1']);

      log.clear();
      rightOf(await root.nodes.single.dispose());
      expect(strictSet.isActive, isFalse);
      expect(strictMap.isActive, isFalse);
      expect(optionalSet.isActive, isTrue);
      expect(rightOf(optionalSet.value), ['d'], reason: 'only the active ones');
      expect(rightOf(optionalMap.value), isEmpty);
      expect(log.indexOf('down strictSet'), isNonNegative);
      expect(
        log.indexOf('down strictSet'),
        lessThan(log.indexOf('down c')),
        reason: 'the reader releases before the contributor it read',
      );

      rightOf(await replacement.run());
      expect(strictSet.isActive, isTrue);
      expect(rightOf(strictSet.value), ['c2', 'd']);
      expect(rightOf(strictMap.value), ['e=e2']);
      expect(rightOf(optionalSet.value), ['c2', 'd']);
      expect(rightOf(optionalMap.value), ['e=e2']);
      rightOf(await root.dispose());
    });

    test('a contributor disposed by itself leaves the membership and the '
        'strict reader activates again without it', () async {
      // from: collection_test.dart: a contributor disposed by itself leaves
      // the membership and the strict reader activates again without it
      final log = <String>[];
      final scope = Scope(
        components: [
          contributor('a', log),
          contributor('b', log),
          entry('x', 'x', log),
          entry('y', 'y', log),
          setReader('strictSet', log),
          setReader('optionalSet', log, strict: false),
          mapReader('strictMap', log),
          mapReader('optionalMap', log, strict: false),
        ],
      );
      rightOf(await scope.run());
      expect(read(scope, 'strictSet'), ['a', 'b']);
      expect(read(scope, 'strictMap'), ['x=x', 'y=y']);

      rightOf(await scope.nodes[1].dispose()); // the contribution of 'b'
      expect(read(scope, 'strictSet'), ['a']);
      expect(read(scope, 'optionalSet'), ['a']);
      expect(read(scope, 'strictMap'), ['x=x', 'y=y']);

      rightOf(
        await rightOf(
          scope.node<AppScope>(key: routes.entryKey('x')),
        ).dispose(),
      );
      expect(nodeOf(scope, 'strictMap').isActive, isTrue);
      expect(read(scope, 'strictMap'), ['y=y']);
      expect(read(scope, 'optionalMap'), ['y=y']);
      rightOf(await scope.dispose());
    });

    test('the disposal of a contributing child scope disposes the child '
        'reader and leaves the parent reader unchanged', () async {
      // from: collection_test.dart: the disposal of a contributing child scope
      // disposes the child reader and leaves the parent reader unchanged
      final parentLog = <String>[];
      final childLog = <String>[];
      final parent = Scope(
        components: [
          contributor('p', parentLog),
          entry('home', 'p', parentLog),
          setReader('pSet', parentLog),
          mapReader('pMap', parentLog),
        ],
      );
      final child = parent.kid(
        components: [
          contributor('c', childLog),
          entry('extra', 'c', childLog),
          setReader('cSet', childLog),
          mapReader('cMap', childLog),
        ],
      );
      rightOf(await parent.run());
      rightOf(await child.run());
      expect(read(child, 'cSet'), ['p', 'c']);
      expect(read(parent, 'pSet'), ['p']);

      parentLog.clear();
      rightOf(await child.dispose());
      expect(childLog, containsAll(['down cSet', 'down cMap', 'down c']));
      expect(parentLog, isEmpty, reason: 'no release or activation');
      expect(read(parent, 'pSet'), ['p']);
      expect(read(parent, 'pMap'), ['home=p']);
      rightOf(await parent.dispose());
    });

    test('a member disposal requested while the reader is in flight cancels '
        'the reader before its collection read', () async {
      // from: collection_test.dart: a member disposal requested while the
      // reader is in flight cancels the reader before its collection read
      final gate = Completer<void>();
      final log = <String>[];
      final reads = <List<String>>[];
      final tokens = <CancellationToken>[];
      final parent = Scope(
        components: [contributor('a', log), contributor('b', log)],
      );
      final scope = parent.kid(
        components: [
          Component<List<String>>(
            key: out('reader'),
            debugLabel: 'reader',
            dependency:
                (
                  Dependency.cancellation().mapTask<CancellationToken>(
                    (token) => Task(() async {
                      tokens.add(token);
                      await Future.any([gate.future, token.whenCanceled.run()]);
                      return token;
                    }),
                  ),
                  Dependency.requireSet<AppScope>(key: features),
                ).zip.mapN<List<String>>((token, set) {
                  final ids = [for (final element in set) element.id];
                  reads.add(ids);
                  return ids;
                }),
          ),
        ],
      );
      rightOf(await parent.run());
      final setup = scope.run();
      await pause(1);
      expect(tokens, hasLength(1), reason: 'the reader is in flight');
      expect(reads, isEmpty);

      final withdrawal = parent.nodes[1].dispose(); // contributor 'b'
      rightOf(await setup);
      expect(tokens.single.isCanceled, isTrue);
      expect(reads, isEmpty, reason: 'canceled before the collection read');
      expect(nodeOf(scope, 'reader').isActive, isFalse);

      gate.complete();
      rightOf(await withdrawal);
      expect(reads, [
        ['a'],
      ], reason: 'one activation after the withdrawal');
      expect(read(scope, 'reader'), ['a']);
      rightOf(await parent.dispose());
    });

    test('a dormant child entry leaves the parent entry selected and an '
        'active child entry needs no dormant parent entry', () async {
      // from: collection_test.dart: a dormant child entry leaves the parent
      // entry selected and an active child entry needs no dormant parent
      // entry
      final log = <String>[];
      const token = DiKey<int>(name: 'token');
      final root = Scope(components: [entry('home', 'parent', log)]);
      // This scope stays not run for the first half of the test.
      final mid = root.kid(
        components: [
          Component<int>.value(value: 1, key: token),
          entry('only', 'dormantParent', log),
        ],
      );
      final leaf = mid.kid(
        components: [
          Component<AppScope>(
            key: routes.entryKey('home'),
            debugLabel: 'child home',
            dependency: Dependency.require<int>(
              key: token,
            ).map<AppScope>((v) => Feature('child$v')),
          ),
          entry('only', 'activeChild', log),
          mapReader('strictMap', log),
          mapReader('optionalMap', log, strict: false),
          Component<List<String>>(
            key: out('require'),
            dependency:
                (
                  Dependency.require<AppScope>(key: routes.entryKey('home')),
                  Dependency.require<AppScope>(key: routes.entryKey('only')),
                ).zip.map<List<String>>(
                  (v) => ['home=${v.$1.id}', 'only=${v.$2.id}'],
                ),
          ),
        ],
      );
      rightOf(await root.run());
      rightOf(await leaf.run());
      // The child 'home' is dormant: the parent entry is selected. The child
      // 'only' is active: the dormant parent entry in `mid` is not awaited.
      expect(read(leaf, 'strictMap'), ['home=parent', 'only=activeChild']);
      expect(read(leaf, 'optionalMap'), ['home=parent', 'only=activeChild']);
      expect(read(leaf, 'require'), ['home=parent', 'only=activeChild']);

      rightOf(await mid.run());
      expect(read(leaf, 'strictMap'), ['home=child1', 'only=activeChild']);
      expect(read(leaf, 'require'), ['home=child1', 'only=activeChild']);
      rightOf(await root.dispose());
    });

    test('the cause of an unavailable key holds the failed contributor behind '
        'a strict set reader', () async {
      // from: observation_test.dart: holds the failed contributor behind a
      // strict reader
      const gate = DiKey<int>(name: 'gate');
      final root = Scope(
        components: [Component<int>.value(value: 1, key: gate)],
      );
      const first = DiKey<String>(name: 'first');
      final child = root.kid(
        components: [
          Component<AppScope>.into(
            key: features,
            debugLabel: 'contributor',
            dependency: Dependency.require<int>(
              key: gate,
            ).map<AppScope>((_) => throw StateError('no member')),
          ),
          Component<String>(
            key: first,
            dependency: Dependency.requireSet<AppScope>(
              key: features,
            ).map<String>((set) => set.map((e) => e.id).join(',')),
          ),
        ],
      );
      rightOf(await child.run());
      final subscription = root.errors.listen((_) {});
      rightOf(await root.run());
      expect(child.findNode<String>(key: first).toNullable()!.missing, [
        features,
      ]);
      final error = leftOf(child.get<String>(key: first));
      final failure = error as UnavailableKeyFailure;
      expect(failure.failedNodeStates, hasLength(1));
      expect(failure.failedNodeStates.single.label, 'contributor');
      expect(failure.failedNodeStates.single.key.isNone(), isTrue);
      expect(failure.message, contains('no member'));
      expect(failure.message, contains('waits for $features'));
      await subscription.cancel();
      rightOf(await root.dispose());
    });

    test('the cause of an unavailable key holds the failed entry behind a '
        'strict map reader', () async {
      // from: observation_test.dart: holds the failed entry behind a strict
      // map reader
      const gate = DiKey<int>(name: 'gate');
      final root = Scope(
        components: [Component<int>.value(value: 1, key: gate)],
      );
      const first = DiKey<String>(name: 'first');
      final child = root.kid(
        components: [
          Component<AppScope>(
            key: routes.entryKey('page'),
            dependency: Dependency.require<int>(
              key: gate,
            ).map<AppScope>((_) => throw StateError('no entry')),
          ),
          Component<String>(
            key: first,
            dependency: Dependency.requireMap<AppScope>(
              key: routes,
            ).map<String>((map) => map.keys.join(',')),
          ),
        ],
      );
      rightOf(await child.run());
      final subscription = root.errors.listen((_) {});
      rightOf(await root.run());
      final failure =
          leftOf(child.get<String>(key: first)) as UnavailableKeyFailure;
      expect(failure.failedNodeStates, hasLength(1));
      expect(
        failure.failedNodeStates.single.key,
        Some(routes.entryKey('page')),
      );
      expect(failure.message, contains('no entry'));
      await subscription.cancel();
      rightOf(await root.dispose());
    });
  });

  group('a strict collection read (witnesses)', () {
    test('waits until each contribution resolves or leaves', () async {
      // from: runtime_state_test.dart: waits until each contribution resolves
      // or leaves
      const numbers = DiSetKey<int>(name: 'numbers');
      const count = DiKey<int>(name: 'count');
      final sources = [for (var i = 0; i < 3; i++) DiKey<int>(name: 'k$i')];
      final root = Scope(components: []);
      rightOf(await root.run());
      final failures = <Cause<DiFailure>>[];
      root.errors.listen(failures.add);
      // Each source has its own scope, so the test chooses the order in which
      // the contributions resolve.
      final providers = <Scope>[];
      var parent = root;
      for (var i = 0; i < 3; i++) {
        parent = parent.kid(
          components: [Component<int>.value(value: i, key: sources[i])],
        );
        providers.add(parent);
      }
      final scope = parent.kid(
        components: [
          for (final source in sources)
            Component<int>.into(
              key: numbers,
              dependency: Dependency.require<int>(key: source),
            ),
          Component<int>(
            key: count,
            dependency: Dependency.requireSet<int>(
              key: numbers,
            ).map<int>((set) => set.length),
          ),
        ],
      );
      rightOf(await scope.run());
      final reader = rightOf(scope.node<int>(key: count));
      void expectWaits(String when) {
        expect(reader.state.phase, NodePhase.waiting, reason: when);
        expect(reader.state.missing, [numbers], reason: when);
      }

      expectWaits('no contribution resolves');
      // The contributions resolve in reverse declaration order.
      rightOf(await providers[2].run());
      expectWaits('the last contribution resolves');
      rightOf(await providers[1].run());
      expectWaits('two contributions resolve');
      // A resolved contribution is withdrawn while the reader waits for
      // another one.
      rightOf(await providers[2].nodes.single.dispose());
      expect(scope.nodes[2].state.phase, NodePhase.waiting);
      expectWaits('a resolved contribution is withdrawn');
      rightOf(await providers[0].run());
      expect(scope.nodes[0].state.phase, NodePhase.active);
      expectWaits('the first contribution resolves');
      // The contributor that the reader waits for is disposed alone, so its
      // contribution leaves the set.
      rightOf(await scope.nodes[2].dispose());
      expect(reader.state.phase, NodePhase.active);
      expect(reader.state.missing, isEmpty);
      expect(rightOf(reader.value), 2);
      expect(failures, isEmpty);
      rightOf(await root.dispose());
    });
  });

  group('collection shape (V-T-RT-LC-019)', () {
    const features = DiSetKey<int>(name: 'features');
    const tabs = DiSetKey<int>(name: 'tabs');
    const routes = DiMapKey<int>(name: 'routes');
    const shell = DiKey<int>(name: 'shell');
    const audit = DiKey<int>(name: 'audit');

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
        Dependency.requireSet<int>(key: features),
        Dependency.optionMap<int>(key: routes),
      ).zip.map<int>((v) => v.$1.length + v.$2.length),
    );
    // Reads the routes strictly and the features optionally.
    final optionalAudit = Component<int>(
      key: audit,
      dependency: (
        Dependency.optionSet<int>(key: features),
        Dependency.requireMap<int>(key: routes),
      ).zip.map<int>((v) => v.$1.length + v.$2.length),
    );
    final mobile = <Component<Object?>>[
      into(features, 1),
      into(features, 2),
      into(tabs, 3),
      entry('home', 10),
      entry('search', 11),
      strictShell,
    ];
    final web = <Component<Object?>>[
      into(features, 4),
      entry('home', 12),
      entry('admin', 13),
      optionalAudit,
    ];
    final testing = rightOf(mobile.overriddenBy([entry('home', 99)]));

    test('a reader keeps its strict and optional collection reads apart', () {
      // from: module_test.dart: a reader keeps its strict and optional
      // collection reads apart
      expect(strictShell.collectionKeys, {features});
      expect(strictShell.optionalCollectionKeys, {routes});
      expect(optionalAudit.collectionKeys, {routes});
      expect(optionalAudit.optionalCollectionKeys, {features});
      expect(strictShell.requires, isEmpty);
      expect(strictShell.optional, isEmpty);
      expect(strictShell.reads, {features, routes});

      final strict = Dependency.requireSet<int>(key: features);
      final optional = Dependency.optionMap<int>(key: routes);
      expect(strict.collectionKeys, {features});
      expect(strict.optionalCollectionKeys, isEmpty);
      expect(optional.collectionKeys, isEmpty);
      expect(optional.optionalCollectionKeys, {routes});
      expect(strict.requires, isEmpty);
      expect(optional.optional, isEmpty);
      final composed = strict.map<int>((s) => s.length).lazy();
      expect(composed.collectionKeys, {features});
    });

    test('a set contribution publishes no key and names its set key', () {
      // from: module_test.dart: a set contribution publishes no key and names
      // its set key
      final contribution = into(features, 1);
      expect(contribution.hasKey, isFalse);
      expect(contribution.isEffect, isFalse);
      expect(contribution.contributesTo, features);
      expect(entry('home', 1).key, routes.entryKey('home'));
      expect(entry('home', 1).hasKey, isTrue);
      expect(entry('home', 1).contributesTo, isNull);
      expect(strictShell.contributesTo, isNull);
    });

    test('entry keys are in publishes and contributes counts the set '
        'contributors', () {
      // from: module_test.dart: entry keys are in publishes and contributes
      // counts the set contributors
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
      expect(<Component<Object?>>[strictShell].contributes, isEmpty);
    });

    test('a collection read is in reads and not in requires', () {
      // from: module_test.dart: a collection read is in reads and not in
      // requires
      for (final components in [mobile, web, testing]) {
        expect(components.reads, {features, routes});
        expect(components.requires, isEmpty);
        expect(components.reads, isNot(contains(tabs)));
      }
    });

    test('reads and requires leave out a key that another member publishes, '
        'and a member does not satisfy itself', () {
      // from: module_test.dart: derives publishes, requires, and reads
      const a = DiKey<int>(name: 'a');
      const b = DiKey<int>(name: 'b');
      const x = DiKey<int>(name: 'x');
      final components = <Component<Object?>>[
        Component<int>(
          key: a,
          dependency: (
            Dependency.require<int>(key: b),
            Dependency.option<int>(key: x),
          ).zip.map<int>((_) => 0),
        ),
        Component<int>(
          key: b,
          dependency: Dependency.require<int>(key: b).map<int>((v) => v),
        ),
      ];
      // `a` reads `b`, which `b` publishes. `b` reads its own key.
      expect(components.requires, {b});
      expect(components.reads, {b, x});
    });

    test('overriddenBy replaces one entry by its entry key', () {
      // from: module_test.dart: overriddenBy replaces one entry by its entry
      // key
      final keys = [
        for (final component in testing)
          if (component.hasKey) component.key,
      ];
      expect(keys, [routes.entryKey('home'), routes.entryKey('search'), shell]);
      expect(identical(testing[3], mobile[3]), isFalse);
      expect(identical(testing[4], mobile[4]), isTrue);
      expect(testing.publishes, mobile.publishes);
      expect(mobile, hasLength(6), reason: 'the source is intact');
      expect(
        leftOf(mobile.overriddenBy([entry('missing', 1)])).only,
        isA<UnmatchedOverrideFailure>(),
      );
    });

    test('a contribution is selected by where only', () {
      // from: module_test.dart: only where selects a set contribution
      expect(
        leftOf(mobile.overriddenBy([into(features, 5)])).only,
        isA<UnmatchedOverrideFailure>(),
      );
      final fewer = mobile
          .where((component) => component.contributesTo != features)
          .toList();
      expect(fewer.contributes, {tabs: 1});
      expect(fewer, hasLength(4));
      expect(fewer.publishes, mobile.publishes);
      final none = mobile
          .where((component) => component.contributesTo == null)
          .toList();
      expect(none.contributes, isEmpty);
      expect(none.reads, {features, routes});
      expect(mobile.contributes, {features: 2, tabs: 1}, reason: 'unchanged');
    });

    test('a list join sums the contributors of each set key', () {
      // from: module_test.dart: Module.all and + sum the contributors of each
      // set key
      final both = [...mobile, ...web];
      expect(both.contributes, {features: 3, tabs: 1});
      expect(both.reads, {features, routes});
      expect(both.requires, isEmpty);
    });

    test('the derived sets reject mutation', () {
      // from: module_test.dart: the derived sets reject mutation
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
        () =>
            Dependency.requireSet<int>(key: features).collectionKeys.add(tabs),
        throwsUnsupportedError,
      );
      expect(
        () => Dependency.optionSet<int>(
          key: features,
        ).optionalCollectionKeys.add(tabs),
        throwsUnsupportedError,
      );
      expect(
        () => Dependency.requireMap<int>(key: routes).collectionKeys.clear(),
        throwsUnsupportedError,
      );
      expect(
        () => Dependency.require<int>(key: shell).requires.add(audit),
        throwsUnsupportedError,
      );
    });
  });

  group('collection key identity (V-T-RT-LC-021)', () {
    const left = DiMapKey<String>(name: 'left');
    const right = DiMapKey<String>(name: 'right');
    const plain = DiKey<String>(name: 'default');
    const set = DiSetKey<String>(name: 'default');
    const map = DiMapKey<String>(name: 'default');

    test('no two keys of the same type and name are equal', () {
      // from: collection_test.dart: no two keys of the same type and name are
      // equal
      final keys = <Object>[
        left.entryKey('default'),
        right.entryKey('default'),
        plain,
        set,
        map,
        const DiMapKey<int>(name: 'default'),
        const DiSetKey<int>(name: 'default'),
      ];
      for (var i = 0; i < keys.length; i++) {
        for (var j = 0; j < keys.length; j++) {
          if (i == j) continue;
          expect(
            keys[i] == keys[j],
            isFalse,
            reason: '${keys[i]} == ${keys[j]}',
          );
        }
      }
    });

    test('an entry key is a DiMapEntryKey with its map and its id', () {
      // from: collection_test.dart: an entry key is a DiMapEntryKey with its
      // map and its id
      final DiMapEntryKey<String> entry = left.entryKey('a');
      expect(entry, isA<DiKey<String>>());
      expect(entry.mapKey, left);
      expect(entry.id, 'a');
      expect(entry.name, 'a');
      expect('$entry', 'DiMapKey<String>(left)[a]');
      expect(plain, isNot(isA<DiMapEntryKey<String>>()));
    });

    test('equal keys have one hash code', () {
      // from: collection_test.dart: equal keys have one hash code
      expect(left.entryKey('a'), left.entryKey('a'));
      expect(left.entryKey('a').hashCode, left.entryKey('a').hashCode);
      expect(const DiMapKey<String>(name: 'left'), left);
      expect(const DiMapKey<String>(name: 'left').hashCode, left.hashCode);
      expect(const DiSetKey<String>(name: 'default'), set);
      expect(const DiSetKey<String>(name: 'default').hashCode, set.hashCode);
      expect(left.entryKey('a'), isNot(left.entryKey('b')));
    });

    test('both entries and the DiKey publish in one scope, each map sees its '
        'own entry, and an override leaves the other map unchanged', () async {
      // from: collection_test.dart: both entries and the DiKey publish in one
      // scope, each map sees its own entry, and an override leaves the other
      // map unchanged
      Component<String> entry(DiMapKey<String> map, String value) =>
          Component<String>.value(value: value, key: map.entryKey('default'));
      Component<List<String>> reader(String name, DiMapKey<String> map) =>
          Component<List<String>>(
            key: out(name),
            dependency: Dependency.requireMap<String>(key: map)
                .map<List<String>>(
                  (m) => [for (final e in m.entries) '${e.key}=${e.value}'],
                ),
          );
      final components = <Component<Object?>>[
        entry(left, 'L'),
        entry(right, 'R'),
        Component<String>.value(value: 'P', key: plain),
        reader('left', left),
        reader('right', right),
      ];
      final scope = Scope(components: components);
      rightOf(await scope.run());
      expect(read(scope, 'left'), ['default=L']);
      expect(read(scope, 'right'), ['default=R']);
      expect(rightOf(scope.get<String>(key: plain)), 'P');
      rightOf(await scope.dispose());

      final overridden = Scope(
        components: rightOf(components.overriddenBy([entry(left, 'L2')])),
      );
      rightOf(await overridden.run());
      expect(read(overridden, 'left'), ['default=L2']);
      expect(read(overridden, 'right'), ['default=R']);
      expect(rightOf(overridden.get<String>(key: plain)), 'P');
      rightOf(await overridden.dispose());
    });

    test(
      'a collection read never resolves a plain key of the same name',
      () async {
        // from: collection_test.dart: a collection read never resolves a plain
        // key of the same name
        final scope = Scope(
          components: [
            Component<String>.value(value: 'P', key: plain),
            Component<List<String>>(
              key: out('set'),
              dependency: Dependency.requireSet<String>(
                key: set,
              ).map<List<String>>((s) => s.toList()),
            ),
            Component<List<String>>(
              key: out('map'),
              dependency: Dependency.optionMap<String>(
                key: map,
              ).map<List<String>>((m) => m.values.toList()),
            ),
          ],
        );
        rightOf(await scope.run());
        expect(read(scope, 'set'), isEmpty);
        expect(read(scope, 'map'), isEmpty);
        rightOf(await scope.dispose());
      },
    );

    test('the keys of a group: publishes holds entry keys, contributes counts '
        'the contributions, and a contribution cannot override', () {
      final log = <String>[];
      final group = <Component<Object?>>[
        contributor('a', log),
        entry('x', 'x', log),
        contributor('b', log),
        Component<int>.value(value: 1, key: const DiKey<int>(name: 'n')),
      ];
      expect(group.publishes, {
        routes.entryKey('x'),
        const DiKey<int>(name: 'n'),
      });
      expect(group.contributes, {features: 2});
      final failure = leftOf(group.overriddenBy([contributor('c', log)]));
      expect(failure.only, isA<UnmatchedOverrideFailure>());
      // An entry is replaced like any key.
      final replaced = rightOf(group.overriddenBy([entry('x', 'y', log)]));
      expect(replaced, hasLength(4));
      expect(replaced[1], isNot(same(group[1])));
    });
  });

  group('a reused component is one member per declaration (V-T-RT-LC-018)', () {
    test(
      'one contribution declared twice in a scope gives two elements',
      () async {
        // from: collection_test.dart: one contribution declared twice in a
        // module gives two elements
        var created = 0;
        final contribution = Component<AppScope>.into(
          key: features,
          dependency: Dependency<AppScope>(
            create: () => Feature('f${created++}'),
          ),
        );
        final components = <Component<Object?>>[
          contribution,
          contribution,
          setReader('all', []),
        ];
        expect(components.contributes, {features: 2});
        final scope = Scope(components: components);
        rightOf(await scope.run());
        expect(read(scope, 'all'), ['f0', 'f1']);

        rightOf(await scope.nodes[0].dispose());
        expect(read(scope, 'all'), [
          'f1',
        ], reason: 'only that declaration left');
        rightOf(await scope.dispose());
      },
    );

    test('two declarations of equal values give one set element', () async {
      // from: collection_test.dart: two declarations of equal values give one
      // set element
      final shared = Component<AppScope>.into(
        key: features,
        dependency: Dependency<AppScope>(create: () => Feature('same')),
      );
      final scope = Scope(components: [shared, shared, setReader('all', [])]);
      rightOf(await scope.run());
      expect(read(scope, 'all'), ['same']);
      rightOf(await scope.dispose());
    });

    test('a reader that also contributes, declared in a parent and a child, '
        'excludes only its own declaration', () async {
      // from: collection_test.dart: a reader that also contributes, declared
      // in a parent and a child, excludes only its own declaration
      final echo = Component<AppScope>.into(
        key: features,
        dependency: Dependency.requireSet<AppScope>(key: features)
            .map<AppScope>(
              (set) =>
                  Feature('echo(${[for (final e in set) e.id].join(',')})'),
            ),
      );
      final parent = Scope(components: [contributor('a', []), echo]);
      final child = parent.kid(components: [echo, setReader('all', [])]);
      rightOf(await parent.run());
      rightOf(await child.run());

      String idOf(Scope scope, int index) =>
          (rightOf(scope.nodes[index].value) as AppScope).id;
      expect(idOf(parent, 1), 'echo(a)');
      expect(idOf(child, 0), 'echo(a,echo(a))');
      expect(read(child, 'all'), ['a', 'echo(a)', 'echo(a,echo(a))']);
      rightOf(await parent.dispose());
    });

    test('one entry component declared twice in a scope is a '
        'DuplicateKeyFailure; in a parent and a child the child shadows the '
        'parent until it is disposed', () async {
      // from: collection_test.dart: one entry component declared twice in a
      // scope throws DuplicateKeyError; in a parent and a child the child
      // shadows the parent until it is disposed
      var created = 0;
      final entryComponent = Component<AppScope>(
        key: routes.entryKey('home'),
        dependency: Dependency<AppScope>(
          create: () => Feature('h${created++}'),
        ),
      );
      expect(
        leftOf(
          await Scope(components: [entryComponent, entryComponent]).run(),
        ).only,
        isA<DuplicateKeyFailure>(),
      );
      expect(created, 0);

      final parent = Scope(components: [entryComponent]);
      final child = parent.kid(
        components: [entryComponent, mapReader('map', [])],
      );
      rightOf(await parent.run());
      rightOf(await child.run());
      expect(read(child, 'map'), ['home=h1']);

      rightOf(
        await rightOf(
          child.node<AppScope>(key: routes.entryKey('home')),
        ).dispose(),
      );
      expect(read(child, 'map'), ['home=h0'], reason: 'the parent entry');
      rightOf(await parent.dispose());
    });
  });

  group('a collection read under nested lazy steps (V-T-RT-LC-018)', () {
    test('forcing both holders yields the strict set and the optional map '
        'read at activation, and the shape stays on the outer step', () async {
      // from: collection_test.dart: forcing both holders yields the strict
      // set and the optional map read at activation, and the shape stays on
      // the outer step
      final runs = <String>[];
      final dependency =
          (
                Dependency.requireSet<AppScope>(key: features),
                Dependency.optionMap<AppScope>(key: routes),
              ).zip
              .mapN<List<String>>((set, map) {
                runs.add('create');
                return [
                  for (final element in set) element.id,
                  for (final e in map.entries) '${e.key}=${e.value.id}',
                ];
              })
              .lazy()
              .lazy();
      expect(dependency.collectionKeys, {features});
      expect(dependency.optionalCollectionKeys, {routes});

      final log = <String>[];
      const key = DiKey<Lazy<Lazy<List<String>>>>();
      final scope = Scope(
        components: [
          contributor('a', log),
          contributor('b', log),
          entry('home', 'h', log),
          Component<Lazy<Lazy<List<String>>>>(key: key, dependency: dependency),
        ],
      );
      rightOf(await scope.run());
      final outer = rightOf(scope.get<Lazy<Lazy<List<String>>>>(key: key));
      expect(runs, isEmpty, reason: 'nothing runs before force');
      final inner = rightOf(await outer.force().run());
      expect(runs, isEmpty, reason: 'the inner step is still deferred');
      expect(rightOf(await inner.force().run()), ['a', 'b', 'home=h']);
      expect(rightOf(await inner.force().run()), ['a', 'b', 'home=h']);
      expect(runs, ['create'], reason: 'one creation per success');
      rightOf(await scope.dispose());
    });

    test(
      'a member disposal reactivates the owner: both old holders fail with '
      'DisposedLazyFailure and a new holder forces the smaller set',
      () async {
        // from: collection_test.dart: a member disposal reactivates the owner:
        // both old holders throw DisposedLazyException and a new holder forces
        // the smaller set
        final log = <String>[];
        const key = DiKey<Lazy<Lazy<List<String>>>>();
        final scope = Scope(
          components: [
            contributor('a', log),
            contributor('b', log),
            Component<Lazy<Lazy<List<String>>>>(
              key: key,
              dependency: Dependency.requireSet<AppScope>(key: features)
                  .map<List<String>>(
                    (set) => [for (final element in set) element.id],
                  )
                  .lazy()
                  .lazy(),
            ),
          ],
        );
        rightOf(await scope.run());
        final oldOuter = rightOf(scope.get<Lazy<Lazy<List<String>>>>(key: key));
        final oldInner = rightOf(await oldOuter.force().run());
        expect(rightOf(await oldInner.force().run()), ['a', 'b']);

        rightOf(await scope.nodes[1].dispose()); // contributor 'b'

        expect(
          leftOf(await oldOuter.force().run()).only,
          isA<DisposedLazyFailure>(),
        );
        expect(
          leftOf(await oldInner.force().run()).only,
          isA<DisposedLazyFailure>(),
        );
        final next = rightOf(scope.get<Lazy<Lazy<List<String>>>>(key: key));
        expect(identical(next, oldOuter), isFalse);
        final inner = rightOf(await next.force().run());
        expect(rightOf(await inner.force().run()), ['a']);
        rightOf(await scope.dispose());
      },
    );
  });
}

/// The text of `describe`, or a test failure.
String described(Scope scope) => rightOf(scope.describe());
