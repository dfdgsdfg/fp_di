import 'package:fp_di_fpdart/src/core/core.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('resolve', () {
    test('finds the publication of the own scope and of an ancestor', () {
      // from: core_test.dart: named keys and child bindings retain parent
      // lookup
      final (s, top) = root([comp('A', key: a)]);
      final (s1, low) = child(s, top, [comp('B', key: b)]);
      final (s2, [nodeA]) = initialize(s1, top);
      final (s3, [nodeB]) = initialize(s2, low);
      expect(resolve(s3, low, b), Some(PublisherRef(nodeB, 1)));
      expect(resolve(s3, low, a), Some(PublisherRef(nodeA, 1)));
      expect(resolve(s3, top, b).isNone(), isTrue);
    });

    test('finds nothing for a key without a committed publisher', () {
      var (s, top) = root([comp('A', key: a)]);
      expect(resolve(s, top, a).isNone(), isTrue);
      (s, _) = createNodes(s, top);
      expect(resolve(s, top, a).isNone(), isTrue);
    });

    test('a nearer scope shadows a farther scope', () {
      var (s, top) = root([comp('A', key: a)]);
      final (s1, low) = child(s, top, [comp('A2', key: a)]);
      final (s2, [far]) = initialize(s1, top);
      final (s3, [near]) = initialize(s2, low);
      expect(resolve(s3, low, a), Some(PublisherRef(near, 1)));
      expect(resolve(s3, top, a), Some(PublisherRef(far, 1)));
    });

    test('a publication that the reader owns does not count', () {
      // A node never resolves its own publications (components do not read
      // themselves), so the walk goes on in the ancestors.
      final (s, top) = root([comp('Far', key: a)]);
      final (s1, low) = child(s, top, [
        comp('Near', key: a, requires: [a]),
      ]);
      final (s2, [far]) = initialize(s1, top);
      final (s3, [near]) = initialize(s2, low);
      expect(resolve(s3, low, a), Some(PublisherRef(near, 1)));
      expect(
        resolve(s3, low, a, exclude: Some(near)),
        Some(PublisherRef(far, 1)),
      );
      expect(
        resolve(s3, low, a, exclude: Some(far)),
        Some(PublisherRef(near, 1)),
      );
    });

    test('an unavailable publisher gives way to the next ancestor', () {
      // from: runtime_state_test.dart: withdraws the keys in the transition
      // that starts it
      // from: runtime_state_test.dart: moves the answer of a key to the node
      // of the parent
      final (s, top) = root([comp('Far', key: a)]);
      final (s1, low) = child(s, top, [comp('Near', key: a)]);
      final (s2, [far]) = initialize(s1, top);
      final (s3, [near]) = initialize(s2, low);
      final released = beginRelease(s3, near);
      expect(resolve(released, low, a), Some(PublisherRef(far, 1)));
      final ended = endRelease(
        released,
        near,
        ownFailed: false,
        permanent: false,
      );
      expect(resolve(ended, low, a), Some(PublisherRef(far, 1)));
    });

    test('a publication returns with a new identity after a recommit', () {
      // from: runtime_state_test.dart: a rebuilt node commits again under the
      // same id
      final (s, top) = root([comp('A', key: a)]);
      final (s1, [n]) = initialize(s, top);
      final s2 = release(s1, n);
      expect(resolve(s2, top, a).isNone(), isTrue);
      final s3 = activate(s2, n);
      expect(resolve(s3, top, a), Some(PublisherRef(n, 2)));
    });

    test('an effect publishes no key', () {
      final (s, top) = root([effect('E')]);
      final (s1, [n]) = initialize(s, top);
      expect(nodePhase(s1, n), NodePhase.active);
      expect(scopeRecord(s1, top).bindings, isEmpty);
    });
  });

  group('target and targetChanged', () {
    test('target maps each read key, and None for an absent optional key', () {
      final (s, top) = root([
        comp('A', key: a),
        comp('R', key: b, requires: [a], optional: [c]),
      ]);
      final (s1, [nodeA, nodeR]) = initialize(s, top);
      expect(target(s1, nodeR), {
        a: Some(PublisherRef(nodeA, 1)),
        c: const None(),
      });
    });

    test('is unchanged right after the commit', () {
      final (s, top) = root([
        comp('A', key: a),
        comp('R', key: b, requires: [a], optional: [c]),
      ]);
      final (s1, [_, nodeR]) = initialize(s, top);
      expect(targetChanged(s1, nodeR), isFalse);
    });

    test('a key that the committed view lacks equals None', () {
      final (s, top) = root([
        comp('R', key: b, optional: [c]),
      ]);
      final (created, [n]) = createNodes(s, top);
      final committed = activate(created, n);
      expect(nodeRecord(committed, n).committed, {c: const None()});
      final bare = commit(
        beginActivation(created, n).$1,
        n,
        0,
        const {},
        const {},
        nodeRecord(created, n).finalizers,
      );
      expect(nodeRecord(bare, n).committed, isEmpty);
      expect(targetChanged(bare, n), isFalse);
    });

    test(
      'an optional key that appears in the same scope changes the target',
      () {
        // from: regression_test.dart: an optional reader sees a publisher that
        // the same reconciliation activates (G-RT-LC-002, Reconcile.tla
        // SkipRecheck)
        final (s, top) = root([
          comp('R', key: b, optional: [c]),
          comp('C', key: c, requires: [d]),
          comp('D', key: d),
        ]);
        final (created, [nodeR, nodeC, nodeD]) = createNodes(s, top);
        var next = activate(created, nodeR);
        expect(targetChanged(next, nodeR), isFalse);
        next = activate(next, nodeD);
        next = activate(next, nodeC, deps: {nodeD});
        expect(targetChanged(next, nodeR), isTrue);
        expect(staleActives(next), [nodeR]);
      },
    );

    test('a nearer publisher that commits later changes the target', () {
      // from: core_test.dart: a nearer binding reloads dependents by
      // publisher identity
      final (s, top) = root([comp('Far', key: a)]);
      final (s1, mid) = child(s, top, [comp('Near', key: a)]);
      final (s2, low) = child(s1, mid, [
        comp('R', key: b, requires: [a]),
      ]);
      final (s3, [far]) = initialize(s2, top);
      final (s4, [nodeR]) = initialize(s3, low);
      expect(target(s4, nodeR), {a: Some(PublisherRef(far, 1))});
      expect(targetChanged(s4, nodeR), isFalse);
      final (s5, [near]) = initialize(s4, mid);
      expect(target(s5, nodeR), {a: Some(PublisherRef(near, 1))});
      expect(targetChanged(s5, nodeR), isTrue);
      expect(staleActives(s5), [nodeR]);
      // The reader releases and activates again against the nearer publisher.
      final s6 = activate(release(s5, nodeR), nodeR, deps: {near});
      expect(targetChanged(s6, nodeR), isFalse);
      expect(nodeRecord(s6, nodeR).commits, 2);
    });

    test('a recommit of the publisher changes the target of its reader', () {
      final (s, top) = root([
        comp('A', key: a),
        comp('R', key: b, requires: [a]),
      ]);
      final (s1, [nodeA, nodeR]) = initialize(s, top);
      final s2 = activate(release(s1, nodeA), nodeA);
      expect(resolve(s2, top, a), Some(PublisherRef(nodeA, 2)));
      expect(targetChanged(s2, nodeR), isTrue);
    });

    test('a vanished required key changes the target', () {
      final (s, top) = root([
        comp('A', key: a),
        comp('R', key: b, requires: [a]),
      ]);
      final (s1, [nodeA, nodeR]) = initialize(s, top);
      final s2 = release(s1, nodeA);
      expect(targetChanged(s2, nodeR), isTrue);
    });
  });

  group('satisfied and unmet', () {
    test('unmet lists the required keys that do not resolve, in order', () {
      // from: observation_test.dart: lists missing keys while inactive and is
      // empty after
      final (s, top) = root([
        comp('A', key: a),
        comp('R', key: d, requires: [c, a, b], optional: [d]),
      ]);
      final (created, [nodeA, nodeR]) = createNodes(s, top);
      expect(unmet(created, nodeR), [c, a, b]);
      expect(satisfied(created, nodeR), isFalse);
      final withA = activate(created, nodeA);
      expect(unmet(withA, nodeR), [c, b]);
    });

    test('an optional key never counts', () {
      final (s, top) = root([
        comp('R', key: b, optional: [a]),
      ]);
      final (created, [n]) = createNodes(s, top);
      expect(unmet(created, n), isEmpty);
      expect(satisfied(created, n), isTrue);
    });

    test('the reads of an effect count', () {
      final (s, top) = root([
        effect('E', requires: [a]),
      ]);
      final (created, [n]) = createNodes(s, top);
      expect(unmet(created, n), [a]);
    });

    test('a node never satisfies its own requirement', () {
      final (s, top) = root([
        comp('Self', key: a, requires: [a]),
      ]);
      final (created, [n]) = createNodes(s, top);
      expect(satisfied(created, n), isFalse);
    });

    test('an ancestor that is not initialized does not satisfy', () {
      // from: core_test.dart: a child initialized before its parent is dormant
      // until the parent initializes
      final (s, top) = root([comp('A', key: a)]);
      final (s1, low) = child(s, top, [
        comp('R', key: b, requires: [a]),
      ]);
      final (created, [nodeR]) = createNodes(s1, low);
      expect(unmet(created, nodeR), [a]);
      expect(dormantCandidates(created, const {}), isEmpty);
      final (parentDone, _) = initialize(created, top);
      expect(unmet(parentDone, nodeR), isEmpty);
      expect(dormantCandidates(parentDone, const {}), [nodeR]);
    });
  });
}
