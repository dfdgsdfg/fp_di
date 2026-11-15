import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fp_di_fpdart/src/core/core.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

/// The state [s] with the node [n] changed by [change].
RuntimeState withNode(
  RuntimeState s,
  NodeId n,
  NodeRecord Function(NodeRecord node) change,
) => s.copyWith(nodes: {...s.nodes, n: change(nodeRecord(s, n))});

/// The state [s] with the scope [id] changed by [change].
RuntimeState withScope(
  RuntimeState s,
  ScopeId id,
  ScopeRecord Function(ScopeRecord scope) change,
) => s.copyWith(scopes: {...s.scopes, id: change(scopeRecord(s, id))});

void main() {
  group('nodePhase, one row of the table at a time', () {
    // A node of a root that reads `a`, which nothing publishes yet, and a node
    // that reads nothing.
    final (base, top) = root([
      comp('Needy', key: b, requires: [a]),
      comp('Free', key: c),
    ]);
    final (created, [needy, free]) = createNodes(base, top);
    const failure = Fail<DiFailure>(
      ActivationFailure('Free', 'boom'),
      StackTrace.empty,
    );

    test('row 1: a removed node is disposed, whatever else holds', () {
      final s = withNode(
        created,
        free,
        (n) => n.copyWith(
          removed: true,
          active: true,
          deactivating: true,
          inFlight: const Some(1),
          doomed: true,
          reactivationBlocked: true,
        ),
      );
      expect(nodePhase(s, free), NodePhase.disposed);
    });

    test('row 2: an active node that does not release is active', () {
      // from: runtime_state_test.dart: a node goes through its phases, and
      // commits count
      final s = withNode(
        created,
        free,
        (n) => n.copyWith(
          active: true,
          inFlight: const Some(1),
          doomed: true,
          reactivationBlocked: true,
          activationFailure: const Some(failure),
        ),
      );
      expect(nodePhase(s, free), NodePhase.active);
    });

    test('row 3: a node that releases is deactivating', () {
      final s = withNode(
        created,
        free,
        (n) => n.copyWith(
          active: true,
          deactivating: true,
          inFlight: const Some(1),
          reactivationBlocked: true,
        ),
      );
      expect(nodePhase(s, free), NodePhase.deactivating);
    });

    test('row 4: a running activation makes a node activating', () {
      final (s, _) = beginActivation(created, free);
      expect(nodePhase(s, free), NodePhase.activating);
    });

    test('row 4: a doomed node is activating without an activation', () {
      final s = withNode(created, free, (n) => n.copyWith(doomed: true));
      expect(nodePhase(s, free), NodePhase.activating);
    });

    test('row 4: an activation outranks the blocked and waiting rows', () {
      final s = withNode(
        created,
        needy,
        (n) => n.copyWith(
          inFlight: const Some(1),
          reactivationBlocked: true,
          activationFailure: const Some(failure),
        ),
      );
      expect(nodePhase(s, needy), NodePhase.activating);
    });

    test('row 5: a blocked node is disposeFailed, also while it waits', () {
      final s = withNode(
        created,
        needy,
        (n) => n.copyWith(
          reactivationBlocked: true,
          activationFailure: const Some(failure),
        ),
      );
      expect(unmet(s, needy), [a]);
      expect(nodePhase(s, needy), NodePhase.disposeFailed);
    });

    test('row 6: a node with an unmet required key is waiting', () {
      expect(nodePhase(created, needy), NodePhase.waiting);
    });

    test('row 6: a missing key outranks a past failure', () {
      // from: observation_test.dart: a missing key outranks the past failure
      final s = withNode(
        created,
        needy,
        (n) => n.copyWith(activationFailure: const Some(failure)),
      );
      expect(nodePhase(s, needy), NodePhase.waiting);
    });

    test('row 7: a node with a failure and no unmet key is failed', () {
      final s = withNode(
        created,
        free,
        (n) => n.copyWith(activationFailure: const Some(failure)),
      );
      expect(nodePhase(s, free), NodePhase.activationFailed);
    });

    test('row 8: otherwise the node is inactive', () {
      expect(nodePhase(created, free), NodePhase.inactive);
    });

    test('a waiting node is inactive once its key resolves', () {
      final (s, top2) = root([
        comp('P', key: a),
        comp('Needy', key: b, requires: [a]),
      ]);
      final (created2, [p, needy2]) = createNodes(s, top2);
      expect(nodePhase(created2, needy2), NodePhase.waiting);
      expect(nodePhase(activate(created2, p), needy2), NodePhase.inactive);
    });

    test(
      'a node whose key vanishes while its release runs stays deactivating',
      () {
        // from: runtime_state_test.dart: withdraws the keys in the transition
        // that starts it
        final (s, top2) = root([
          comp('P', key: a),
          comp('R', key: b, requires: [a]),
        ]);
        final (s1, [p, r]) = initialize(s, top2);
        final released = beginRelease(s1, p);
        expect(nodePhase(released, p), NodePhase.deactivating);
        expect(nodePhase(released, r), NodePhase.active);
        expect(unmet(released, r), [a]);
      },
    );

    test('a canceled activation is not a failure', () {
      // from: observation_test.dart: a canceled activation is not named a
      // failure
      final (begun, _) = beginActivation(created, free);
      final ended = endActivation(
        begun,
        free,
        failure: const None(),
        awaiting: const {},
        failed: true,
      );
      // The scope is initializing, so the node is doomed until the rollback.
      expect(nodePhase(ended, free), NodePhase.activating);
      expect(nodeRecord(ended, free).activationFailure.isNone(), isTrue);
    });

    test('a disposed node has the state disposed', () {
      // from: observation_test.dart: a disposed node has the state disposed
      // and no entry
      final s = removeNode(created, free);
      expect(nodePhase(s, free), NodePhase.disposed);
    });
  });

  group('scopePhase, one row of the table at a time', () {
    // A chain: grand -> parent -> leaf.
    (RuntimeState, ScopeId, ScopeId, ScopeId) chain() {
      final (s, grand) = root([comp('G', key: a)]);
      final (s1, parent) = child(s, grand, [comp('P', key: b)]);
      final (s2, leaf) = child(s1, parent, [comp('L', key: c)]);
      return (s2, grand, parent, leaf);
    }

    test('row 6: a new scope is declared', () {
      final (s, _, _, leaf) = chain();
      expect(scopePhase(s, leaf), ScopePhase.declared);
    });

    test('row 5: the creation of the nodes makes the scope initializing', () {
      // from: runtime_state_test.dart: a scope is declared, initializing, and
      // initialized
      final (s, _, _, leaf) = chain();
      final (created, _) = createNodes(s, leaf);
      expect(scopePhase(created, leaf), ScopePhase.initializing);
    });

    test(
      'row 4: the end of the initialization makes the scope initialized',
      () {
        final (s, _, _, leaf) = chain();
        final (initialized, _) = initialize(s, leaf);
        expect(scopePhase(initialized, leaf), ScopePhase.initialized);
        expect(scopeRecord(initialized, leaf).initializing, isFalse);
      },
    );

    test('row 3: an accepted disposal outranks initialized', () {
      // from: runtime_state_test.dart: an initialize whose members committed
      // completes with success in disposeRequested
      final (s, _, _, leaf) = chain();
      final (initialized, _) = initialize(s, leaf);
      final requested = requestScopeDisposal(initialized, leaf);
      expect(scopePhase(requested, leaf), ScopePhase.disposeRequested);
      expect(scopeRecord(requested, leaf).initialized, isTrue);
    });

    test('row 3: an accepted disposal outranks initializing', () {
      // from: runtime_state_test.dart: a canceled initialize ends in
      // disposeRequested
      final (s, _, _, leaf) = chain();
      final (created, _) = createNodes(s, leaf);
      final requested = requestScopeDisposal(created, leaf);
      expect(scopePhase(requested, leaf), ScopePhase.disposeRequested);
      final finished = finishInitialize(requested, leaf);
      expect(scopePhase(finished, leaf), ScopePhase.disposeRequested);
    });

    test('row 2: disposing outranks disposeRequested', () {
      final (s, _, _, leaf) = chain();
      final requested = requestScopeDisposal(s, leaf);
      final disposing = markDisposing(requested, [leaf]);
      expect(scopePhase(disposing, leaf), ScopePhase.disposing);
      expect(scopeRecord(disposing, leaf).disposeRequested, isTrue);
    });

    test('row 1: disposed outranks disposing', () {
      // from: runtime_state_test.dart: goes through disposeRequested,
      // disposing, and disposed
      final (s, _, _, leaf) = chain();
      final disposed = markDisposed(
        withScope(s, leaf, (r) => r.copyWith(disposing: true)),
        leaf,
      );
      expect(scopePhase(disposed, leaf), ScopePhase.disposed);
      expect(scopeRecord(disposed, leaf).disposing, isFalse);
    });

    for (final (name, change) in <(String, ScopeRecord Function(ScopeRecord))>[
      ('disposeRequested', (r) => r.copyWith(disposeRequested: true)),
      ('disposing', (r) => r.copyWith(disposing: true)),
      ('disposed', (r) => r.copyWith(disposed: true)),
    ]) {
      test('an ancestor that is $name gives disposeRequested', () {
        final (s, grand, _, leaf) = chain();
        final (initialized, _) = initialize(s, leaf);
        final changed = withScope(initialized, grand, change);
        expect(scopePhase(changed, leaf), ScopePhase.disposeRequested);
        expect(disposalRequested(changed, leaf), isTrue);
      });

      test('a middle scope that is $name gives disposeRequested below', () {
        final (s, grand, parent, leaf) = chain();
        final changed = withScope(s, parent, change);
        expect(scopePhase(changed, leaf), ScopePhase.disposeRequested);
        expect(disposalRequested(changed, grand), isFalse);
        expect(scopePhase(changed, grand), ScopePhase.declared);
      });
    }

    test('a scope declared under a requested parent is disposeRequested', () {
      final (s, grand, _, _) = chain();
      final requested = requestScopeDisposal(s, grand);
      final (born, later) = child(requested, grand, [comp('N', key: d)]);
      expect(scopePhase(born, later), ScopePhase.disposeRequested);
    });

    test('the disposal of a child leaves the parent as it was', () {
      // from: core_test.dart: disposing a scope recursively disposes
      // descendants
      final (s, grand, parent, leaf) = chain();
      final requested = requestScopeDisposal(s, leaf);
      expect(disposalRequested(requested, parent), isFalse);
      expect(disposalRequested(requested, grand), isFalse);
      expect(disposalRequested(requested, leaf), isTrue);
    });

    test('a sibling of a disposed scope is not affected', () {
      final (s, _, parent, leaf) = chain();
      final (withSibling, sibling) = child(s, parent, [comp('S', key: d)]);
      final requested = requestScopeDisposal(withSibling, leaf);
      expect(scopePhase(requested, sibling), ScopePhase.declared);
    });
  });
}
