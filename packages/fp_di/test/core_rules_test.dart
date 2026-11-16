// The pure rules of `lib/src/core/` against fake views, with no runtime.
import 'package:fp_di/fp_di.dart';
import 'package:fp_di/src/core/core_graph.dart';
import 'package:fp_di/src/core/core_node.dart';
import 'package:fp_di/src/core/core_plan.dart';
import 'package:fp_di/src/core/core_resolve.dart';
import 'package:fp_di/src/core/core_scope.dart';
import 'package:fp_di/src/core/core_search.dart';
import 'package:test/test.dart';

final _trace = StackTrace.fromString('trace');

final class FakeScope implements CoreScope<FakeScope, FakePublisher, FakeNode> {
  FakeScope(this.declared, {this.parent}) {
    parent?.children.add(this);
    final components = declared.components;
    for (var i = 0; i < components.length; i++) {
      if (components[i].key case final key?) declarationIndexes[key] = i;
    }
  }

  @override
  final FakeScope? parent;
  @override
  final List<FakeScope> children = [];
  @override
  final Module declared;
  @override
  List<DiKeyBase?> get contributionKeys =>
      List<DiKeyBase?>.filled(declared.components.length, null);
  @override
  final Map<DiKeyBase, int> declarationIndexes = {};
  @override
  List<FakeNode> nodes = [];
  @override
  ScopePhase phase = ScopePhase.declared;
  @override
  bool initialized = false;
  @override
  bool initializing = false;
  @override
  bool disposeRequested = false;
  @override
  bool disposing = false;
  @override
  bool disposed = false;
  @override
  bool waitsForHolds = false;
  @override
  int holdCount = 0;

  final Map<DiKeyBase, FakePublisher> bindings = {};

  @override
  FakePublisher? bindingOf(DiKeyBase key) => bindings[key];

  /// Adds a node for the component at [index] and returns it.
  FakeNode addNode(int index, {Set<DiKeyBase> requires = const {}}) {
    final component = declared.components[index];
    final node = FakeNode(this, index, component.label)
      ..declaredRequires = requires
      ..declaredPlainReads = requires
      ..declaredPublishes = {?component.key}
      ..publicKey = component.key;
    nodes = [...nodes, node];
    return node;
  }
}

final class FakePublisher implements CorePublisher<FakeNode> {
  FakePublisher(this.owner);

  @override
  final FakeNode owner;
  @override
  bool available = true;
  @override
  final Set<FakeNode> dependents = {};
}

final class FakeNode implements CoreNode<FakeScope, FakePublisher, FakeNode> {
  FakeNode(this.scope, this.declarationIndex, this.label) : id = _nextId++;

  static int _nextId = 0;

  @override
  final int id;
  @override
  final String label;
  @override
  final FakeScope scope;
  @override
  final int declarationIndex;
  @override
  Set<DiKeyBase> declaredRequires = {};
  @override
  Set<DiKeyBase> declaredPlainReads = {};
  @override
  Set<DiKeyBase> declaredPublishes = {};
  @override
  Set<DiCollectionKey<Object?>> collectionKeys = {};
  @override
  Set<DiCollectionKey<Object?>> optionalCollectionKeys = {};
  @override
  DiKeyBase? publicKey;
  @override
  DiSetKey<Object?>? contributionSet;
  @override
  Map<DiCollectionKey<Object?>, ({DiKeyBase key, int index})> witnesses = {};
  @override
  int commits = 0;
  @override
  Set<FakePublisher> dependencies = {};
  @override
  Set<FakePublisher> publishers = {};
  @override
  Map<DiKeyBase, FakePublisher> committed = {};
  @override
  Map<DiCollectionKey<Object?>, List<DiKeyBase>> committedMembership = {};
  @override
  bool removed = false;
  @override
  bool active = false;
  @override
  bool deactivating = false;
  @override
  bool doomed = false;
  @override
  bool reactivationBlocked = false;
  @override
  bool activationInFlight = false;
  @override
  ActivationException? activationException;

