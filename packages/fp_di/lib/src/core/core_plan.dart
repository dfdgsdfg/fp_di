// The plans and the walks over the read graph of nodes: which node waits for
// which, which nodes a withdrawal reaches, and in which order a release
// visits the dependents. Each rule reads the views of `core_graph.dart` and
// returns a value.
import '../model/key.dart';
import 'core_graph.dart';
import 'core_node.dart';

/// The prerequisites among the member [nodes] of one `initialize` call.
///
/// A member waits for the members that publish a key it reads. Element `i`
/// of [waitingFor] is the number of prerequisites of member `i`, and element
/// `i` of [dependents] lists the members that wait for member `i`, in the
/// order of their indexes.
({List<int> waitingFor, List<List<int>> dependents}) coreActivationPlan<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(List<CoreNode<S, P, N>> nodes) {
  final count = nodes.length;
  // `initialize` has rejected duplicate keys, so each key has one member.
  final publisherOf = <DiKeyBase, int>{
    for (var i = 0; i < count; i++)
      for (final key in nodes[i].declaredPublishes) key: i,
  };
  final waitingFor = List<int>.filled(count, 0);
  final dependents = List<List<int>>.generate(count, (_) => <int>[]);
  for (var i = 0; i < count; i++) {
    final prerequisites = <int>{
      for (final key in corePlainReads(nodes[i]))
        if (publisherOf[key] case final publisher? when publisher != i)
          publisher,
    };
    waitingFor[i] = prerequisites.length;
    for (final prerequisite in prerequisites) {
      dependents[prerequisite].add(i);
    }
  }
  return (waitingFor: waitingFor, dependents: dependents);
}

/// [root] and every active node that reads, directly or through other
/// nodes, a value that the withdrawal of [root] withdraws.
Set<N> coreWithdrawalReach<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(N root) {
  final reach = <N>{root};
  final queue = <N>[root];
  while (queue.isNotEmpty) {
    final next = queue.removeLast();
    for (final publisher in next.publishers) {
      for (final dependent in publisher.dependents) {
        if (dependent.active && reach.add(dependent)) queue.add(dependent);
      }
    }
  }
  return reach;
}

/// Whether an activation of [node] read, or will read by its shape, a value
/// whose publisher has an owner that [isOwner] accepts. [dependencies] are
/// the publishers that the activation read until now.
bool coreReadsOwner<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(
  CoreNode<S, P, N> node,
  Iterable<P> dependencies,
  bool Function(N owner) isOwner,
) {
  for (final publisher in dependencies) {
    if (isOwner(publisher.owner)) return true;
  }
  for (final key in corePlainReads(node)) {
    final publisher = node.resolve(key);
    if (publisher != null && isOwner(publisher.owner)) return true;
  }
  return false;
}

/// The nodes that read a value of [node], by descending id.
List<N> coreDependentsOf<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(CoreNode<S, P, N> node) {
  final dependents = <N>{};
  for (final publisher in node.publishers) {
    dependents.addAll(publisher.dependents);
  }
  return dependents.toList()
    ..sort((left, right) => right.id.compareTo(left.id));
}

/// Whether every other node that read a value of [node] finished its release:
/// it is neither active nor releasing.
bool coreReleaseReady<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(CoreNode<S, P, N> node) {
  for (final publisher in node.publishers) {
    for (final dependent in publisher.dependents) {
      if (!identical(dependent, node) &&
          (dependent.active || dependent.deactivating)) {
        return false;
      }
    }
  }
  return true;
}

/// The path of committed reads from [from] to [target], both included, or
/// null when [from] does not reach [target]. [seen] holds the nodes that the
/// walk visited.
List<N>? corePath<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(N from, N target, Set<N> seen) {
  if (!seen.add(from)) return null;
  if (identical(from, target)) return [from];
  for (final dependency in from.dependencies) {
    final suffix = corePath<S, P, N>(dependency.owner, target, seen);
    if (suffix != null) return [from, ...suffix];
  }
  return null;
}
