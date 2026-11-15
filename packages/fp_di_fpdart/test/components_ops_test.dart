// The edits of a group of components: `requiring`, `withoutRequiring`, and
// `replacing`. The group is a plain list, so `where`, `without`, and the
// concatenation are the list operations.
import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';
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

List<String> labels(List<Component<Object?>> group) => [
  for (final member in group) member.label,
];

void main() {
  group('replacing', () {
    test('keeps the position and the ordering rule', () {
      // from: module_test.dart: replacing keeps the position and the ordering
      // rule
      final p = _node('p', []);
      final q = _node('q', []);
      final r = _node('r', []);
      final fake = Component<int>(
        dependency: Dependency<int>(create: () => 99),
        debugLabel: 'fake',
        key: _k('q'),
      );
      final group = [p, q, r];
      final edited = rightOf(group.replacing(key: _k('q'), component: fake));
      expect(edited, [p, fake, r]);
      expect(group, [p, q, r], reason: 'the source is unchanged');
    });

    test('rejects an ambiguous or absent key, and a component that does not '
        'publish the key', () {
      // from: module_test.dart: replacing and without reject an ambiguous or
      // absent key
      final p = _node('p', []);
      final twin = Component<int>(
        dependency: Dependency<int>(create: () => 2),
        key: _k('p'),
      );
      final other = _node('o', []);
      expect(
        leftOf([p, twin].replacing(key: _k('p'), component: p)).only,
        isA<DuplicateKeyFailure>().having((f) => f.labels.length, 'labels', 2),
      );
      expect(
        leftOf(
          [p].replacing(key: _k('missing'), component: _node('missing', [])),
        ).only,
        isA<UnmatchedOverrideFailure>().having(
          (f) => f.owner,
          'owner',
          'missing',
        ),
      );
      expect(
        leftOf([p].replacing(key: _k('p'), component: other)).only,
        isA<InvalidComponentFailure>(),
        reason: 'the replacement must publish the key',
      );
      final effect = Component<int>.effect(
        dependency: Dependency<int>(create: () => 1),
      );
      expect(
        leftOf([effect].replacing(key: _k('p'), component: effect)).only,
        isA<InvalidComponentFailure>(),
        reason: 'an effect publishes no key',
      );
    });

    test('a replaced component is what the scope creates', () async {
      // from: module_test.dart: a replaced member is what the scope creates
      final log = <String>[];
      final group = [
        _node('api', [], log: log),
        _node('repo', ['api'], log: log),
      ];
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
      final di = Scope(
        components: rightOf(group.replacing(key: _k('api'), component: fake)),
      );
      rightOf(await di.run());
      expect(log, ['up fake', 'up repo']);
      expect(rightOf(di.get<int>(key: _k('repo'))), 42);
      rightOf(await di.dispose());
    });
  });

  group('overriddenBy', () {
    test('replaces each component that a fake publishes', () async {
      // from: module_test.dart: overriddenBy replaces each member that a fake
      // publishes
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
      final group = [p, q, r];
      final edited = rightOf(group.overriddenBy([fakeR, fakeP]));
      expect(edited, [fakeP, q, fakeR], reason: 'positions stay');
      expect(group, [p, q, r], reason: 'the source is unchanged');
      final di = Scope(components: edited);
      rightOf(await di.run());
      expect(rightOf(di.get<int>(key: _k('q'))), 11, reason: 'q reads fake p');
      rightOf(await di.dispose());
    });

    test('rejects a fake that replaces nothing', () {
      // from: module_test.dart: overriddenBy rejects a fake that replaces
      // nothing
      final p = _node('p', []);
      final twin = Component<int>.value(value: 2, key: _k('p'));
      final group = [p];
      expect(
        leftOf(group.overriddenBy([_node('missing', [])])).only,
        isA<UnmatchedOverrideFailure>(),
      );
      expect(
        leftOf(
          group.overriddenBy([
            Component<int>.effect(dependency: Dependency(create: () => 1)),
          ]),
        ).only,
        isA<UnmatchedOverrideFailure>(),
        reason: 'a fake without a key',
      );
      expect(
        leftOf(group.overriddenBy([twin, twin])).only,
        isA<DuplicateKeyFailure>(),
        reason: 'two fakes of one key',
      );
      expect(
        leftOf([p, twin].overriddenBy([twin])).only,
        isA<DuplicateKeyFailure>(),
        reason: 'an ambiguous source key',
      );
    });
  });

  group('list operations that the package does not wrap', () {
    test('without and where keep the declaration order', () {
      // from: module_test.dart: without and where keep the declaration order
      final p = _node('p', []);
      final q = _node('q', []);
      final r = _node('r', []);
      final s = _node('s', []);
      final group = [
        p,
        q,
        ...[r, s],
      ];
      expect(group.where((member) => member.key != _k('p')), [q, r, s]);
      expect(group.where((member) => member != q), [p, r, s]);
    });

    test('a concatenation keeps the order of its operands', () {
      // from: module_test.dart: all and + concatenate in order
      final a = Component<int>.effect(dependency: Dependency(create: () => 1));
      final b = Component<int>.effect(dependency: Dependency(create: () => 2));
      final c = Component<int>.effect(dependency: Dependency(create: () => 3));
      final d = Component<int>.effect(dependency: Dependency(create: () => 4));
      final left = [a, b];
      final right = [c, d];
      expect([...left, ...right], [a, b, c, d]);
      expect([...right, ...left], [c, d, a, b]);
      expect(left, [a, b], reason: 'operands are unchanged');
    });
  });

  group('components that require absent keys', () {
    // `a` requires nothing. `b` requires `a`. `c` requires `b`. `d` requires
    // the key `gone`, which no component publishes. `e` requires `d`. `f`
    // requires `gone`. `g` reads `gone` optionally.
    List<Component<Object?>> variant() => [
      _node('a', []),
      _node('b', ['a']),
      _node('c', ['b']),
      _node('d', ['gone']),
      _node('e', ['d']),
      _node('f', ['gone']),
      Component<int>(
        dependency: Dependency.option<int>(
          key: _k('gone'),
        ).map((value) => value.getOrElse(() => 0)),
        debugLabel: 'g',
        key: _k('g'),
      ),
    ];

    const features = DiSetKey<int>(name: 'features');
    const routes = DiMapKey<int>(name: 'routes');

    // A set contribution and a map entry that each require `gone`, a strict
    // reader of the set key, a strict reader of the map key, and a component
    // that requires the entry key.
    List<Component<Object?>> second() => [
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
        dependency: Dependency.requireMap(key: routes).map((map) => map.length),
        debugLabel: 'mapReader',
      ),
      Component<int>(
        key: _k('entryReader'),
        dependency: Dependency.require<int>(key: routes.entryKey('home')),
        debugLabel: 'entryReader',
      ),
    ];

    // `self` requires `gone` and the key that it publishes. `reader` requires
    // that key.
    List<Component<Object?>> selfGroup() => [
      Component<int>(
        key: _k('self'),
        dependency: (
          Dependency.require<int>(key: _k('gone')),
          Dependency.require<int>(key: _k('self')),
        ).zip.map((v) => v.$1 + v.$2),
        debugLabel: 'self',
      ),
      _node('reader', ['self']),
    ];

    // `p1` and `p2` publish the key `p`. `p1` requires `gone`. `third`
    // requires `p`.
    List<Component<Object?>> twinGroup() => [
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
    ];

    // `h` requires `d`. `i` requires `a`. `j` publishes the key of `e`. `k`
    // requires `e`. `m` publishes the key of `f` and requires it.
    List<Component<Object?>> childGroup() => [
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
    ];

    // Runs both edits and checks the two properties of `withoutRequiring`,
    // and that each source keeps its components. Every case below passes
    // through it.
    ({List<Component<Object?>> removed, List<Component<Object?>> rest}) check(
      List<Component<Object?>> source,
      Iterable<DiKeyBase> keys, {
      Iterable<DiKeyBase> ancestorKeys = const <DiKeyBase>[],
    }) {
      final absent = Set<DiKeyBase>.of(keys);
      final ancestors = Set<DiKeyBase>.of(ancestorKeys);
      final before = List<Component<Object?>>.of(source);
      final removed = source.requiring(keys: absent, ancestorKeys: ancestors);
      final rest = source.withoutRequiring(
        keys: absent,
        ancestorKeys: ancestors,
      );

      for (final member in rest) {
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
      expect(removed.length + rest.length, source.length);
      expect(source, orderedEquals(before));
      return (removed: removed, rest: rest);
    }

    test('requiring holds the components behind an absent key, in order', () {
      // from: module_test.dart: requiring holds the members behind an absent
      // key, in order
      final source = variant();
      final removed = source.requiring(keys: {_k('gone')});
      final rest = source.withoutRequiring(keys: {_k('gone')});

      expect(labels(removed), ['d', 'e', 'f']);
      expect(labels(rest), ['a', 'b', 'c', 'g']);
      expect(labels(source), ['a', 'b', 'c', 'd', 'e', 'f', 'g']);
      expect(removed, isNot(same(source)));
      expect(rest, isNot(same(source)));
    });

    test(
      'requiring a key of a component holds the components that read it',
      () {
        // from: module_test.dart: requiring a key of a member holds the members
        // that read it
        final source = variant();
        final (:removed, :rest) = check(source, {_k('a')});
        expect(labels(removed), ['b', 'c']);
        expect(labels(removed), isNot(contains('a')));
        expect(labels(rest), ['a', 'd', 'e', 'f', 'g']);
      },
    );

    test('ancestorKeys keeps the readers of a key that an ancestor holds', () {
      // from: module_test.dart: ancestorKeys keeps the readers of a key that
      // an ancestor holds
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
    });

    group('a key that no component requires', () {
      // from: module_test.dart: $name changes nothing
      for (final (name, key) in <(String, DiKeyBase)>[
        ('a plain key', _k('nobody')),
        ('a set key', features),
        ('a map key', routes),
      ]) {
        test('$name changes nothing', () {
          for (final source in [variant(), second()]) {
            final (:removed, :rest) = check(source, {key});
            expect(removed, isEmpty);
            expect(rest, orderedEquals(source));
          }
        });
      }
    });

    test('a contribution and an entry that require a key are in the result, '
        'a strict collection reader is not', () {
      // from: module_test.dart: a contribution and an entry that require a key
      // are in the result, a strict collection reader is not
      final source = second();
      final (:removed, :rest) = check(source, {_k('gone')});
      expect(labels(removed), ['contribution', 'entry', 'entryReader']);
      expect(labels(rest), ['setReader', 'mapReader']);
      expect(removed.first.hasKey, isFalse);
      expect(removed.first.contributesTo, features);
      expect(removed[1].key, routes.entryKey('home'));
    });

    test('a component that requires its own key takes its readers with it, '
        'unless an ancestor holds the key', () {
      // from: module_test.dart: a member that requires its own key takes its
      // readers with it, unless an ancestor holds the key
      final source = selfGroup();
      final gone = _k('gone');
      final without = check(source, {gone});
      expect(labels(without.removed), ['self', 'reader']);
      expect(without.rest, isEmpty);

      final withAncestor = check(source, {gone}, ancestorKeys: {_k('self')});
      expect(labels(withAncestor.removed), ['self']);
      expect(labels(withAncestor.rest), ['reader']);
    });

    test('a key with two publishers takes the readers of the key', () {
      // from: module_test.dart: a key with two publishers takes the readers of
      // the key
      final source = twinGroup();
      final (:removed, :rest) = check(source, {_k('gone')});
      expect(labels(removed), ['p1', 'third']);
      expect(labels(rest), ['p2']);
    });

    test('an effect that requires a key is in the result', () {
      final effect = Component<int>.effect(
        dependency: Dependency.require<int>(key: _k('gone')),
        debugLabel: 'effect',
      );
      final source = [_node('a', []), effect];
      final (:removed, :rest) = check(source, {_k('gone')});
      expect(labels(removed), ['effect']);
      expect(labels(rest), ['a']);
    });

    test(
      'each source keeps its components and each result is another list',
      () {
        // from: module_test.dart: each source keeps its members and each result
        // is another module
        final source = variant();
        final components = List<Component<Object?>>.of(source);
        final first = source.requiring(keys: {_k('gone')});
        final again = source.requiring(keys: {_k('gone')});
        source.withoutRequiring(keys: {_k('gone')});
        expect(source, orderedEquals(components));
        expect(first, isNot(same(again)));
        expect(first, orderedEquals(again));
        expect(
          source.requiring(keys: const <DiKeyBase>[]),
          isNot(same(source)),
          reason: 'an empty edit is still another list',
        );
      },
    );

    test('a scope of the variant fails, and a scope of withoutRequiring runs '
        'the components that remain', () async {
      // from: module_test.dart: a scope of the variant throws, and a scope of
      // withoutRequiring initializes the members that remain
      final gone = _k('gone');
      final broken = Scope(components: variant());
      expect(await failureOfRun(broken), isA<UndeclaredKeyFailure>());
      rightOf(await broken.dispose());

      final root = Scope(components: variant().withoutRequiring(keys: {gone}));
      rightOf(await root.run());
      try {
        expect(rightOf(root.get<int>(key: _k('a'))), 1);
        expect(rightOf(root.get<int>(key: _k('b'))), 2);
        expect(rightOf(root.get<int>(key: _k('c'))), 3);
        expect(rightOf(root.get<int>(key: _k('g'))), 0);
        expect(root.findNode<int>(key: _k('d')), isA<None>());
      } finally {
        rightOf(await root.dispose());
      }
    });

    group('the components of a child scope', () {
      final gone = _k('gone');
      final lost = variant().requiring(keys: {gone}).publishes;
      final kept = variant().withoutRequiring(keys: {gone}).publishes;

      test('requiring holds the components behind a lost key, in order', () {
        // from: module_test.dart: requiring holds the members behind a lost
        // key, in order
        final source = childGroup();
        final (:removed, :rest) = check(source, {
          gone,
          ...lost,
        }, ancestorKeys: kept);
        expect(labels(removed), ['h', 'k', 'm']);
        expect(labels(rest), ['i', 'j']);
      });

      test('without the key of e, k stays', () {
        // from: module_test.dart: without the key of e, k stays
        final source = childGroup();
        final (:removed, :rest) = check(source, {
          gone,
          _k('d'),
          _k('f'),
        }, ancestorKeys: kept);
        expect(labels(removed), ['h', 'm']);
        expect(labels(rest), ['i', 'j', 'k']);
      });

      test('a child scope of withoutRequiring runs below the parent, and the '
          'unedited list fails', () async {
        // from: module_test.dart: a child scope of withoutRequiring
        // initializes below the parent, and the unedited module throws
        final source = childGroup();
        final (:removed, :rest) = check(source, {
          gone,
          ...lost,
        }, ancestorKeys: kept);
        expect(labels(removed), ['h', 'k', 'm']);
        final root = Scope(
          components: variant().withoutRequiring(keys: {gone}),
        );
        rightOf(await root.run());
        try {
          final session = root.kid(components: rest);
          rightOf(await session.run());
          expect(rightOf(session.get<int>(key: _k('i'))), 2);
          // `j` publishes the key of `e`.
          expect(rightOf(session.get<int>(key: _k('e'))), 1);
          rightOf(await session.dispose());

          final unedited = root.kid(components: source);
          expect(await failureOfRun(unedited), isA<UndeclaredKeyFailure>());
          rightOf(await unedited.dispose());
        } finally {
          rightOf(await root.dispose());
        }
      });
    });

    test('a chain in reverse declaration order is in the result and costs '
        'little', () {
      // from: module_test.dart: a chain in reverse declaration order is in the
      // result and costs little
      const length = 2000;
      // Component `n$i` requires `n${i - 1}`, and `n0` requires `gone`. The
      // component that a component requires is declared after it.
      final chain = <Component<Object?>>[
        for (var i = length - 1; i >= 0; i--)
          _node('n$i', [i == 0 ? 'gone' : 'n${i - 1}']),
      ];
      final (:removed, :rest) = check(chain, {_k('gone')});
      expect(removed, orderedEquals(chain));
      expect(rest, isEmpty);

      final watch = Stopwatch()..start();
      for (var i = 0; i < 100; i++) {
        chain.requiring(keys: {_k('gone')});
      }
      watch.stop();
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });
  });
}
