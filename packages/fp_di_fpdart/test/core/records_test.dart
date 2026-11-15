import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fp_di_fpdart/src/core/core.dart';
import 'package:fp_di_fpdart/src/finalizers.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('PublisherRef', () {
    test('equals by node and commit', () {
      expect(PublisherRef(NodeId(1), 2), PublisherRef(NodeId(1), 2));
      expect(
        PublisherRef(NodeId(1), 2).hashCode,
        PublisherRef(NodeId(1), 2).hashCode,
      );
      expect(PublisherRef(NodeId(1), 2), isNot(PublisherRef(NodeId(1), 3)));
      expect(PublisherRef(NodeId(1), 2), isNot(PublisherRef(NodeId(2), 2)));
    });
  });

  group('records are immutable', () {
    test('a scope record holds unmodifiable collections', () {
      final (s, id) = root([comp('A', key: a)]);
      final scope = scopeRecord(s, id);
      expectUnmodifiable(() => scope.components.add(comp('B', key: b)));
      expectUnmodifiable(() => scope.children.add(ScopeId(9)));
      expectUnmodifiable(() => scope.nodes.add(NodeId(9)));
      expectUnmodifiable(() => scope.bindings[a] = PublisherRef(NodeId(0), 1));
    });

    test('a scope record copies the lists that it receives', () {
      final components = [comp('A', key: a)];
      final scope = ScopeRecord(id: ScopeId(0), components: components);
      components.add(comp('B', key: b));
      expect(scope.components, hasLength(1));
    });

    test('a node record holds unmodifiable collections', () {
      final (s, id) = root([comp('A', key: a)]);
      final (created, [n]) = createNodes(s, id);
      final node = nodeRecord(created, n);
      expectUnmodifiable(() => node.committed[a] = const None());
      expectUnmodifiable(() => node.dependencies.add(NodeId(9)));
      expectUnmodifiable(() => node.awaiting.add(NodeId(9)));
    });

    test('a state holds unmodifiable collections', () {
      final (s, _) = root([comp('A', key: a)]);
      expectUnmodifiable(() => s.scopes.clear());
      expectUnmodifiable(() => s.nodes.clear());
      expectUnmodifiable(() => s.withdrawals.add(Withdrawal(NodeId(0), {})));
      expectUnmodifiable(
        () => Withdrawal(NodeId(0), {NodeId(0)}).reach.add(NodeId(1)),
      );
    });

    test('a transition leaves the old state as it was', () {
      final (s, id) = root([comp('A', key: a)]);
      final (created, _) = createNodes(s, id);
      expect(s.nodes, isEmpty);
      expect(scopeRecord(s, id).initializing, isFalse);
      expect(created.nodes, hasLength(1));
      expect(s.nextNodeId, 0);
    });
  });

  group('copyWith', () {
    test('keeps the fields that it does not name', () {
      final node = NodeRecord(id: NodeId(3), scope: ScopeId(1), index: 2);
      final copy = node.copyWith(active: true);
      expect(copy.active, isTrue);
      expect((copy.id, copy.scope, copy.index), (NodeId(3), ScopeId(1), 2));
      expect(copy.available, isTrue);
      expect(copy.commits, 0);
    });

    test('an Option field resets to None', () {
      final node = NodeRecord(
        id: NodeId(0),
        scope: ScopeId(0),
        index: 0,
        inFlight: const Some(4),
        value: const Some(1),
        activationFailure: const Some(Empty<DiFailure>()),
      );
      final reset = node.copyWith(
        inFlight: const None(),
        value: const None(),
        activationFailure: const None(),
      );
      expect(reset.inFlight.isNone(), isTrue);
      expect(reset.value.isNone(), isTrue);
      expect(reset.activationFailure.isNone(), isTrue);
      expect(node.copyWith(active: true).inFlight, const Some(4));
    });

    test('a record keeps the finalizers that it receives', () {
      final node = NodeRecord(
        id: NodeId(0),
        scope: ScopeId(0),
        index: 0,
        finalizers: Finalizers.empty.push('A', () {}),
      );
      expect(node.finalizers.isEmpty, isFalse);
      expect(
        node.copyWith(finalizers: Finalizers.empty).finalizers.isEmpty,
        isTrue,
      );
    });
  });
}
