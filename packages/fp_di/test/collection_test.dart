// Collection keys (R-UC-RT-LC-018). V-T-RT-LC-018 covers membership, order, and
// value, V-T-RT-LC-020 the reads over time, and V-T-RT-LC-021 key identity.
// V-T-RT-LC-019 (module shape) lives in module_test.dart.
import 'dart:async';

import 'package:fp_di/fp_di.dart';
import 'package:test/test.dart';

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
Component<AppScope> _contributor(String id, List<String> log) =>
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
Component<AppScope> _entry(String id, String value, List<String> log) =>
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

DiKey<List<String>> _out(String name) => DiKey<List<String>>(name: name);

/// A reader of a set key. It publishes the ids of the elements, in order.
Component<List<String>> _setReader(
  String name,
  List<String> log, {
  bool strict = true,
  DiSetKey<AppScope> key = features,
}) => Component<List<String>>(
  key: _out(name),
  debugLabel: name,
  dependency:
      (strict ? Dependency.requireSet(key: key) : Dependency.maybeSet(key: key))
          .map((set) {
            log.add('up $name');
            return [for (final element in set) element.id];
          }, dispose: (_) => log.add('down $name')),
);

/// A reader of a map key. It publishes `id=value` for each element, in order.
Component<List<String>> _mapReader(
  String name,
  List<String> log, {
  bool strict = true,
  DiMapKey<AppScope> key = routes,
}) => Component<List<String>>(
  key: _out(name),
  debugLabel: name,
  dependency:
      (strict ? Dependency.requireMap(key: key) : Dependency.maybeMap(key: key))
          .map((map) {
            log.add('up $name');
            return [for (final e in map.entries) '${e.key}=${e.value.id}'];
          }, dispose: (_) => log.add('down $name')),
);

