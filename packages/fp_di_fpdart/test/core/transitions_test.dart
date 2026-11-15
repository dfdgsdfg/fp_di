import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fp_di_fpdart/src/core/core.dart';
import 'package:fp_di_fpdart/src/finalizers.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

const boom = Fail<DiFailure>(ActivationFailure('R', 'boom'), StackTrace.empty);

void main() {
  group('declareScope', () {
    test('numbers the scopes, and a root does not raise the revision', () {
      // The creation of a root is no transition of the runtime. Only
      // `childCreated` is one.
      final (s, first) = root([comp('A', key: a)]);
      final (s1, second) = root2(s);
      expect((first.value, second.value), (0, 1));
      expect(s.revision, 0);
      expect(s1.revision, 0);
      expect(s1.nextScopeId, 2);
    });

    test('a child joins the children of its parent in creation order', () {
      final (s, top) = root([comp('A', key: a)]);
      final (s1, one) = child(s, top, [comp('B', key: b)]);
      final (s2, two) = child(s1, top, [comp('C', key: c)]);
      expect(scopeRecord(s2, top).children, [one, two]);
      expect(scopeRecord(s2, one).parent, Some(top));
      expect(scopeRecord(s2, top).parent.isNone(), isTrue);
      expect(s2.revision, 2, reason: 'one for each child');
    });

    test('a scope has no node and no binding before the initialization', () {
      // from: core_test.dart: nodes is empty and get throws before initialize
      final (s, top) = root([comp('A', key: a)]);
      expect(scopeRecord(s, top).nodes, isEmpty);
      expect(scopeRecord(s, top).bindings, isEmpty);
      expect(s.nodes, isEmpty);
    });
  });

  group('createNodes', () {
    test('creates one node for each component in declaration order', () {
      final (s, top) = root([comp('A', key: a), comp('B', key: b)]);
      final before = s.revision;
      final (created, ids) = createNodes(s, top);
      expect(ids, [NodeId(0), NodeId(1)]);
      expect(scopeRecord(created, top).nodes, ids);
      expect(scopeRecord(created, top).initializing, isTrue);
      expect([for (final id in ids) nodeRecord(created, id).index], [0, 1]);
      expect(created.nextNodeId, 2);
      expect(created.revision, before + 1);
    });

    test('the ids grow across the scopes of the runtime', () {
      final (s, top) = root([comp('A', key: a)]);
      final (s1, low) = child(s, top, [comp('B', key: b), comp('C', key: c)]);
      final (s2, lowIds) = createNodes(s1, low);
      final (s3, topIds) = createNodes(s2, top);
      expect(lowIds, [NodeId(0), NodeId(1)]);
      expect(topIds, [NodeId(2)]);
      expect(s3.nextNodeId, 3);
    });

    test('a new node is not active, and has nothing committed', () {
      final (s, top) = root([comp('A', key: a)]);
      final (created, [n]) = createNodes(s, top);
      final node = nodeRecord(created, n);
      expect(node.active || node.deactivating || node.removed, isFalse);
      expect(node.inFlight.isNone(), isTrue);
      expect(node.value.isNone(), isTrue);
      expect(node.commits, 0);
      expect(node.available, isTrue);
      expect(node.committed, isEmpty);
      expect(nodePhase(created, n), NodePhase.inactive);
    });
  });

  group('beginActivation', () {
    test('gives growing tickets and makes the node activating', () {
      final (s, top) = root([comp('A', key: a), comp('B', key: b)]);
      final (created, [na, nb]) = createNodes(s, top);
      final (s1, first) = beginActivation(created, na);
      final (s2, second) = beginActivation(s1, nb);
      expect((first, second), (0, 1));
      expect(nodeRecord(s2, na).inFlight, const Some(0));
      expect(nodeRecord(s2, nb).inFlight, const Some(1));
      expect(nodePhase(s2, na), NodePhase.activating);
      expect(s2.revision, created.revision + 2);
    });

    test('clears the failure of the last activation', () {
      // from: observation_test.dart: a later successful attempt clears the
      // failure
      final (s, top) = root([comp('R', key: b)]);
      final (init, [n]) = initialize(s, top);
      final (begun, _) = beginActivation(release(init, n), n);
      final failed = endActivation(
        begun,
        n,
        failure: const Some(boom),
        awaiting: const {},
        failed: true,
      );
      expect(nodePhase(failed, n), NodePhase.activationFailed);
      final (again, _) = beginActivation(failed, n);
      expect(nodeRecord(again, n).activationFailure.isNone(), isTrue);
      expect(nodePhase(again, n), NodePhase.activating);
    });
  });

  group('commit', () {
    test('binds the keys with the new commit number, in one step', () {
      // from: runtime_state_test.dart: a node goes through its phases, and
      // commits count
      final (s, top) = root([comp('A', key: a)]);
      final (created, [n]) = createNodes(s, top);
      final committed = activate(created, n, value: 7);
      final node = nodeRecord(committed, n);
      expect(node.active, isTrue);
      expect(node.value, const Some(7));
      expect(node.commits, 1);
      expect(node.inFlight.isNone(), isTrue);
      expect(scopeRecord(committed, top).bindings, {a: PublisherRef(n, 1)});
      expect(nodePhase(committed, n), NodePhase.active);
      expect(committed.revision, created.revision + 2);
    });

    test('a second commit is a new publisher identity of the same node', () {
      // from: runtime_state_test.dart: a rebuilt node commits again under the
      // same id
      final (s, top) = root([comp('A', key: a)]);
      final (init, [n]) = initialize(s, top);
      final again = activate(release(init, n), n);
      expect(nodeRecord(again, n).commits, 2);
      expect(scopeRecord(again, top).bindings, {a: PublisherRef(n, 2)});
    });

    test('keeps the view, the dependencies, and the finalizers', () {
      final (s, top) = root([
        comp('A', key: a),
        comp('R', key: b, requires: [a]),
      ]);
      final (created, [na, nr]) = createNodes(s, top);
      final withA = activate(created, na);
      final owned = Finalizers.empty.push('R', () {});
      final (begun, _) = beginActivation(withA, nr);
      final view = target(begun, nr);
      final committed = commit(begun, nr, 1, view, {na, nr}, owned);
      final node = nodeRecord(committed, nr);
      expect(node.committed, view);
      expect(node.dependencies, {na}, reason: 'a node never reads itself');
      expect(node.finalizers.isEmpty, isFalse);
    });

    test('an effect binds no key', () {
      final (s, top) = root([effect('E')]);
      final (created, [n]) = createNodes(s, top);
      expect(declaredPublishes(created, nodeRecord(created, n)), isEmpty);
      final committed = activate(created, n);
      expect(nodeRecord(committed, n).active, isTrue);
      expect(scopeRecord(committed, top).bindings, isEmpty);
    });

    test('clears a block of the reactivation', () {
      final (s, top) = root([comp('A', key: a)]);
      final (init, [n]) = initialize(s, top);
      final blocked = release(init, n, ownFailed: true);
      expect(nodeRecord(blocked, n).reactivationBlocked, isTrue);
      final again = activate(blocked, n);
      expect(nodeRecord(again, n).reactivationBlocked, isFalse);
    });

    test('conflictingPublication names a key that the scope binds already', () {
      // from: core_test.dart: duplicate publishers are rejected atomically
      final (s, top) = root([comp('A', key: a)]);
      final (init, [n]) = initialize(s, top);
      expect(conflictingPublication(init, n), const Some(a));
      final (created, [fresh]) = createNodes(s, top);
      expect(conflictingPublication(created, fresh).isNone(), isTrue);
    });

    test('a nearer scope that binds the key is no conflict', () {
      final (s, top) = root([comp('Far', key: a)]);
      final (s1, low) = child(s, top, [comp('Near', key: a)]);
      final (s2, _) = initialize(s1, top);
      final (s3, [near]) = createNodes(s2, low);
      expect(conflictingPublication(s3, near).isNone(), isTrue);
    });
  });

  group('endActivation', () {
    final (base, top) = root([comp('R', key: b)]);

    RuntimeState begun(RuntimeState s, NodeId n) => beginActivation(s, n).$1;

    test('a withdrawal that cancels the activation is not a failure', () {
      final (init, [n]) = initialize(base, top);
      final released = release(init, n);
      final running = begun(released, n);
      final ended = endActivation(
        running,
        n,
        failure: const None(),
        awaiting: {NodeId(9)},
        failed: false,
      );
      final node = nodeRecord(ended, n);
      expect(node.inFlight.isNone(), isTrue);
      expect(node.doomed, isFalse);
      expect(node.awaiting, {NodeId(9)});
      expect(node.activationFailure.isNone(), isTrue);
      expect(nodePhase(ended, n), NodePhase.inactive);
    });

    test('an automatic failure records the cause in an initialized scope', () {
      // from: runtime_state_test.dart: an automatic activation failure is in
      // the state, then in errors
      final (init, [n]) = initialize(base, top);
      final ended = endActivation(
        begun(release(init, n), n),
        n,
        failure: const Some(boom),
        awaiting: const {},
        failed: true,
      );
      expect(nodeRecord(ended, n).doomed, isFalse);
      expect(nodeRecord(ended, n).activationFailure, const Some(boom));
      expect(nodePhase(ended, n), NodePhase.activationFailed);
    });

    test('a failure while the scope initializes dooms the node', () {
      // from: runtime_state_test.dart: a failed initialize returns the scope
      // to declared
      final (created, [n]) = createNodes(base, top);
      final ended = endActivation(
        begun(created, n),
        n,
        failure: const Some(boom),
        awaiting: const {},
        failed: true,
      );
      expect(nodeRecord(ended, n).doomed, isTrue);
      expect(nodePhase(ended, n), NodePhase.activating);
    });

    test('a cancel by the owner dooms the node and records no failure', () {
      final (created, [n]) = createNodes(base, top);
      final ended = endActivation(
        begun(created, n),
        n,
        failure: const None(),
        awaiting: const {},
        failed: true,
      );
      expect(nodeRecord(ended, n).doomed, isTrue);
      expect(nodeRecord(ended, n).activationFailure.isNone(), isTrue);
    });

    test('a cancel by the owner in an initialized scope leaves the node '
        'inactive', () {
      final (init, [n]) = initialize(base, top);
      final ended = endActivation(
        begun(release(init, n), n),
        n,
        failure: const None(),
        awaiting: const {},
        failed: true,
      );
      expect(nodeRecord(ended, n).doomed, isFalse);
      expect(nodePhase(ended, n), NodePhase.inactive);
    });

    test('keeps the awaited roots of an earlier withdrawal', () {
      final (init, [n]) = initialize(base, top);
      final awaiting = addWithdrawal(release(init, n), NodeId(5), {n});
      final ended = endActivation(
        begun(awaiting, n),
        n,
        failure: const None(),
        awaiting: {NodeId(6)},
        failed: false,
      );
      expect(nodeRecord(ended, n).awaiting, {NodeId(5), NodeId(6)});
    });
  });

  group('release', () {
    test('beginRelease makes the node deactivating and unavailable', () {
      // from: runtime_state_test.dart: withdraws the keys in the transition
      // that starts it
      final (s, top) = root([comp('A', key: a)]);
      final (init, [n]) = initialize(s, top);
      final begun = beginRelease(init, n);
      final node = nodeRecord(begun, n);
      expect(node.deactivating, isTrue);
      expect(node.active, isTrue);
      expect(node.available, isFalse);
      expect(nodePhase(begun, n), NodePhase.deactivating);
      expect(scopeRecord(begun, top).bindings, {a: PublisherRef(n, 1)});
      expect(resolve(begun, top, a).isNone(), isTrue);
      expect(begun.revision, init.revision + 1);
    });

    test('beginRelease does nothing for a node that is not active', () {
      final (s, top) = root([comp('A', key: a)]);
      final (created, [n]) = createNodes(s, top);
      expect(identical(beginRelease(created, n), created), isTrue);
    });

    test('beginRelease does nothing for a node that releases already', () {
      final (s, top) = root([comp('A', key: a)]);
      final (init, [n]) = initialize(s, top);
      final begun = beginRelease(init, n);
      expect(identical(beginRelease(begun, n), begun), isTrue);
    });

    test('beginRelease does nothing for a removed node', () {
      final (s, top) = root([comp('A', key: a)]);
      final (init, [n]) = initialize(s, top);
      final removed = release(init, n, permanent: true);
      expect(identical(beginRelease(removed, n), removed), isTrue);
    });

    test('endRelease drops the bindings and the committed activation', () {
      final (s, top) = root([
        comp('A', key: a),
        comp('R', key: b, requires: [a]),
      ]);
      final (init, [na, nr]) = initialize(s, top);
      final ended = release(release(init, nr), na);
      final node = nodeRecord(ended, na);
      expect(scopeRecord(ended, top).bindings, isEmpty);
      expect(node.active || node.deactivating, isFalse);
      expect(node.value.isNone(), isTrue);
      expect(node.committed, isEmpty);
      expect(node.finalizers.isEmpty, isTrue);
      expect(node.commits, 1);
      expect(nodeRecord(ended, nr).dependencies, isEmpty);
      expect(nodePhase(ended, na), NodePhase.inactive);
      expect(nodePhase(ended, nr), NodePhase.waiting);
    });

    test('endRelease keeps the bindings of other nodes', () {
      final (s, top) = root([comp('A', key: a), comp('B', key: b)]);
      final (init, [na, nb]) = initialize(s, top);
      final ended = release(init, na);
      expect(scopeRecord(ended, top).bindings, {b: PublisherRef(nb, 1)});
    });

    test('an own failure blocks the reactivation', () {
      // from: core_test.dart: cleanup failure blocks automatic reacquisition
      final (s, top) = root([comp('A', key: a)]);
      final (init, [n]) = initialize(s, top);
      final ended = release(init, n, ownFailed: true);
      expect(nodeRecord(ended, n).reactivationBlocked, isTrue);
      expect(nodePhase(ended, n), NodePhase.disposeFailed);
    });

    test('a permanent release removes the node, also after a failure', () {
      final (s, top) = root([comp('A', key: a)]);
      final (init, [n]) = initialize(s, top);
      final ended = release(init, n, permanent: true, ownFailed: true);
      expect(nodeRecord(ended, n).removed, isTrue);
      expect(nodePhase(ended, n), NodePhase.disposed);
      expect(scopeRecord(ended, top).nodes, [n], reason: 'keeps its place');
    });

    test('endRelease without a begun release removes only a permanent one', () {
      final (s, top) = root([comp('A', key: a)]);
      final (created, [n]) = createNodes(s, top);
      final kept = endRelease(created, n, ownFailed: false, permanent: false);
      expect(identical(kept, created), isTrue);
      final removed = endRelease(created, n, ownFailed: false, permanent: true);
      expect(nodePhase(removed, n), NodePhase.disposed);
    });

    test('endRelease of a removed node changes nothing', () {
      final (s, top) = root([comp('A', key: a)]);
      final (created, [n]) = createNodes(s, top);
      final removed = removeNode(created, n);
      expect(
        identical(
          endRelease(removed, n, ownFailed: true, permanent: true),
          removed,
        ),
        isTrue,
      );
      expect(identical(removeNode(removed, n), removed), isTrue);
    });

    test('removeNode drops the failure of the node', () {
      final (s, top) = root([comp('R', key: b)]);
      final (init, [n]) = initialize(s, top);
      final failed = endActivation(
        beginActivation(release(init, n), n).$1,
        n,
        failure: const Some(boom),
        awaiting: const {},
        failed: true,
      );
      expect(
        nodeRecord(removeNode(failed, n), n).activationFailure.isNone(),
        isTrue,
      );
    });
  });

  group('initialize and rollback', () {
    test('finishInitialize ends the initialization with success', () {
      final (s, top) = root([comp('A', key: a)]);
      final (init, _) = initialize(s, top);
      final scope = scopeRecord(init, top);
      expect((scope.initialized, scope.initializing), (true, false));
    });

    test('rollbackInitialize returns the scope to declared', () {
      // from: runtime_state_test.dart: a failed initialize returns the scope
      // to declared
      // from: core_test.dart: a failed initialize binds nothing and a retry
      // can succeed
      final (s, top) = root([comp('A', key: a), comp('B', key: b)]);
      final (created, [na, nb]) = createNodes(s, top);
      final active = activate(created, na);
      final rolled = rollbackInitialize(
        release(release(active, na, permanent: true), nb, permanent: true),
        top,
      );
      expect(scopePhase(rolled, top), ScopePhase.declared);
      expect(scopeRecord(rolled, top).nodes, isEmpty);
      expect(scopeRecord(rolled, top).bindings, isEmpty);
      // The records stay, so a holder of an id reads the phase disposed.
      expect(nodePhase(rolled, na), NodePhase.disposed);
      expect(nodePhase(rolled, nb), NodePhase.disposed);
      expect(rolled.nextNodeId, 2, reason: 'ids are never reused');
      // A retry creates the nodes again, with new ids.
      final (retry, ids) = createNodes(rolled, top);
      expect(ids, [NodeId(2), NodeId(3)]);
      expect(scopePhase(retry, top), ScopePhase.initializing);
    });

    test(
      'rollbackInitialize keeps the removed nodes of a requested disposal',
      () {
        // from: runtime_state_test.dart: a canceled initialize ends in
        // disposeRequested
        final (s, top) = root([comp('A', key: a)]);
        final (created, [n]) = createNodes(s, top);
        final requested = requestScopeDisposal(created, top);
        final rolled = rollbackInitialize(removeNode(requested, n), top);
        expect(scopePhase(rolled, top), ScopePhase.disposeRequested);
        expect(scopeRecord(rolled, top).nodes, [n]);
        expect(nodePhase(rolled, n), NodePhase.disposed);
        expect(scopeRecord(rolled, top).initializing, isFalse);
      },
    );

    test('a failed initialize of a child leaves its parent as it was', () {
      final (s, top) = root([comp('A', key: a)]);
      final (s1, low) = child(s, top, [
        comp('R', key: b, requires: [a]),
      ]);
      final (s2, [na]) = initialize(s1, top);
      final (s3, [nr]) = createNodes(s2, low);
      final rolled = rollbackInitialize(removeNode(s3, nr), low);
      expect(scopePhase(rolled, low), ScopePhase.declared);
      expect(scopePhase(rolled, top), ScopePhase.initialized);
      expect(nodePhase(rolled, na), NodePhase.active);
    });
  });

  group('disposal of a scope', () {
    test('requestScopeDisposal marks the scope and every descendant', () {
      // from: core_test.dart: disposing a scope recursively disposes
      // descendants
      final (s, top) = root([comp('A', key: a)]);
      final (s1, mid) = child(s, top, [comp('B', key: b)]);
      final (s2, low) = child(s1, mid, [comp('C', key: c)]);
      final requested = requestScopeDisposal(s2, mid);
      expect(scopePhase(requested, top), ScopePhase.declared);
      expect(scopePhase(requested, mid), ScopePhase.disposeRequested);
      expect(scopePhase(requested, low), ScopePhase.disposeRequested);
      expect(scopeRecord(requested, low).disposeRequested, isFalse);
    });

    test('markDisposing, markDisposed, and the children of the parent', () {
      // from: runtime_state_test.dart: goes through disposeRequested,
      // disposing, and disposed
      final (s, top) = root([comp('A', key: a)]);
      final (s1, mid) = child(s, top, [comp('B', key: b)]);
      final (s2, low) = child(s1, mid, [comp('C', key: c)]);
      final tree = subtree(s2, mid);
      expect(tree, [mid, low]);
      var next = markDisposing(requestScopeDisposal(s2, mid), tree);
      expect(scopePhase(next, mid), ScopePhase.disposing);
      expect(scopePhase(next, low), ScopePhase.disposing);
      for (final id in tree.reversed) {
        next = markDisposed(next, id);
      }
      expect(scopePhase(next, low), ScopePhase.disposed);
      expect(scopePhase(next, mid), ScopePhase.disposed);
      expect(scopeRecord(next, mid).children, isEmpty);
      expect(scopeRecord(next, top).children, isEmpty);
      expect(scopeRecord(next, mid).disposing, isFalse);
      expect(next.scopes, contains(low), reason: 'the record stays');
    });

    test('markDisposed clears the bindings of the scope', () {
      final (s, top) = root([comp('A', key: a)]);
      final (init, [n]) = initialize(s, top);
      final disposed = markDisposed(removeNode(init, n), top);
      expect(scopeRecord(disposed, top).bindings, isEmpty);
      expect(resolve(disposed, top, a).isNone(), isTrue);
    });

    test('requestNodeDisposal sets the flag of the node', () {
      final (s, top) = root([comp('A', key: a)]);
      final (init, [n]) = initialize(s, top);
      final requested = requestNodeDisposal(init, n);
      expect(nodeRecord(requested, n).disposeRequested, isTrue);
      expect(setupRefused(requested, n), isTrue);
      expect(setupRefused(init, n), isFalse);
    });
  });

  group('withdrawal', () {
    test('addWithdrawal keeps the reach and makes the canceled nodes wait', () {
      final (s, top) = root([
        comp('P', key: a),
        comp('R', key: b, requires: [a]),
        comp('Q', key: c, requires: [a]),
      ]);
      final (created, [p, r, q]) = createNodes(s, top);
      final withP = activate(created, p);
      final withR = activate(withP, r, deps: {p});
      final added = addWithdrawal(withR, p, {q});
      expect(added.withdrawals.single.root, p);
      expect(added.withdrawals.single.reach, {p, r});
      expect(nodeRecord(added, q).awaiting, {p});
      expect(nodeRecord(added, r).awaiting, isEmpty);
      expect(withdrawalsOf(added, r), [p]);
      expect(withdrawalsOf(added, q), isEmpty);
    });

    test('the reach is a snapshot of the request', () {
      final (s, top) = root([
        comp('P', key: a),
        comp('R', key: b, requires: [a]),
      ]);
      final (created, [p, r]) = createNodes(s, top);
      final withR = activate(activate(created, p), r, deps: {p});
      final added = addWithdrawal(withR, p, const {});
      // The release of R ends. R is no active dependent of P any more.
      final released = release(release(added, p), r);
      expect(withdrawalReach(released, p), {p});
      expect(released.withdrawals.single.reach, {p, r});
      expect(withdrawalsOf(released, r), [p]);
    });

    test('finishWithdrawal frees the waiting nodes', () {
      final (s, top) = root([comp('P', key: a), comp('Q', key: c)]);
      final (created, [p, q]) = createNodes(s, top);
      final added = addWithdrawal(created, p, {q});
      expect(dormantCandidates(added, const {}), [p]);
      final finished = finishWithdrawal(added, p);
      expect(finished.withdrawals, isEmpty);
      expect(nodeRecord(finished, q).awaiting, isEmpty);
      expect(dormantCandidates(finished, const {}), [p, q]);
    });

    test('finishWithdrawal keeps the other withdrawals', () {
      final (s, top) = root([comp('P', key: a), comp('Q', key: c)]);
      final (created, [p, q]) = createNodes(s, top);
      final both = addWithdrawal(addWithdrawal(created, p, {q}), q, {q});
      expect(nodeRecord(both, q).awaiting, {p, q});
      final finished = finishWithdrawal(both, p);
      expect(finished.withdrawals.map((w) => w.root), [q]);
      expect(nodeRecord(finished, q).awaiting, {q});
    });
  });

  group('revision', () {
    test('every observable transition raises it by one', () {
      final (s, top) = root([comp('A', key: a)]);
      var next = s;
      var expected = s.revision;
      void step(RuntimeState Function(RuntimeState) f, String reason) {
        next = f(next);
        expected++;
        expect(next.revision, expected, reason: reason);
      }

      late NodeId n;
      step((s) {
        final (created, ids) = createNodes(s, top);
        n = ids.single;
        return created;
      }, 'createNodes');
      step((s) => beginActivation(s, n).$1, 'beginActivation');
      step(
        (s) => commit(s, n, 0, const {}, const {}, Finalizers.empty),
        'commit',
      );
      step((s) => beginRelease(s, n), 'beginRelease');
      step(
        (s) => endRelease(s, n, ownFailed: false, permanent: false),
        'endRelease',
      );
      step((s) => removeNode(s, n), 'removeNode');
      step((s) => finishInitialize(s, top), 'finishInitialize');
      step((s) => requestScopeDisposal(s, top), 'requestScopeDisposal');
      step((s) => markDisposing(s, [top]), 'markDisposing');
      step((s) => markDisposed(s, top), 'markDisposed');
    });

    test('a change that no observer sees leaves it', () {
      final (s, top) = root([comp('A', key: a), comp('B', key: b)]);
      final (init, [na, nb]) = initialize(s, top);
      final revision = init.revision;
      expect(requestNodeDisposal(init, na).revision, revision);
      expect(addWithdrawal(init, na, {nb}).revision, revision);
      expect(finishWithdrawal(init, na).revision, revision);
    });

    test('a repeated request of a disposal leaves it', () {
      final (s, top) = root([comp('A', key: a)]);
      final requested = requestScopeDisposal(s, top);
      expect(requested.revision, s.revision + 1);
      expect(requestScopeDisposal(requested, top).revision, requested.revision);
    });

    test('the request of a disposal under a requested parent leaves it', () {
      final (s, top) = root([comp('A', key: a)]);
      final (s1, low) = child(s, top, [comp('B', key: b)]);
      final requested = requestScopeDisposal(s1, top);
      expect(requestScopeDisposal(requested, low).revision, requested.revision);
    });

    test('a doomed end of an activation leaves it', () {
      final (s, top) = root([comp('A', key: a)]);
      final (created, [n]) = createNodes(s, top);
      final (running, _) = beginActivation(created, n);
      // The node is activating before and after: no observer sees a change.
      final doomed = endActivation(
        running,
        n,
        failure: const None(),
        awaiting: const {},
        failed: true,
      );
      expect(doomed.revision, running.revision);
    });

    test('an end of an activation that changes the phase raises it', () {
      final (s, top) = root([comp('A', key: a)]);
      final (init, [n]) = initialize(s, top);
      final (running, _) = beginActivation(release(init, n), n);
      final ended = endActivation(
        running,
        n,
        failure: const Some(boom),
        awaiting: const {},
        failed: true,
      );
      expect(ended.revision, running.revision + 1);
    });

    test('finishInitialize in a requested scope leaves it', () {
      // from: runtime_state_test.dart: an initialize whose members committed
      // completes with success in disposeRequested
      final (s, top) = root([comp('A', key: a)]);
      final (created, _) = createNodes(s, top);
      final requested = requestScopeDisposal(created, top);
      expect(finishInitialize(requested, top).revision, requested.revision);
    });

    test('rollbackInitialize in a requested scope leaves it', () {
      final (s, top) = root([comp('A', key: a)]);
      final (created, _) = createNodes(s, top);
      final requested = requestScopeDisposal(created, top);
      expect(rollbackInitialize(requested, top).revision, requested.revision);
    });

    test('a read of a query leaves it', () {
      // from: runtime_state_test.dart: reads of the state do not change the
      // revision
      final (s, top) = root([comp('A', key: a)]);
      final (init, [n]) = initialize(s, top);
      final revision = init.revision;
      nodePhase(init, n);
      scopePhase(init, top);
      target(init, n);
      staleActives(init);
      dormantCandidates(init, const {});
      expect(init.revision, revision);
    });
  });
}

(RuntimeState, ScopeId) root2(RuntimeState s) =>
    declareScope(s, const None(), [comp('Z', key: d)]);
