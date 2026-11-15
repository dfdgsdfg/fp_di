import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fp_di_fpdart/src/core/core.dart';
import 'package:fp_di_fpdart/src/finalizers.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

const set = DiSetKey<int>(name: 'set');
const map = DiMapKey<int>(name: 'map');

/// A contribution to [set].
Component<int> into(String label) => Component<int>.into(
  key: set,
  debugLabel: label,
  dependency: Dependency<int>.of(0),
);

/// A reader of [set], strict or optional.
Component<int> reader(String label, {bool strict = true, DiKey<int>? key}) =>
    Component<int>(
      key: key ?? DiKey<int>(name: label),
      debugLabel: label,
      dependency:
          (strict
                  ? Dependency.requireSet<int>(key: set)
                  : Dependency.optionSet<int>(key: set))
              .map<int>((s) => s.length),
    );

/// An entry of [map].
Component<int> entry(String id, {List<DiKey<int>> requires = const []}) =>
    comp(id, key: map.entryKey(id), requires: requires);

/// The membership of the node [n] for [collection], as the shell records it.
Map<DiCollectionKey<Object?>, List<DiKey<Object?>>> membershipOf(
  RuntimeState s,
  NodeId n,
  List<DiCollectionKey<Object?>> collections,
) => {for (final c in collections) c: contributionKeysOf(s, n, c)};

