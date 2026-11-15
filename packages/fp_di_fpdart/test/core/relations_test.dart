import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fp_di_fpdart/src/core/core.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('seams', () {
    test('plainReads lists the required keys and then the optional keys', () {
      final (s, top) = root([
        comp('R', key: d, requires: [b, a], optional: [c]),
      ]);
      final (created, [n]) = createNodes(s, top);
      expect(plainReads(created, nodeRecord(created, n)).toList(), [b, a, c]);
    });

    test('plainReads of an effect holds its reads', () {
      final (s, top) = root([
        effect('E', requires: [a]),
      ]);
      final (created, [n]) = createNodes(s, top);
      expect(plainReads(created, nodeRecord(created, n)), {a});
    });

    test('declaredPublishes is the key, and empty for an effect', () {
      final (s, top) = root([comp('A', key: a), effect('E')]);
      final (created, [na, ne]) = createNodes(s, top);
      expect(declaredPublishes(created, nodeRecord(created, na)), {a});
      expect(declaredPublishes(created, nodeRecord(created, ne)), isEmpty);
    });

    test('a component without a key publishes the key of its type', () {
      final (s, top) = root([comp('A')]);
      final (created, [n]) = createNodes(s, top);
      expect(declaredPublishes(created, nodeRecord(created, n)), {
        const DiKey<int>(),
      });
    });
  });

  group('dependentsOf', () {
    // P publishes `a`. R1, R2, and R3 read it. R4 reads nothing.
    final (base, top) = root([
      comp('P', key: a),
      comp('R1', key: b, requires: [a]),
      comp('R2', key: c, requires: [a]),
      comp('R3', key: d, requires: [a]),
      comp('R4'),
    ]);
    final (init, [p, r1, r2, r3, r4]) = initialize(base, top);

    test('lists the readers in descending id', () {
      expect(dependentsOf(init, p), [r3, r2, r1]);
    });

    test('lists nothing for a node that nobody reads', () {
      expect(dependentsOf(init, r1), isEmpty);
      expect(dependentsOf(init, r4), isEmpty);
    });

    test('lists a reader whose release started', () {
      expect(dependentsOf(beginRelease(init, r2), p), [r3, r2, r1]);
    });

    test('does not list a reader whose release ended', () {
      // from: core_test.dart: publisher removal deactivates and later
      // replacement reactivates
      expect(dependentsOf(release(init, r3), p), [r2, r1]);
    });

    test('does not list a removed reader', () {
      expect(dependentsOf(release(init, r1, permanent: true), p), [r3, r2]);
    });

    test('does not list a node that is not active, whatever it holds', () {
      final stale = init.copyWith(
        nodes: {
          ...init.nodes,
          r1: nodeRecord(init, r1).copyWith(active: false),
        },
      );
      expect(dependentsOf(stale, p), [r3, r2]);
    });
  });

  group('staleActives', () {
    test('lists the active nodes whose target changed, in descending id', () {
      // A reader of `a` in two scopes under a middle scope that publishes
      // `a` later.
      final (s, top) = root([comp('Far', key: a)]);
      final (s1, mid) = child(s, top, [comp('Near', key: a)]);
      final (s2, low) = child(s1, mid, [
        comp('R1', key: b, requires: [a]),
        comp('R2', key: c, requires: [a]),
        comp('R3', key: d),
      ]);
      final (s3, _) = initialize(s2, top);
      final (s4, [r1, r2, _]) = initialize(s3, low);
      expect(staleActives(s4), isEmpty);
      final (s5, _) = initialize(s4, mid);
      expect(staleActives(s5), [r2, r1]);
    });

    test('does not list a node that is not active', () {
      final (s, top) = root([
        comp('A', key: a),
        comp('R', key: b, requires: [a]),
      ]);
      final (init, [_, nr]) = initialize(s, top);
      final released = release(init, nr);
      expect(staleActives(released), isEmpty);
    });

    test('does not list a removed node', () {
      final (s, top) = root([
        comp('A', key: a),
        comp('R', key: b, requires: [a]),
      ]);
      final (init, [na, nr]) = initialize(s, top);
      final gone = release(release(init, nr), na, permanent: true);
      expect(staleActives(gone), isEmpty);
    });
  });

  group('dormantCandidates', () {
    test('lists the satisfied nodes that are not active, in ascending id', () {
      // from: core_test.dart: a child initialized before its parent is
      // dormant until the parent initializes
      final (s, top) = root([
        comp('A', key: a),
        comp('B', key: b),
        comp('C', key: c, requires: [d]),
      ]);
      final (created, [na, nb, _]) = createNodes(s, top);
      expect(dormantCandidates(created, const {}), [na, nb]);
      expect(dormantCandidates(activate(created, na), const {}), [nb]);
    });

    test('a node of an uninitialized scope counts, when it is satisfied', () {
      final (s, top) = root([comp('A', key: a)]);
      final (s1, low) = child(s, top, [
        comp('R', key: b, requires: [a]),
      ]);
      final (s2, [nr]) = createNodes(s1, low);
      expect(dormantCandidates(s2, const {}), isEmpty);
      final (s3, [na]) = createNodes(s2, top);
      expect(dormantCandidates(s3, const {}), [na]);
      expect(dormantCandidates(activate(s3, na), const {}), [nr]);
    });

    test('does not list an active node, also while its release runs', () {
      final (s, top) = root([comp('A', key: a)]);
      final (init, [n]) = initialize(s, top);
      expect(dormantCandidates(init, const {}), isEmpty);
      expect(dormantCandidates(beginRelease(init, n), const {}), isEmpty);
      expect(dormantCandidates(release(init, n), const {}), [n]);
    });

    test('does not list a removed node', () {
      // from: regression_test.dart: a disposed consumer does not activate
      // again when its publisher leaves and a new one arrives
      // (V-T-RT-LC-003)
      final (s, top) = root([comp('A', key: a)]);
      final (init, [n]) = initialize(s, top);
      expect(
        dormantCandidates(release(init, n, permanent: true), const {}),
        isEmpty,
      );
    });

    test('does not list a node whose release is blocked', () {
      // from: core_test.dart: cleanup failure blocks automatic reacquisition
      final (s, top) = root([comp('A', key: a)]);
      final (init, [n]) = initialize(s, top);
      expect(
        dormantCandidates(release(init, n, ownFailed: true), const {}),
        isEmpty,
      );
    });

    test('lists a node whose last activation failed', () {
      // from: regression_test.dart: a throwing automatic activation is
      // attempted once per reconciliation and again on a later mutation
      final (s, top) = root([comp('A', key: a)]);
      final (init, [n]) = initialize(s, top);
      final (running, _) = beginActivation(release(init, n), n);
      final failed = endActivation(
        running,
        n,
        failure: const Some(
          Fail<DiFailure>(ActivationFailure('A', 'x'), StackTrace.empty),
        ),
        awaiting: const {},
        failed: true,
      );
      expect(nodePhase(failed, n), NodePhase.activationFailed);
      expect(dormantCandidates(failed, const {}), [n]);
    });

    test('does not list a node that failed in this reconciliation', () {
      // from: regression_test.dart: a throwing automatic activation is
      // attempted once per reconciliation and again on a later mutation
      final (s, top) = root([comp('A', key: a), comp('B', key: b)]);
      final (created, [na, nb]) = createNodes(s, top);
      expect(dormantCandidates(created, {na}), [nb]);
      expect(dormantCandidates(created, {na, nb}), isEmpty);
    });

    test('does not list a node that waits for a withdrawal', () {
      final (s, top) = root([comp('A', key: a), comp('B', key: b)]);
      final (created, [na, nb]) = createNodes(s, top);
      final waiting = addWithdrawal(created, na, {nb});
      expect(dormantCandidates(waiting, const {}), [na]);
    });

    test('does not list a node whose disposal was requested', () {
      final (s, top) = root([comp('A', key: a), comp('B', key: b)]);
      final (created, [na, nb]) = createNodes(s, top);
      expect(dormantCandidates(requestNodeDisposal(created, na), const {}), [
        nb,
      ]);
    });

    test('does not list a node of a scope whose disposal was requested', () {
      final (s, top) = root([comp('A', key: a)]);
      final (s1, low) = child(s, top, [comp('B', key: b)]);
      final (s2, [nb]) = createNodes(s1, low);
      final (s3, [na]) = createNodes(s2, top);
      expect(dormantCandidates(s3, const {}), [nb, na]);
      // The request of the root covers the child.
      expect(
        dormantCandidates(requestScopeDisposal(s3, top), const {}),
        isEmpty,
      );
      // The request of the child leaves the root.
      expect(dormantCandidates(requestScopeDisposal(s3, low), const {}), [na]);
    });

    test('does not list a node of a scope that is disposing or disposed', () {
      final (s, top) = root([comp('A', key: a)]);
      final (created, _) = createNodes(s, top);
      final disposing = markDisposing(created, [top]);
      expect(dormantCandidates(disposing, const {}), isEmpty);
      final disposed = markDisposed(disposing, top);
      expect(dormantCandidates(disposed, const {}), isEmpty);
    });

    test('lists a node of a scope that is initializing', () {
      final (s, top) = root([comp('A', key: a)]);
      final (created, [n]) = createNodes(s, top);
      expect(scopePhase(created, top), ScopePhase.initializing);
      expect(dormantCandidates(created, const {}), [n]);
    });
  });

  group('scenarios of the regression tests', () {
    // root publishes K. mid declares K, and is not initialized. leaf holds a
    // publisher P that reads K, and a dependent D that reads P.
    (RuntimeState, ScopeId, ScopeId, ScopeId, List<NodeId>) chain() {
      const k = DiKey<int>(name: 'k');
      final (s, top) = root([comp('K1', key: k)]);
      final (s1, mid) = child(s, top, [comp('K2', key: k)]);
      final (s2, leaf) = child(s1, mid, [
        comp('P', key: a, requires: [k]),
        comp('D', key: b, requires: [a]),
      ]);
      final (s3, topIds) = initialize(s2, top);
      final (s4, leafIds) = initialize(s3, leaf);
      return (s4, top, mid, leaf, [...topIds, ...leafIds]);
    }

    test(
      'a dependent whose own release failed does not block the publisher',
      () {
        // from: regression_test.dart: a dependent cleanup failure does not
        // block the publisher reload
        final (s, _, mid, _, [k1, p, d]) = chain();
        expect(withdrawalReach(s, k1), {k1, p, d});
        // The release order: the dependents first.
        var next = beginRelease(s, k1);
        next = release(next, d, ownFailed: true);
        next = release(next, p);
        next = endRelease(next, k1, ownFailed: false, permanent: true);
        expect(nodePhase(next, d), NodePhase.disposeFailed);
        expect(nodePhase(next, p), NodePhase.waiting);
        // The mid scope initializes and publishes K again.
        final (afterMid, _) = initialize(next, mid);
        expect(dormantCandidates(afterMid, const {}), [p]);
      },
    );

    test('a node whose own release failed stays blocked', () {
      // from: regression_test.dart: a component whose own cleanup fails stays
      // blocked
      final (s, _, mid, _, [k1, p, d]) = chain();
      var next = beginRelease(s, k1);
      next = release(next, d);
      next = release(next, p, ownFailed: true);
      next = endRelease(next, k1, ownFailed: false, permanent: true);
      final (afterMid, _) = initialize(next, mid);
      expect(dormantCandidates(afterMid, const {}), isEmpty);
      expect(nodePhase(afterMid, p), NodePhase.disposeFailed);
      expect(nodePhase(afterMid, d), NodePhase.waiting);
    });

    test(
      'a disposed consumer does not activate when a new publisher comes',
      () {
        // from: regression_test.dart: a disposed consumer does not activate
        // again when its publisher leaves and a new one arrives
        // (V-T-RT-LC-003)
        final (s, _, mid, _, [k1, p, d]) = chain();
        var next = release(s, d, permanent: true);
        next = release(release(next, p), k1, permanent: true);
        final (afterMid, _) = initialize(next, mid);
        expect(dormantCandidates(afterMid, const {}), [p]);
        expect(nodePhase(afterMid, d), NodePhase.disposed);
      },
    );

    test('a publisher that returns wakes its reader after the withdrawal', () {
      // from: core_test.dart: publisher removal deactivates and later
      // replacement reactivates
      final (s, _, mid, _, [k1, p, d]) = chain();
      final withdrawing = addWithdrawal(
        requestNodeDisposal(s, k1),
        k1,
        const {},
      );
      var next = release(release(beginRelease(withdrawing, k1), d), p);
      next = endRelease(next, k1, ownFailed: false, permanent: true);
      next = finishWithdrawal(next, k1);
      expect(next.withdrawals, isEmpty);
      final (afterMid, [k2]) = initialize(next, mid);
      expect(dormantCandidates(afterMid, const {}), [p]);
      final reborn = activate(afterMid, p, deps: {k2});
      expect(target(reborn, p).values.single, Some(PublisherRef(k2, 1)));
      expect(dormantCandidates(reborn, const {}), [d]);
    });
  });

  group('subtree', () {
    test('lists the scope and its descendants, parents first', () {
      final (s, top) = root([comp('A', key: a)]);
      final (s1, one) = child(s, top, [comp('B', key: b)]);
      final (s2, oneOne) = child(s1, one, [comp('C', key: c)]);
      final (s3, two) = child(s2, top, [comp('D', key: d)]);
      final (s4, oneTwo) = child(s3, one, [comp('E')]);
      expect(subtree(s4, top), [top, one, oneOne, oneTwo, two]);
      expect(subtree(s4, one), [one, oneOne, oneTwo]);
      expect(subtree(s4, two), [two]);
    });

    test('does not list a disposed child', () {
      final (s, top) = root([comp('A', key: a)]);
      final (s1, one) = child(s, top, [comp('B', key: b)]);
      final disposed = markDisposed(s1, one);
      expect(subtree(disposed, top), [top]);
    });
  });

  group('withdrawalReach', () {
    test('holds the root and its transitive active dependents', () {
      final (s, top) = root([
        comp('P', key: a),
        comp('R', key: b, requires: [a]),
        comp('T', key: c, requires: [b]),
        comp('U', key: d),
      ]);
      final (init, [p, r, t, u]) = initialize(s, top);
      expect(withdrawalReach(init, p), {p, r, t});
      expect(withdrawalReach(init, r), {r, t});
      expect(withdrawalReach(init, t), {t});
      expect(withdrawalReach(init, u), {u});
    });

    test('does not hold a dependent that is not active', () {
      final (s, top) = root([
        comp('P', key: a),
        comp('R', key: b, requires: [a]),
        comp('T', key: c, requires: [b]),
      ]);
      final (init, [p, r, t]) = initialize(s, top);
      expect(withdrawalReach(release(init, r), p), {p});
      expect(withdrawalReach(release(init, t), p), {p, r});
    });

    test('holds a dependent whose release started', () {
      final (s, top) = root([
        comp('P', key: a),
        comp('R', key: b, requires: [a]),
      ]);
      final (init, [p, r]) = initialize(s, top);
      expect(withdrawalReach(beginRelease(init, r), p), {p, r});
    });

    test('follows the readers of other scopes, and ends in a diamond', () {
      final (s, top) = root([
        comp('P', key: a),
        comp('L', key: b, requires: [a]),
        comp('M', key: c, requires: [a]),
      ]);
      final (s1, low) = child(s, top, [
        comp('Join', key: d, requires: [b, c]),
      ]);
      final (s2, [p, l, m]) = initialize(s1, top);
      final (s3, [join]) = initialize(s2, low);
      expect(withdrawalReach(s3, p), {p, l, m, join});
    });
  });

  group('withdrawalCancels', () {
    test('cancels a running activation that reads a node of the reach', () {
      final (s, top) = root([
        comp('P', key: a),
        comp('R', key: b, requires: [a]),
        comp('Other', key: c),
      ]);
      final (created, [p, r, other]) = createNodes(s, top);
      final withP = activate(created, p);
      final (running, _) = beginActivation(withP, r);
      final (runningOther, _) = beginActivation(running, other);
      expect(withdrawalCancels(runningOther, {p}), {r});
    });

    test('cancels an activation by the reads that it recorded', () {
      final (s, top) = root([comp('P', key: a), comp('R', key: b)]);
      final (created, [p, r]) = createNodes(s, top);
      final (running, _) = beginActivation(created, r);
      expect(withdrawalCancels(running, {p}), isEmpty);
      expect(
        withdrawalCancels(
          running,
          {p},
          reads: {
            r: {p},
          },
        ),
        {r},
      );
    });

    test('does not cancel a node that is not in flight', () {
      final (s, top) = root([
        comp('P', key: a),
        comp('R', key: b, requires: [a]),
      ]);
      final (init, [p, _]) = initialize(s, top);
      expect(withdrawalCancels(init, {p}), isEmpty);
    });

    test('does not cancel a node whose disposal was requested', () {
      final (s, top) = root([
        comp('P', key: a),
        comp('R', key: b, requires: [a]),
      ]);
      final (created, [p, r]) = createNodes(s, top);
      final withP = activate(created, p);
      final (running, _) = beginActivation(withP, r);
      expect(withdrawalCancels(requestNodeDisposal(running, r), {p}), isEmpty);
      expect(
        withdrawalCancels(requestScopeDisposal(running, top), {p}),
        isEmpty,
      );
    });

    test('does not count a publication of the node itself', () {
      final (s, top) = root([comp('P', key: a)]);
      final (s1, low) = child(s, top, [
        comp('R', key: a, requires: [a]),
      ]);
      final (s2, [p]) = initialize(s1, top);
      final (s3, [r]) = createNodes(s2, low);
      final (running, _) = beginActivation(s3, r);
      expect(withdrawalCancels(running, {r}), isEmpty);
      expect(withdrawalCancels(running, {p}), {r});
    });
  });

  group('withdrawalsOf', () {
    test('lists the roots whose reach holds the node', () {
      final (s, top) = root([
        comp('P', key: a),
        comp('R', key: b, requires: [a]),
        comp('Q', key: c),
      ]);
      final (init, [p, r, q]) = initialize(s, top);
      final one = addWithdrawal(init, p, const {});
      final two = addWithdrawal(one, r, const {});
      expect(withdrawalsOf(two, r), [p, r]);
      expect(withdrawalsOf(two, p), [p]);
      expect(withdrawalsOf(two, q), isEmpty);
    });
  });
}