  @override
  NodeState get state => coreNodeState(this);

  @override
  FakePublisher? resolve(DiKeyBase key) =>
      coreResolve(scope, key, excludeOwner: this);

  /// Publishes [key] in the scope of this node, as a commit does.
  FakePublisher publish(DiKeyBase key) {
    final publisher = FakePublisher(this);
    scope.bindings[key] = publisher;
    publishers.add(publisher);
    active = true;
    return publisher;
  }
}

Set<FakeNode> reachOf(FakeNode root) =>
    coreWithdrawalReach<FakeScope, FakePublisher, FakeNode>(root);

List<FakeNode>? pathBetween(FakeNode from, FakeNode target) =>
    corePath<FakeScope, FakePublisher, FakeNode>(from, target, <FakeNode>{});

Module _module(List<DiKey<int>> keys) => Module(
  components: [
    for (final key in keys) Component<int>.value(value: 0, key: key),
  ],
);

void main() {
  final a = DiKey<int>(name: 'a');
  final b = DiKey<int>(name: 'b');
  final c = DiKey<int>(name: 'c');

  group('resolve', () {
    test('the nearest scope shadows the farther one', () {
      final root = FakeScope(_module([a]));
      final child = FakeScope(_module([a]), parent: root);
      final rootNode = root.addNode(0);
      final childNode = child.addNode(0);
      final rootPublisher = rootNode.publish(a);
      final childPublisher = childNode.publish(a);
      expect(coreResolve(child, a), same(childPublisher));
      expect(coreResolve(root, a), same(rootPublisher));
      expect(coreResolve(child, b), isNull);
    });

    test('the farthest flag keeps the walk going to the root', () {
      final root = FakeScope(_module([a]));
      final child = FakeScope(_module([a]), parent: root);
      final rootPublisher = root.addNode(0).publish(a);
      child.addNode(0).publish(a);
      expect(coreResolve(child, a, farthest: true), same(rootPublisher));
    });

    test('a publisher that is not available does not count', () {
      final root = FakeScope(_module([a]));
      final child = FakeScope(_module([a]), parent: root);
      final rootPublisher = root.addNode(0).publish(a);
      child.addNode(0).publish(a).available = false;
      expect(coreResolve(child, a), same(rootPublisher));
    });

    test('excludeOwner skips the publisher of that node', () {
      final root = FakeScope(_module([a]));
      final child = FakeScope(_module([a]), parent: root);
      final rootPublisher = root.addNode(0).publish(a);
      final childNode = child.addNode(0);
      childNode.publish(a);
      expect(coreResolve(child, a, excludeOwner: childNode), rootPublisher);
      // The resolve member of a node excludes its own publisher.
      expect(childNode.resolve(a), same(rootPublisher));
    });
  });

  group('phase', () {
    test('a scope phase follows the flags, and a request comes from above', () {
      final root = FakeScope(_module([a]));
      final child = FakeScope(_module([b]), parent: root);
      expect(coreScopePhase(child), ScopePhase.declared);
      child.initializing = true;
      expect(coreScopePhase(child), ScopePhase.initializing);
      child
        ..initializing = false
        ..initialized = true;
      expect(coreScopePhase(child), ScopePhase.initialized);
      root.disposeRequested = true;
      expect(coreDisposalRequested(child), isTrue);
      expect(coreScopePhase(child), ScopePhase.disposeRequested);
      child.disposing = true;
      expect(coreScopePhase(child), ScopePhase.disposing);
      child.disposed = true;
      expect(coreScopePhase(child), ScopePhase.disposed);
    });

    test('a node phase follows its fields', () {
      final root = FakeScope(_module([a, b]));
      final provider = root.addNode(0);
      final reader = root.addNode(1, requires: {a});
      expect(coreNodePhase(reader), NodePhase.waiting);
      expect(coreUnmet(reader), [a]);
      expect(coreSatisfied(reader), isFalse);
      provider.publish(a);
      expect(coreNodePhase(provider), NodePhase.active);
      expect(coreUnmet(reader), isEmpty);
      expect(coreSatisfied(reader), isTrue);
      expect(coreNodePhase(reader), NodePhase.inactive);
      reader.activationInFlight = true;
      expect(coreNodePhase(reader), NodePhase.activating);
      reader
        ..activationInFlight = false
        ..activationException = ActivationException('boom', _trace);
      expect(coreNodePhase(reader), NodePhase.activationFailed);
      reader.reactivationBlocked = true;
      expect(coreNodePhase(reader), NodePhase.disposeFailed);
      reader.deactivating = true;
      expect(coreNodePhase(reader), NodePhase.deactivating);
      reader.removed = true;
      expect(coreNodePhase(reader), NodePhase.disposed);
    });

    test('the idle phase takes waits as an argument', () {
      final root = FakeScope(_module([a]));
      final node = root.addNode(0);
      expect(coreIdlePhase(node, waits: false), NodePhase.inactive);
      expect(coreIdlePhase(node, waits: true), NodePhase.waiting);
    });

    test('a changed target shows when a key resolves to another publisher', () {
      final root = FakeScope(_module([a, b]));
      final provider = root.addNode(0);
      final reader = root.addNode(1, requires: {a});
      final publisher = provider.publish(a);
      reader.committed = {a: publisher};
      expect(coreTargetChanged(reader), isFalse);
      publisher.available = false;
      expect(coreTargetChanged(reader), isTrue);
    });
  });

  group('the cause of an unavailable key', () {
    // a is failed, b waits for a, and c waits for b.
    late FakeScope root;
    late FakeNode failed;
    setUp(() {
      root = FakeScope(_module([a, b, c]));
      failed = root.addNode(0)
        ..activationException = ActivationException('boom', _trace);
      root
        ..addNode(1, requires: {a})
        ..addNode(2, requires: {b});
    });

    test('the search visits the nodes from the key to the failed node', () {
      final visited = coreCauseSearch(root.nodes[2]);
      expect(visited.map((node) => node.label), [
        root.nodes[2].label,
        root.nodes[1].label,
        failed.label,
      ]);
    });

    test('the error names the failed node and holds its state', () {
      final error = coreUnavailable(root, c, dropFailedNodes: false);
      expect(error.failedNodeStates.map((state) => state.id), [failed.id]);
      expect(error.message, contains('waits for $b'));
      expect(error.message, contains('The activation of ${failed.label}'));
      expect(error.message, contains('boom'));
    });

    test('a defect argument drops the failed nodes and keeps the message', () {
      final kept = coreUnavailable(root, c, dropFailedNodes: false);
      final dropped = coreUnavailable(root, c, dropFailedNodes: true);
      expect(dropped.failedNodeStates, isEmpty);
      expect(dropped.message, kept.message);
    });

    test('a key without a node gives the case in the message', () {
      final missing = DiKey<int>(name: 'missing');
      expect(
        coreUnavailable(root, missing, dropFailedNodes: false).message,
        'No node publishes $missing.',
      );
      final child = FakeScope(_module([missing]), parent: root);
      expect(
        coreUnavailable(child, missing, dropFailedNodes: false).message,
        contains('not initialized'),
      );
    });

    test('a scope can publish a key until its node leaves', () {
      expect(coreCanPublish(root, a), isTrue);
      failed.reactivationBlocked = true;
      expect(coreCanPublish(root, a), isFalse);
      expect(coreCanPublish(root, DiKey<int>(name: 'other')), isFalse);
    });
  });

  group('plans', () {
    test('the activation plan counts the prerequisites of each member', () {
      final root = FakeScope(_module([a, b, c]));
      final nodes = [
        root.addNode(0),
        root.addNode(1, requires: {a}),
        root.addNode(2, requires: {a, b}),
      ];
      final plan = coreActivationPlan(nodes);
      expect(plan.waitingFor, [0, 1, 2]);
      expect(plan.dependents, [
        [1, 2],
        [2],
        <int>[],
      ]);
    });

    test('the withdrawal reach holds the active readers of the root', () {
      final root = FakeScope(_module([a, b, c]));
      final first = root.addNode(0);
      final second = root.addNode(1, requires: {a});
      final third = root.addNode(2, requires: {b});
      first.publish(a).dependents.add(second);
      second.publish(b).dependents.add(third);
      third.active = true;
      expect(reachOf(first), {first, second, third});
      third.active = false;
      expect(reachOf(first), {first, second});
    });

    test('a path of reads ends at the target, or is null', () {
      final root = FakeScope(_module([a, b]));
      final first = root.addNode(0);
      final second = root.addNode(1, requires: {a});
      second.dependencies = {first.publish(a)};
      expect(pathBetween(second, first), [second, first]);
      expect(pathBetween(first, second), isNull);
    });

    test('the dependents come by descending id, and a release waits', () {
      final root = FakeScope(_module([a, b, c]));
      final first = root.addNode(0);
      final second = root.addNode(1, requires: {a});
      final third = root.addNode(2, requires: {a});
      final publisher = first.publish(a)..dependents.addAll([second, third]);
      second.active = true;
      expect(coreDependentsOf(first), [third, second]);
      expect(coreReleaseReady(first), isFalse);
      second.active = false;
      expect(coreReleaseReady(first), isTrue);
      expect(publisher.dependents, hasLength(2));
    });

    test('a read of an owner shows in the dependencies and in the shape', () {
      final root = FakeScope(_module([a, b]));
      final first = root.addNode(0);
      final second = root.addNode(1, requires: {a});
      expect(
        coreReadsOwner(
          second,
          const <FakePublisher>[],
          (owner) => owner == first,
        ),
        false,
      );
      final publisher = first.publish(a);
      expect(
        coreReadsOwner(
          second,
          const <FakePublisher>[],
          (owner) => owner == first,
        ),
        true,
      );
      first.scope.bindings.clear();
      expect(
        coreReadsOwner(second, [publisher], (owner) => owner == first),
        isTrue,
      );
    });
  });

  group('pre-checks', () {
    test('the first duplicate key comes with the labels of its members', () {
      final module = Module(
        components: [
          Component<int>.value(value: 0, key: a, debugLabel: 'one'),
          Component<int>.value(value: 1, key: b),
          Component<int>.value(value: 2, key: a, debugLabel: 'two'),
        ],
      );
      final duplicate = coreDuplicate(module)!;
      expect(duplicate.key, a);
      expect(duplicate.labels, ['one', 'two']);
      expect(coreDuplicate(_module([a, b])), isNull);
    });

    test('a required key that no scope declares is unresolvable', () {
      final root = FakeScope(_module([a]));
      final module = Module(
        components: [
          Component<int>(
            key: b,
            dependency: Dependency.require<int>(key: a).map((v) => v),
          ),
          Component<int>(
            key: c,
            dependency: Dependency.require<int>(key: DiKey<int>(name: 'x')),
          ),
        ],
      );
      final child = FakeScope(module, parent: root);
      final unresolvable = coreUnresolvable(child, module);
      expect(unresolvable, hasLength(1));
      expect(unresolvable.single.key.toString(), contains('x'));
    });
  });

  group('the tree of scopes', () {
    test('the subtree lists parents first, and the path names a child', () {
      final root = FakeScope(_module([a]));
      final first = FakeScope(_module([b]), parent: root);
      final second = FakeScope(_module([c]), parent: root);
      final nested = FakeScope(_module([a]), parent: second);
      expect(coreSubtree(root), [root, first, second, nested]);
      expect(corePathOf(root), 'scope');
      expect(corePathOf(nested), 'child scope 2.1');
      first.holdCount = 1;
      nested.holdCount = 2;
      expect(coreSubtreeHolds(root), 3);
      expect(coreSubtreeHolds(second), 2);
    });
  });
}
