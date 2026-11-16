// The search for the cause of an unavailable key. The search reads the held
// state of the nodes and changes nothing.
import '../model/exception.dart';
import '../model/key.dart';
import '../model/state.dart';
import 'core_graph.dart';
import 'core_node.dart';
import 'core_resolve.dart';

/// The nodes that the search for the cause of an unavailable key visits, from
/// [first], in the order of the visit.
///
/// A failed node ends its path. A waiting node continues at the nodes of its
/// missing keys: the nearest node of a required key, and each contributing
/// node of a collection key whose contribution does not resolve. The search
/// is depth-first and visits each node one time.
List<CoreNode<S, P, N>> coreCauseSearch<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(CoreNode<S, P, N> first) {
  final visited = <CoreNode<S, P, N>>[];
  final seen = <CoreNode<S, P, N>>{};
  final pending = <CoreNode<S, P, N>>[first];
  while (pending.isNotEmpty) {
    final node = pending.removeLast();
    if (!seen.add(node)) continue;
    visited.add(node);
    final state = node.state;
    if (state.phase != NodePhase.waiting) continue;
    final next = <CoreNode<S, P, N>>[];
    for (final missing in state.missing) {
      if (missing is DiCollectionKey<Object?>) {
        for (final contribution in coreContributionKeysOf(node, missing)) {
          if (node.resolve(contribution) != null) continue;
          if (coreNodeBehind(node, contribution) case final behind?) {
            next.add(behind);
          }
        }
      } else if (coreNodeBehind(node, missing) case final behind?) {
        next.add(behind);
      }
    }
    // The last node of the stack is the next one, so the first node behind
    // this node goes on last.
    pending.addAll(next.reversed);
  }
  return visited;
}

/// The error of a `Scope.get` call for [key] from [scope], when the key has
/// no value (specs/runtime/lifecycle, "The cause of an unavailable key").
///
/// The search starts at the node that `findNode` returns and follows
/// [coreCauseSearch].
///
/// With [dropFailedNodes], the error keeps its message and holds no failed
/// node. Only a deliberate defect of the runtime sets it.
UnavailableKeyException coreUnavailable<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(
  CoreScope<S, P, N> scope,
  DiKey<Object?> key, {
  required bool dropFailedNodes,
}) {
  CoreNode<S, P, N>? first;
  var declaredOnly = false;
  for (CoreScope<S, P, N>? s = scope; s != null; s = s.parent) {
    first = coreNodeOf(s, key);
    if (first != null) break;
    declaredOnly |=
        s.phase == ScopePhase.declared && s.declared.publishes.contains(key);
  }
  if (first == null) {
    return UnavailableKeyException(
      key,
      message: declaredOnly
          ? 'No node publishes $key: a scope declares the key and is not '
                'initialized.'
          : 'No node publishes $key.',
    );
  }

  final failed = [
    for (final node in coreCauseSearch(first))
      if (node.state.phase == NodePhase.activationFailed) node.state,
  ];

  final state = first.state;
  final buffer = StringBuffer('No value is available for $key');
  switch (state.phase) {
    case NodePhase.waiting:
      buffer.write(
        ': the node ${state.label} waits for ${state.missing.join(', ')}.',
      );
    case NodePhase.activationFailed:
      buffer.write('.');
    case final phase:
      buffer.write(': the node ${state.label} is ${coreStateWord(phase)}.');
  }
  if (failed.isNotEmpty) {
    final cause = failed.first;
    buffer.write(' The activation of ${cause.label} failed');
    if (failed.length > 1) {
      buffer.write(', and ${failed.length - 1} more failed');
    }
    buffer.write(': ${cause.activationException!.cause}');
  }
  return UnavailableKeyException(
    key,
    message: buffer.toString(),
    failedNodeStates: dropFailedNodes
        ? const <NodeState>[]
        : List<NodeState>.unmodifiable(failed),
  );
}