void main() {
  group('contributionKeysOf', () {
    test('lists the contributions in declaration order, without the own '
        'declaration', () {
      final (s, top) = root([into('a'), reader('r', key: a), into('b')]);
      final (created, [na, nr, nb]) = createNodes(s, top);
      final keys = scopeRecord(created, top).contributionKeys;
      expect(contributionKeysOf(created, nr, set), [keys[0], keys[2]]);
      // A contributor that reads the set leaves out its own declaration.
      final (s2, top2) = root([
        Component<int>.into(
          key: set,
          dependency: Dependency.requireSet<int>(
            key: set,
          ).map<int>((s) => s.length),
        ),
        into('b'),
      ]);
      final (created2, [first, second]) = createNodes(s2, top2);
      final keys2 = scopeRecord(created2, top2).contributionKeys;
      expect(contributionKeysOf(created2, first, set), [keys2[1]]);
      expect(contributionKeysOf(created2, second, set), [keys2[0]]);
      expect(na, isNot(nb));
    });

    test('puts the ancestors first, and the parent never sees the child', () {
      final (s, top) = root([into('p'), reader('r', key: a)]);
      final (s1, low) = child(s, top, [into('c'), reader('l', key: b)]);
      final (s2, [np, nr]) = createNodes(s1, top);
      final (s3, [nc, nl]) = createNodes(s2, low);
      final parent = scopeRecord(s3, top).contributionKeys;
      final lower = scopeRecord(s3, low).contributionKeys;
      expect(contributionKeysOf(s3, nr, set), [parent[0]]);
      expect(contributionKeysOf(s3, nl, set), [parent[0], lower[0]]);
      expect(np, isNot(nc));
    });

    test('lists a map id once, at the position of its first declaration', () {
      final (s, top) = root([entry('home')]);
      final (s1, low) = child(s, top, [
        entry('extra'),
        entry('home'),
        Component<int>(
          key: a,
          dependency: Dependency.requireMap<int>(key: map).map<int>((m) => 0),
        ),
      ]);
      final (s2, _) = createNodes(s1, top);
      final (s3, [_, _, nr]) = createNodes(s2, low);
      expect(contributionKeysOf(s3, nr, map), [
        map.entryKey('home'),
        map.entryKey('extra'),
      ]);
    });

    test(
      'leaves out a node that the runtime removed in an initialized scope',
      () {
        final (s, top) = root([into('a'), into('b'), reader('r', key: a)]);
        final (init, [na, nb, nr]) = initialize(s, top);
        final keys = scopeRecord(init, top).contributionKeys;
        expect(contributionKeysOf(init, nr, set), [keys[0], keys[1]]);
        final gone = release(init, na, permanent: true);
        expect(contributionKeysOf(gone, nr, set), [keys[1]]);
        expect(nb, isNot(nr));
      },
    );

    test('counts a removed node of a scope that is initializing', () {
      final (s, top) = root([into('a'), reader('r', key: a)]);
      final (created, [na, nr]) = createNodes(s, top);
      final removed = removeNode(created, na);
      expect(contributionKeysOf(removed, nr, set), hasLength(1));
    });
  });

  group('the seams', () {
    test(
      'plainReads adds the contribution keys of strict and optional reads',
      () {
        final (s, top) = root([
          into('a'),
          Component<int>(
            key: a,
            dependency: (
              Dependency.requireSet<int>(key: set),
              Dependency.optionMap<int>(key: map),
              Dependency.require<int>(key: b),
            ).zip.map<int>((_) => 0),
          ),
          entry('x'),
          comp('B', key: b),
        ]);
        final (created, [_, nr, _, _]) = createNodes(s, top);
        final keys = scopeRecord(created, top).contributionKeys;
        expect(plainReads(created, nodeRecord(created, nr)), {
          b,
          keys[0],
          map.entryKey('x'),
        });
      },
    );

    test('declaredPublishes is the contribution key of a contribution', () {
      final (s, top) = root([into('a'), entry('x'), effect('E')]);
      final (created, [na, nx, ne]) = createNodes(s, top);
      final keys = scopeRecord(created, top).contributionKeys;
      expect(declaredPublishes(created, nodeRecord(created, na)), {keys[0]});
      expect(declaredPublishes(created, nodeRecord(created, nx)), {
        map.entryKey('x'),
      });
      expect(declaredPublishes(created, nodeRecord(created, ne)), isEmpty);
    });

    test('a contribution commits under its contribution key and is no key', () {
      final (s, top) = root([into('a')]);
      final (init, [n]) = initialize(s, top);
      final keys = scopeRecord(init, top).contributionKeys;
      expect(scopeRecord(init, top).bindings, {keys[0]!: PublisherRef(n, 1)});
      expect(nodeState(init, n).key.isNone(), isTrue);
      expect(scopeRecord(init, top).keyIndex[keys[0]], 0);
      expect(nodeForKey(init, top, keys[0]!), Some(n));
      expect(nodeForKey(init, top, const DiKey<int>()).isNone(), isTrue);
    });

    test('each scope has its own contribution keys, distinct from every '
        'other key', () {
      final component = into('a');
      final (s, one) = root([component]);
      final (s1, two) = declareScope(s, const None(), [component, component]);
      final one0 = scopeRecord(s1, one).contributionKeys[0]!;
      final two0 = scopeRecord(s1, two).contributionKeys[0]!;
      final two1 = scopeRecord(s1, two).contributionKeys[1]!;
      expect({one0, two0, two1}, hasLength(3));
      expect(one0 == const DiKey<Object?>(), isFalse);
      expect(const DiKey<Object?>() == one0, isFalse);
      expect(one0.toString(), 'contribution to $set');
    });
  });

  group('satisfied and unmet', () {
    test('a strict read waits for every contribution, and names the '
        'collection', () {
      final (s, top) = root([
        into('a'),
        into('b'),
        reader('r', key: a),
        comp('P', key: b, requires: [c]),
      ]);
      final (created, [na, nb, nr, _]) = createNodes(s, top);
      expect(unmet(created, nr), [set]);
      expect(satisfied(created, nr), isFalse);
      final one = activate(created, na);
      expect(unmet(one, nr), [set], reason: 'one contribution still waits');
      final both = activate(one, nb);
      expect(unmet(both, nr), isEmpty);
      expect(satisfied(both, nr), isTrue);
    });

    test('an optional read never waits', () {
      final (s, top) = root([into('a'), reader('r', key: a, strict: false)]);
      final (created, [_, nr]) = createNodes(s, top);
      expect(unmet(created, nr), isEmpty);
      expect(satisfied(created, nr), isTrue);
    });

    test('lists the required keys first, then the collections', () {
      final (s, top) = root([
        into('a'),
        Component<int>(
          key: a,
          dependency: (
            Dependency.requireSet<int>(key: set),
            Dependency.require<int>(key: c),
          ).zip.map<int>((_) => 0),
        ),
      ]);
      final (created, [_, nr]) = createNodes(s, top);
      expect(unmet(created, nr), [c, set]);
      expect(nodePhase(created, nr), NodePhase.waiting);
      expect(nodeState(created, nr).missing, [c, set]);
    });

    test('an empty collection is satisfied', () {
      final (s, top) = root([reader('r', key: a)]);
      final (created, [nr]) = createNodes(s, top);
      expect(unmet(created, nr), isEmpty);
    });

    test('a contribution of a scope that did not run counts as unresolved', () {
      final (s, top) = root([into('p')]);
      final (s1, low) = child(s, top, [reader('r', key: a)]);
      final (created, [nr]) = createNodes(s1, low);
      expect(unmet(created, nr), [set]);
    });
  });

  group('targetChanged with a collection', () {
    /// Activates [n], with the membership that the reads record.
    RuntimeState activateReading(
      RuntimeState s,
      NodeId n,
      List<DiCollectionKey<Object?>> collections,
    ) {
      final (begun, _) = beginActivation(s, n);
      return commit(
        begun,
        n,
        0,
        target(begun, n),
        depsOf(begun, n),
        Finalizers.empty,
        membership: membershipOf(begun, n, collections),
      );
    }

    test('is unchanged while the members stay', () {
      final (s, top) = root([into('a'), reader('r', key: a)]);
      final (created, [na, nr]) = createNodes(s, top);
      final next = activateReading(activate(created, na), nr, [set]);
      expect(targetChanged(next, nr), isFalse);
    });

    test('changes when a member leaves the membership', () {
      final (s, top) = root([into('a'), into('b'), reader('r', key: a)]);
      final (init, [na, nb, nr]) = initialize(s, top);
      final read = activateReading(release(init, nr), nr, [set]);
      expect(targetChanged(read, nr), isFalse);
      final left = release(read, nb, permanent: true);
      expect(targetChanged(left, nr), isTrue);
      expect(na, isNot(nb));
    });

    test('changes when a member of an optional read appears', () {
      final (s, top) = root([
        into('a'),
        into('b'),
        reader('r', key: a, strict: false),
      ]);
      final (created, [na, nb, nr]) = createNodes(s, top);
      final read = activateReading(activate(created, na), nr, [set]);
      expect(targetChanged(read, nr), isFalse);
      // The second contribution resolves: the key resolved to None before.
      final more = activate(read, nb);
      expect(targetChanged(more, nr), isTrue);
    });

    test('changes when the publisher of a member commits again', () {
      final (s, top) = root([into('a'), reader('r', key: a)]);
      final (init, [na, nr]) = initialize(s, top);
      final read = activateReading(release(init, nr), nr, [set]);
      final again = activate(release(read, na), na);
      expect(targetChanged(again, nr), isTrue);
    });

    test('a node that never recorded a membership is stale', () {
      final (s, top) = root([into('a'), reader('r', key: a)]);
      final (created, [na, nr]) = createNodes(s, top);
      final next = activate(activate(created, na), nr);
      expect(nodeRecord(next, nr).membership, isEmpty);
      expect(targetChanged(next, nr), isTrue);
    });

    test('a release clears the membership', () {
      final (s, top) = root([into('a'), reader('r', key: a)]);
      final (created, [na, nr]) = createNodes(s, top);
      final read = activateReading(activate(created, na), nr, [set]);
      expect(nodeRecord(read, nr).membership, isNotEmpty);
      expect(nodeRecord(release(read, nr), nr).membership, isEmpty);
    });
  });

  group('preCheck with collections', () {
    test('a duplicate entry id is a duplicate key, contributions are not', () {
      final (s, top) = root([
        entry('home'),
        entry('home'),
        into('a'),
        into('a'),
      ]);
      final problems = preCheck(s, top).failures;
      expect(problems, hasLength(1));
      expect(
        (problems.single as DuplicateKeyFailure).key,
        map.entryKey('home'),
      );
    });

    test('a collection read never makes a key undeclared', () {
      final (s, top) = root([reader('r', key: a), reader('o', strict: false)]);
      expect(preCheck(s, top).isEmpty, isTrue);
    });

    test('a member that requires an entry key counts when another member '
        'publishes it', () {
      final (s, top) = root([
        entry('derived', requires: [DiKey<int>(name: 'base')]),
        comp('Base', key: const DiKey<int>(name: 'base')),
      ]);
      expect(preCheck(s, top).isEmpty, isTrue);
    });
  });

  group('describeScope with a contribution', () {
    test('names the set of a contribution', () {
      final (s, top) = root([into('a')]);
      expect(describeScope(s, top), 'scope (not initialized)\n  - a: declared');
      final (init, _) = initialize(s, top);
      expect(
        describeScope(init, top),
        'scope\n  - a: active; contributes to $set',
      );
    });

    test('numbers an unnamed contribution like an effect', () {
      final (s, top) = root([
        Component<int>.into(key: set, dependency: Dependency<int>.of(1)),
      ]);
      final (created, [n]) = createNodes(s, top);
      expect(labelOf(created, n), 'Component<int> into $set#${n.value}');
    });
  });
}
