import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fp_di_fpdart/src/core/core.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('scopeStateShared', () {
    test('gives the same object at one revision', () {
      final (s, top) = root([comp('A', key: a)]);
      final (init, _) = initialize(s, top);
      final (first, memo) = scopeStateShared(init, top, Snapshots.empty);
      final (second, again) = scopeStateShared(init, top, memo);
      expect(identical(first, second), isTrue);
      expect(identical(memo, again), isTrue, reason: 'the memo is kept');
    });

    test('keeps the object of a node and of a scope that did not change', () {
      final (s, top) = root([comp('A', key: a), comp('B', key: b)]);
      final (s1, low) = child(s, top, [comp('C', key: c)]);
      final (s2, [na, nb]) = initialize(s1, top);
      final (s3, [nc]) = initialize(s2, low);
      final (before, memo) = scopeStateShared(s3, top, Snapshots.empty);
      // The node B releases: A, the node C of the child, and the child keep
      // their objects.
      final s4 = release(s3, nb);
      final (after, _) = scopeStateShared(s4, top, memo);
      expect(identical(after, before), isFalse);
      expect(identical(after.nodeStates[0], before.nodeStates[0]), isTrue);
      expect(identical(after.nodeStates[1], before.nodeStates[1]), isFalse);
      expect(
        identical(after.childStates.single, before.childStates.single),
        isTrue,
      );
      expect(na, isNot(nc));
    });

    test('keeps an equal node state although the revision rose', () {
      final (s, top) = root([comp('A', key: a)]);
      final (s1, low) = child(s, top, [comp('B', key: b)]);
      final (init, _) = initialize(s1, top);
      final (before, memo) = scopeStateShared(init, top, Snapshots.empty);
      // A new child scope raises the revision and changes only the list of the
      // children.
      final (s2, _) = child(init, top, [comp('D', key: d)]);
      final (after, _) = scopeStateShared(s2, top, memo);
      expect(
        identical(after.nodeStates.single, before.nodeStates.single),
        isTrue,
      );
      expect(after.childStates, hasLength(2));
      expect(
        identical(after.childStates.first, before.childStates.first),
        isTrue,
      );
      expect(low, isNot(top));
    });

    test('the state of a node is the object of its scope state', () {
      final (s, top) = root([comp('A', key: a)]);
      final (init, [n]) = initialize(s, top);
      final (node, memo) = nodeStateShared(init, n, Snapshots.empty);
      final (scope, _) = scopeStateShared(init, top, memo);
      expect(identical(scope.nodeStates.single, node), isTrue);
    });

    test('is equal by value to the unshared state', () {
      final (s, top) = root([comp('A', key: a), comp('B', key: b)]);
      final (init, _) = initialize(s, top);
      final (shared, _) = scopeStateShared(init, top, Snapshots.empty);
      expect(shared, scopeState(init, top));
    });
  });

  group('changedSince', () {
    test('pairs the nodes of the changed scopes only', () {
      final (s, top) = root([comp('A', key: a), comp('B', key: b)]);
      final (s1, low) = child(s, top, [comp('C', key: c)]);
      final (s2, [na, nb]) = initialize(s1, top);
      final (s3, [nc]) = initialize(s2, low);
      final (before, memo) = scopeStateShared(s3, top, Snapshots.empty);
      final s4 = release(s3, nb);
      final (after, _) = scopeStateShared(s4, top, memo);
      final pairs = after.changedSince(before);
      expect(pairs, hasLength(1));
      expect(pairs.single.$1!.id, nb);
      expect(pairs.single.$1!.phase, NodePhase.active);
      expect(pairs.single.$2!.phase, NodePhase.inactive);
      expect(after.changedSince(after), isEmpty);
      expect(na, isNot(nc));
    });

    test('pairs the node of a scope that left with none', () {
      final (s, top) = root([comp('A', key: a)]);
      final (s1, low) = child(s, top, [comp('B', key: b)]);
      final (s2, [nb]) = initialize(initialize(s1, top).$1, low);
      final (before, memo) = scopeStateShared(s2, top, Snapshots.empty);
      final gone = markDisposed(release(s2, nb, permanent: true), low);
      final (after, _) = scopeStateShared(gone, top, memo);
      final pairs = after.changedSince(before);
      expect(pairs, hasLength(1));
      expect(pairs.single.$1!.id, nb);
      expect(pairs.single.$2, isNull);
    });
  });

  group('describeScope', () {
    test('lists declared components, in the order of the list', () {
      final (s, top) = root([
        comp('A', key: a),
        comp('B', key: b, requires: [c]),
        effect('E'),
      ]);
      expect(
        describeScope(s, top),
        [
          'scope (not initialized)',
          '  - A (DiKey<int>(a)): declared',
          '  - B (DiKey<int>(b)): declared',
          '  - E: declared',
        ].join('\n'),
      );
    });

    test('the heading has no suffix for an initialized scope', () {
      final (s, top) = root([comp('A', key: a)]);
      final (init, _) = initialize(s, top);
      expect(describeScope(init, top), 'scope\n  - A (DiKey<int>(a)): active');
    });

    test('does not list a removed node', () {
      final (s, top) = root([comp('A', key: a), comp('B', key: b)]);
      final (init, [na, _]) = initialize(s, top);
      final gone = release(init, na, permanent: true);
      expect(describeScope(gone, top), 'scope\n  - B (DiKey<int>(b)): active');
    });

    test('lists a waiting node with its missing keys, in order', () {
      final (s, top) = root([
        comp('B', key: b, requires: [c, a]),
      ]);
      final (init, _) = initialize(s, top);
      expect(
        describeScope(init, top),
        'scope\n  - B (DiKey<int>(b)): waiting; '
        'missing DiKey<int>(c), DiKey<int>(a)',
      );
    });
  });

  group('unavailableKey', () {
    test('names a key that no scope declares', () {
      final (s, top) = root([comp('A', key: a)]);
      final failure = unavailableKey(s, top, b);
      expect(failure.key, b);
      expect(failure.message, 'No node publishes DiKey<int>(b).');
      expect(failure.failedNodeStates, isEmpty);
    });

    test('names a key that a scope declares and did not run', () {
      final (s, top) = root([comp('A', key: a)]);
      final failure = unavailableKey(s, top, a);
      expect(failure.message, contains('is not initialized'));
    });

    test('follows a waiting node to a failed node', () {
      final (s, top) = root([
        comp('A', key: a),
        comp('B', key: b, requires: [a]),
        comp('C', key: c, requires: [b]),
      ]);
      final (created, [na, nb, nc]) = createNodes(s, top);
      final (begun, _) = beginActivation(created, na);
      final failed = endActivation(
        begun,
        na,
        failure: Some(
          Fail<DiFailure>(
            const ActivationFailure('A', 'boom'),
            StackTrace.empty,
          ),
        ),
        awaiting: const {},
        failed: false,
      );
      final failure = unavailableKey(finishInitialize(failed, top), top, c);
      expect(failure.failedNodeStates.map((n) => n.id), [na]);
      expect(failure.message, contains('the node C waits for DiKey<int>(b).'));
      expect(failure.message, contains('The activation of A'));
      expect(failure.message, contains('boom'));
      expect(nb, isNot(nc));
    });
  });
}