List<String> _read(Scope scope, String name) =>
    scope.get<List<String>>(key: _out(name));

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('collection membership, order, and value (V-T-RT-LC-018)', () {
    test('a child read yields the parent elements first and the parent does '
        'not see the child', () async {
      final log = <String>[];
      final parentModule = Module.all(
        modules: [
          Module(
            debugLabel: 'feature A',
            components: [
              _contributor('a1', log),
              _entry('home', 'pHome', log),
              _contributor('a2', log),
              _entry('settings', 'pSettings', log),
            ],
          ),
          Module(
            debugLabel: 'feature B',
            components: [
              _contributor('b1', log),
              _setReader('pSet', log),
              _mapReader('pMap', log),
              // A member that implements the interface and does not
              // contribute is not an element.
              Component<AppScope>.value(
                value: Feature('plain'),
                key: const DiKey<AppScope>(),
              ),
            ],
          ),
        ],
      );
      final parent = Scope(module: parentModule);
      final child = parent.child(
        module: Module(
          components: [
            _contributor('c1', log),
            _entry('home', 'cHome', log),
            _entry('extra', 'cExtra', log),
            _setReader('cSet', log),
            _mapReader('cMap', log),
          ],
        ),
      );
      await parent.initialize();
      await child.initialize();

      expect(_read(parent, 'pSet'), ['a1', 'a2', 'b1']);
      expect(_read(child, 'cSet'), ['a1', 'a2', 'b1', 'c1']);
      expect(_read(parent, 'pMap'), ['home=pHome', 'settings=pSettings']);
      expect(_read(child, 'cMap'), [
        'home=cHome',
        'settings=pSettings',
        'extra=cExtra',
      ], reason: 'the child entry sits at the position of the parent entry');
      await parent.dispose();
    });

    test('equal values give one element at the first position', () async {
      const names = DiSetKey<String>(name: 'names');
      Component<String> name(String value) => Component<String>.into(
        key: names,
        dependency: Dependency<String>(create: () => value),
      );
      final scope = Scope(
        module: Module(
          components: [
            name('b'),
            name('a'),
            name('b'),
            Component<List<String>>(
              key: _out('names'),
              dependency: Dependency.requireSet(
                key: names,
              ).map((s) => s.toList()),
            ),
          ],
        ),
      );
      await scope.initialize();
      expect(_read(scope, 'names'), ['b', 'a']);
      await scope.dispose();
    });

    test('an entry reads another entry with Dependency.require', () async {
      final log = <String>[];
      final scope = Scope(
        module: Module(
          components: [
            Component<AppScope>(
              key: routes.entryKey('derived'),
              dependency: Dependency.require<AppScope>(
                key: routes.entryKey('base'),
              ).map((base) => Feature('derived(${base.id})')),
            ),
            _entry('base', 'base', log),
            _mapReader('reader', log),
          ],
        ),
      );
      await scope.initialize();
      expect(_read(scope, 'reader'), [
        'derived=derived(base)',
        'base=base',
      ], reason: 'the order is the declaration order');
      await scope.dispose();
    });

    test('a reader starts after the contributors of its scope settle and '
        'releases before them', () async {
      final log = <String>[];
      final scope = Scope(
        module: Module(
          components: [
            // The readers are declared first and still start last.
            _setReader('setReader', log),
            _mapReader('mapReader', log),
            _contributor('a1', log),
            _entry('home', 'h', log),
            _contributor('a2', log),
          ],
        ),
      );
      await scope.initialize();
      final firstReader = [
        log.indexOf('up setReader'),
        log.indexOf('up mapReader'),
      ].reduce((a, b) => a < b ? a : b);
      for (final member in ['up a1', 'up a2', 'up home=h']) {
        expect(log.indexOf(member), lessThan(firstReader), reason: member);
      }

      log.clear();
      await scope.dispose();
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

    test('two entries of one id in one scope throw DuplicateKeyError before '
        'any creation', () async {
      final log = <String>[];
      final scope = Scope(
        module: Module(
          components: [
            _contributor('a1', log),
            _entry('home', 'one', log),
            _entry('home', 'two', log),
            _mapReader('reader', log),
          ],
        ),
      );
      await expectLater(scope.initialize(), throwsA(isA<DuplicateKeyError>()));
      expect(log, isEmpty);
      expect(scope.isInitialized, isFalse);
    });

    test(
      'an empty collection is an empty value, not UndeclaredKeyError',
      () async {
        final log = <String>[];
        final scope = Scope(
          module: Module(
            components: [
              _setReader('strictSet', log),
              _mapReader('strictMap', log),
              _setReader('optionalSet', log, strict: false),
              _mapReader('optionalMap', log, strict: false),
            ],
          ),
        );
        await scope.initialize();
        for (final name in [
          'strictSet',
          'strictMap',
          'optionalSet',
          'optionalMap',
        ]) {
          expect(_read(scope, name), isEmpty, reason: name);
        }
        expect(scope.nodes.every((m) => m.isActive), isTrue);

        // A child of an empty scope reads an empty collection too.
        final child = scope.child(
          module: Module(components: [_setReader('childSet', log)]),
        );
        await child.initialize();
        expect(_read(child, 'childSet'), isEmpty);
        await scope.dispose();
      },
    );

    test('the only contributor of a set key reads that set strictly and '
        'activates without a wait for itself', () async {
      final seen = <int>[];
      final log = <String>[];
      final scope = Scope(
        module: Module(
          components: [
            Component<AppScope>.into(
              key: features,
              debugLabel: 'solo',
              dependency: Dependency.requireSet(key: features).map((others) {
                seen.add(others.length);
                return Feature('solo');
              }),
            ),
            _setReader('reader', log),
          ],
        ),
      );
      await scope.initialize();
      final solo = scope.nodes.first;
      expect(solo.isActive, isTrue);
      expect(solo.missing, isEmpty);
      expect(seen, [0], reason: 'its own contribution is not a member');
      expect(_read(scope, 'reader'), ['solo']);
      await scope.dispose();
    });
  });

  group('collection reads over time (V-T-RT-LC-020)', () {
    final version = DiKey<int>(name: 'version');

    test('a strict reader waits for the contributor of a later parent and '
        'an optional reader never waits', () async {
      final log = <String>[];
      final root = Scope(
        module: Module(components: [Component.value(value: 1, key: version)]),
      );
      final child = root.child(
        module: Module(
          components: [
            Component<AppScope>.into(
              key: features,
              debugLabel: 'c',
              dependency: Dependency.require<int>(
                key: version,
              ).map((v) => Feature('c$v')),
            ),
            _contributor('d', log),
            _setReader('strictSet', log),
            _setReader('optionalSet', log, strict: false),
          ],
        ),
      );
      await child.initialize();
      final strict = child.node(key: _out('strictSet'));
      final optional = child.node(key: _out('optionalSet'));
      expect(strict.isActive, isFalse, reason: 'c is dormant');
      expect(strict.missing, [features]);
      expect(
        optional.isActive,
        isTrue,
        reason: 'the optional read never waits',
      );
      expect(optional.value, ['d']);

      await root.initialize();
      expect(strict.isActive, isTrue);
      expect(strict.value, ['c1', 'd']);
      expect(optional.value, ['c1', 'd']);
      await root.dispose();
    });

    test('a strict reader waits for a contributor that an uninitialized '
        'ancestor declares', () async {
      final log = <String>[];
      final root = Scope();
      final mid = root.child(
        module: Module(
          components: [_contributor('m', log), _entry('home', 'm', log)],
        ),
      );
      final leaf = mid.child(
        module: Module(
          components: [
            _contributor('l', log),
            _entry('own', 'l', log),
            _setReader('strictSet', log),
            _setReader('optionalSet', log, strict: false),
            _mapReader('strictMap', log),
            _mapReader('optionalMap', log, strict: false),
          ],
        ),
      );
      await root.initialize();
      await leaf.initialize();
      expect(leaf.node(key: _out('strictSet')).isActive, isFalse);
      expect(leaf.node(key: _out('strictMap')).isActive, isFalse);
      expect(_read(leaf, 'optionalSet'), ['l']);
      expect(_read(leaf, 'optionalMap'), ['own=l']);

      await mid.initialize();
      expect(_read(leaf, 'strictSet'), ['m', 'l']);
      expect(_read(leaf, 'optionalSet'), ['m', 'l']);
      expect(_read(leaf, 'strictMap'), ['home=m', 'own=l']);
      expect(_read(leaf, 'optionalMap'), ['home=m', 'own=l']);
      await root.dispose();
    });

    test('the strict reader deactivates while a withdrawn contributor is '
        'dormant and activates again when it returns', () async {
      final log = <String>[];
      final root = Scope(
        module: Module(components: [Component.value(value: 1, key: version)]),
      );
      // This scope stays uninitialized: it holds the replacement publisher.
      final replacement = root.child(
        module: Module(components: [Component.value(value: 2, key: version)]),
      );
      final leaf = replacement.child(
        module: Module(
          components: [
            Component<AppScope>.into(
              key: features,
              debugLabel: 'c',
              dependency: Dependency.require<int>(
                key: version,
              ).map((v) => Feature('c$v'), dispose: (_) => log.add('down c')),
            ),
            _contributor('d', log),
            Component<AppScope>(
              key: routes.entryKey('e'),
              dependency: Dependency.require<int>(
                key: version,
              ).map((v) => Feature('e$v')),
            ),
            _setReader('strictSet', log),
            _setReader('optionalSet', log, strict: false),
            _mapReader('strictMap', log),
            _mapReader('optionalMap', log, strict: false),
          ],
        ),
      );
      await root.initialize();
      await leaf.initialize();
      final strictSet = leaf.node(key: _out('strictSet'));
      final strictMap = leaf.node(key: _out('strictMap'));
      final optionalSet = leaf.node(key: _out('optionalSet'));
      final optionalMap = leaf.node(key: _out('optionalMap'));
      expect(strictSet.value, ['c1', 'd']);
      expect(strictMap.value, ['e=e1']);

      log.clear();
      await root.nodes.single.dispose();
      expect(strictSet.isActive, isFalse);
      expect(strictMap.isActive, isFalse);
      expect(optionalSet.isActive, isTrue);
      expect(optionalSet.value, ['d'], reason: 'only the active members');
      expect(optionalMap.value, isEmpty);
      expect(log.indexOf('down strictSet'), isNonNegative);
      expect(
        log.indexOf('down strictSet'),
        lessThan(log.indexOf('down c')),
        reason: 'the reader releases before the contributor it read',
      );

      await replacement.initialize();
      expect(strictSet.isActive, isTrue);
      expect(strictSet.value, ['c2', 'd']);
      expect(strictMap.value, ['e=e2']);
      expect(optionalSet.value, ['c2', 'd']);
      expect(optionalMap.value, ['e=e2']);
      await root.dispose();
    });

    test('a contributor disposed by itself leaves the membership and the '
        'strict reader activates again without it', () async {
      final log = <String>[];
      final scope = Scope(
        module: Module(
          components: [
            _contributor('a', log),
            _contributor('b', log),
            _entry('x', 'x', log),
            _entry('y', 'y', log),
            _setReader('strictSet', log),
            _setReader('optionalSet', log, strict: false),
            _mapReader('strictMap', log),
            _mapReader('optionalMap', log, strict: false),
          ],
        ),
      );
      await scope.initialize();
      expect(_read(scope, 'strictSet'), ['a', 'b']);
      expect(_read(scope, 'strictMap'), ['x=x', 'y=y']);

      await scope.nodes[1].dispose(); // the set contribution of 'b'
      expect(_read(scope, 'strictSet'), ['a']);
      expect(_read(scope, 'optionalSet'), ['a']);
      expect(_read(scope, 'strictMap'), ['x=x', 'y=y']);

      await scope.node(key: routes.entryKey('x')).dispose();
      expect(scope.node(key: _out('strictMap')).isActive, isTrue);
      expect(_read(scope, 'strictMap'), ['y=y']);
      expect(_read(scope, 'optionalMap'), ['y=y']);
      await scope.dispose();
    });

    test('the disposal of a contributing child scope disposes the child '
        'reader and leaves the parent reader unchanged', () async {
      final parentLog = <String>[];
      final childLog = <String>[];
      final parent = Scope(
        module: Module(
          components: [
            _contributor('p', parentLog),
            _entry('home', 'p', parentLog),
            _setReader('pSet', parentLog),
            _mapReader('pMap', parentLog),
          ],
        ),
      );
      final child = parent.child(
        module: Module(
          components: [
            _contributor('c', childLog),
            _entry('extra', 'c', childLog),
            _setReader('cSet', childLog),
            _mapReader('cMap', childLog),
          ],
        ),
      );
      await parent.initialize();
      await child.initialize();
      expect(_read(child, 'cSet'), ['p', 'c']);
      expect(_read(parent, 'pSet'), ['p']);

      parentLog.clear();
      await child.dispose();
      expect(childLog, containsAll(['down cSet', 'down cMap', 'down c']));
      expect(parentLog, isEmpty, reason: 'no release or activation');
      expect(_read(parent, 'pSet'), ['p']);
      expect(_read(parent, 'pMap'), ['home=p']);
      await parent.dispose();
    });

    test('a member disposal requested while the reader is in flight cancels '
        'the reader before its collection read', () async {
      final gate = Completer<void>();
      final log = <String>[];
      final reads = <List<String>>[];
      final tokens = <CancellationToken>[];
      final parent = Scope(
        module: Module(
          components: [_contributor('a', log), _contributor('b', log)],
        ),
      );
      final scope = parent.child(
        module: Module(
          components: [
            Component<List<String>>(
              key: _out('reader'),
              debugLabel: 'reader',
              dependency:
                  (
                    Dependency.cancellation().map((token) async {
                      tokens.add(token);
                      await Future.any([gate.future, token.whenCanceled]);
                      return token;
                    }),
                    Dependency.requireSet(key: features),
                  ).zip.mapN((token, set) {
                    final ids = [for (final element in set) element.id];
                    reads.add(ids);
                    return ids;
                  }),
            ),
          ],
        ),
      );
      await parent.initialize();
      final setup = scope.initialize();
      await _settle();
      expect(tokens, hasLength(1), reason: 'the reader is in flight');
      expect(reads, isEmpty);

      final withdrawal = parent.nodes[1].dispose(); // contributor 'b'
      await setup;
      expect(tokens.single.isCanceled, isTrue);
      expect(reads, isEmpty, reason: 'canceled before the collection read');
      expect(scope.node(key: _out('reader')).isActive, isFalse);

      gate.complete();
      await withdrawal;
      expect(reads, [
        ['a'],
      ], reason: 'one activation after the withdrawal');
      expect(_read(scope, 'reader'), ['a']);
      await parent.dispose();
    });

    test('a dormant child entry leaves the parent entry selected and an '
        'active child entry needs no dormant parent entry', () async {
      final log = <String>[];
      final token = DiKey<int>(name: 'token');
      final root = Scope(
        module: Module(components: [_entry('home', 'parent', log)]),
      );
      // This scope stays uninitialized for the first half of the test.
      final mid = root.child(
        module: Module(
          components: [
            Component.value(value: 1, key: token),
            _entry('only', 'dormantParent', log),
          ],
        ),
      );
      final leaf = mid.child(
        module: Module(
          components: [
            Component<AppScope>(
              key: routes.entryKey('home'),
              debugLabel: 'child home',
              dependency: Dependency.require<int>(
                key: token,
              ).map((v) => Feature('child$v')),
            ),
            _entry('only', 'activeChild', log),
            _mapReader('strictMap', log),
            _mapReader('optionalMap', log, strict: false),
            Component<List<String>>(
              key: _out('require'),
              dependency: (
                Dependency.require<AppScope>(key: routes.entryKey('home')),
                Dependency.require<AppScope>(key: routes.entryKey('only')),
              ).zip.map((v) => ['home=${v.$1.id}', 'only=${v.$2.id}']),
            ),
          ],
        ),
      );
      await root.initialize();
      await leaf.initialize();
      // The child 'home' is dormant: the parent entry is selected. The child
      // 'only' is active: the dormant parent entry in `mid` is not awaited.
      expect(_read(leaf, 'strictMap'), ['home=parent', 'only=activeChild']);
      expect(_read(leaf, 'optionalMap'), ['home=parent', 'only=activeChild']);
      expect(_read(leaf, 'require'), ['home=parent', 'only=activeChild']);

      await mid.initialize();
      expect(_read(leaf, 'strictMap'), ['home=child1', 'only=activeChild']);
      expect(_read(leaf, 'require'), ['home=child1', 'only=activeChild']);
      await root.dispose();
    });
  });

  group('collection key identity (V-T-RT-LC-021)', () {
    const left = DiMapKey<String>(name: 'left');
    const right = DiMapKey<String>(name: 'right');
    const plain = DiKey<String>(name: 'default');
    const set = DiSetKey<String>(name: 'default');
    const map = DiMapKey<String>(name: 'default');

    test('no two keys of the same type and name are equal', () {
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
      final DiMapEntryKey<String> entry = left.entryKey('a');
      expect(entry, isA<DiKey<String>>());
      expect(entry.mapKey, left);
      expect(entry.id, 'a');
      expect(entry.name, 'a');
      expect(entry.needsName, isFalse);
      expect('$entry', 'DiMapKey<String>(left)[a]');
      expect(plain, isNot(isA<DiMapEntryKey<String>>()));
    });

    test('equal keys have one hash code', () {
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
      Component<String> entry(DiMapKey<String> map, String value) =>
          Component<String>.value(value: value, key: map.entryKey('default'));
      Component<List<String>> mapReader(String name, DiMapKey<String> map) =>
          Component<List<String>>(
            key: _out(name),
            dependency: Dependency.requireMap(
              key: map,
            ).map((m) => [for (final e in m.entries) '${e.key}=${e.value}']),
          );
      final module = Module(
        components: [
          entry(left, 'L'),
          entry(right, 'R'),
          Component<String>.value(value: 'P', key: plain),
          mapReader('left', left),
          mapReader('right', right),
        ],
      );
      final scope = Scope(module: module);
      await scope.initialize();
      expect(_read(scope, 'left'), ['default=L']);
      expect(_read(scope, 'right'), ['default=R']);
      expect(scope.get<String>(key: plain), 'P');
      await scope.dispose();

      final overridden = Scope(
        module: module.overriddenBy(Module(components: [entry(left, 'L2')])),
      );
      await overridden.initialize();
      expect(_read(overridden, 'left'), ['default=L2']);
      expect(_read(overridden, 'right'), ['default=R']);
      expect(overridden.get<String>(key: plain), 'P');
      await overridden.dispose();
    });

    test(
      'a collection read never resolves a plain key of the same name',
      () async {
        final scope = Scope(
          module: Module(
            components: [
              Component<String>.value(value: 'P', key: plain),
              Component<List<String>>(
                key: _out('set'),
                dependency: Dependency.requireSet(
                  key: set,
                ).map((s) => s.toList()),
              ),
              Component<List<String>>(
                key: _out('map'),
                dependency: Dependency.maybeMap(
                  key: map,
                ).map((m) => m.values.toList()),
              ),
            ],
          ),
        );
        await scope.initialize();
        expect(_read(scope, 'set'), isEmpty);
        expect(_read(scope, 'map'), isEmpty);
        await scope.dispose();
      },
    );
  });

  // Regressions: a collection read inside nested `lazy` steps, which the
  // snapshot of each step must carry, and a component value that is declared
  // more than once, whose identity is its declaration.
  group('a collection read under nested lazy steps (V-T-RT-LC-018)', () {
    test('forcing both holders yields the strict set and the optional map '
        'read at activation, and the shape stays on the outer step', () async {
      final runs = <String>[];
      final dependency =
          (
                Dependency.requireSet(key: features),
                Dependency.maybeMap(key: routes),
              ).zip
              .mapN((set, map) {
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
      final scope = await Scope(
        module: Module(
          components: [
            _contributor('a', log),
            _contributor('b', log),
            _entry('home', 'h', log),
            Component<Lazy<Lazy<List<String>>>>(
              key: DiKey<Lazy<Lazy<List<String>>>>(),
              dependency: dependency,
            ),
          ],
        ),
      ).initialize();
      final outer = scope.get<Lazy<Lazy<List<String>>>>();
      expect(runs, isEmpty, reason: 'nothing runs before force');
      final inner = await outer.force();
      expect(runs, isEmpty, reason: 'the inner step is still deferred');
      expect(await inner.force(), ['a', 'b', 'home=h']);
      expect(await inner.force(), ['a', 'b', 'home=h']);
      expect(runs, ['create'], reason: 'one creation per success');
      await scope.dispose();
    });

    test(
      'a member disposal reactivates the owner: both old holders throw '
      'DisposedLazyException and a new holder forces the smaller set',
      () async {
        final log = <String>[];
        final scope = await Scope(
          module: Module(
            components: [
              _contributor('a', log),
              _contributor('b', log),
              Component<Lazy<Lazy<List<String>>>>(
                key: DiKey<Lazy<Lazy<List<String>>>>(),
                dependency: Dependency.requireSet(key: features)
                    .map((set) => [for (final element in set) element.id])
                    .lazy()
                    .lazy(),
              ),
            ],
          ),
        ).initialize();
        final oldOuter = scope.get<Lazy<Lazy<List<String>>>>();
        final oldInner = await oldOuter.force();
        expect(await oldInner.force(), ['a', 'b']);

        await scope.nodes[1].dispose(); // contributor 'b'

        await expectLater(
          oldOuter.force(),
          throwsA(isA<DisposedLazyException>()),
        );
        await expectLater(
          oldInner.force(),
          throwsA(isA<DisposedLazyException>()),
        );
        final next = scope.get<Lazy<Lazy<List<String>>>>();
        expect(identical(next, oldOuter), isFalse);
        expect(await (await next.force()).force(), ['a']);
        await scope.dispose();
      },
    );
  });

  group('a reused component is one member per declaration (V-T-RT-LC-018)', () {
    test(
      'one contribution declared twice in a module gives two elements',
      () async {
        var created = 0;
        final contribution = Component<AppScope>.into(
          key: features,
          dependency: Dependency<AppScope>(
            create: () => Feature('f${created++}'),
          ),
        );
        final module = Module(
          components: [contribution, contribution, _setReader('all', [])],
        );
        expect(module.contributes, {features: 2});
        final scope = await Scope(module: module).initialize();
        expect(_read(scope, 'all'), ['f0', 'f1']);

        await scope.nodes[0].dispose();
        expect(_read(scope, 'all'), [
          'f1',
        ], reason: 'only that declaration left');
        await scope.dispose();
      },
    );

    test('two declarations of equal values give one set element', () async {
      final shared = Component<AppScope>.into(
        key: features,
        dependency: Dependency<AppScope>(create: () => Feature('same')),
      );
      final scope = await Scope(
        module: Module(components: [shared, shared, _setReader('all', [])]),
      ).initialize();
      expect(_read(scope, 'all'), ['same']);
      await scope.dispose();
    });

    test('a reader that also contributes, declared in a parent and a child, '
        'excludes only its own declaration', () async {
      final echo = Component<AppScope>.into(
        key: features,
        dependency: Dependency.requireSet(key: features).map(
          (set) => Feature('echo(${[for (final e in set) e.id].join(',')})'),
        ),
      );
      final parent = await Scope(
        module: Module(components: [_contributor('a', []), echo]),
      ).initialize();
      final child = await parent
          .child(module: Module(components: [echo, _setReader('all', [])]))
          .initialize();

      AppScope valueOf(Scope scope, int index) =>
          scope.nodes[index].value! as AppScope;
      expect(valueOf(parent, 1).id, 'echo(a)');
      expect(valueOf(child, 0).id, 'echo(a,echo(a))');
      expect(_read(child, 'all'), ['a', 'echo(a)', 'echo(a,echo(a))']);
      await parent.dispose();
    });

    test('one entry component declared twice in a scope throws '
        'DuplicateKeyError; in a parent and a child the child shadows the '
        'parent until it is disposed', () async {
      var created = 0;
      final entry = Component<AppScope>(
        key: routes.entryKey('home'),
        dependency: Dependency<AppScope>(
          create: () => Feature('h${created++}'),
        ),
      );
      await expectLater(
        Scope(module: Module(components: [entry, entry])).initialize(),
        throwsA(isA<DuplicateKeyError>()),
      );
      expect(created, 0);

      final parent = await Scope(
        module: Module(components: [entry]),
      ).initialize();
      final child = await parent
          .child(module: Module(components: [entry, _mapReader('map', [])]))
          .initialize();
      expect(_read(child, 'map'), ['home=h1']);

      await child.node(key: routes.entryKey('home')).dispose();
      expect(_read(child, 'map'), ['home=h0'], reason: 'the parent entry');
      await parent.dispose();
    });
  });
}
