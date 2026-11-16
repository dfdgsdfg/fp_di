// The resolution of a key through the scopes of a graph.
import '../model/key.dart';
import 'core_graph.dart';

/// The nearest available publisher of [key] from [scope] to the root.
///
/// A publisher that [excludeOwner] owns does not count. With [farthest], the
/// walk goes on to the root and returns the farthest publisher. Only a
/// deliberate defect of the runtime sets it.
P? coreResolve<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(
  CoreScope<S, P, N> scope,
  DiKeyBase key, {
  N? excludeOwner,
  bool farthest = false,
}) {
  P? found;
  for (
    CoreScope<S, P, N>? current = scope;
    current != null;
    current = current.parent
  ) {
    final publisher = current.bindingOf(key);
    if (publisher != null &&
        publisher.available &&
        (excludeOwner == null || !identical(publisher.owner, excludeOwner))) {
      if (!farthest) return publisher;
      found = publisher;
    }
  }
  return found;
}

/// The node of [scope] whose component publishes [key] or has the internal
/// contribution key [key], or null.
N? coreDeclaredNode<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(CoreScope<S, P, N> scope, DiKeyBase key) {
  if (scope.nodes.isEmpty) return null;
  final index = scope.declarationIndexes[key];
  if (index == null) return null;
  final node = scope.nodes[index];
  return node.removed ? null : node;
}

/// The node of [scope] whose component publishes [key], or null when [scope]
/// has no such node or the node is disposed.
///
/// A scope has nodes from its `initialize` call, also before that call
/// completes.
N? coreNodeOf<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(CoreScope<S, P, N> scope, DiKeyBase key) {
  if (!scope.declared.publishes.contains(key)) return null;
  return coreDeclaredNode(scope, key);
}

/// The nearest node, other than [reader], that publishes [key] or has the
/// contribution key [key], from the scope of [reader] to the root.
N? coreNodeBehind<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(CoreNode<S, P, N> reader, DiKeyBase key) {
  for (
    CoreScope<S, P, N>? scope = reader.scope;
    scope != null;
    scope = scope.parent
  ) {
    final node = coreDeclaredNode(scope, key);
    if (node != null && !identical(node, reader)) return node;
  }
  return null;
}

/// The nearest node that publishes [key], from [scope] to the root, or null.
N? coreNearestNode<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(CoreScope<S, P, N> scope, DiKeyBase key) {
  for (CoreScope<S, P, N>? s = scope; s != null; s = s.parent) {
    final node = coreNodeOf(s, key);
    if (node != null) return node;
  }
  return null;
}
