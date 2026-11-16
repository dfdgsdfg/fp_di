// The rules that read one scope or the tree of scopes. Each rule reads the
// views of `core_graph.dart` and changes nothing.
import '../model/key.dart';
import '../model/module.dart';
import '../model/state.dart';
import 'core_graph.dart';
import 'core_node.dart';
import 'core_resolve.dart';

/// Whether the disposal of [scope] or of an ancestor was requested.
bool coreDisposalRequested<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(CoreScope<S, P, N> scope) {
  for (
    CoreScope<S, P, N>? current = scope;
    current != null;
    current = current.parent
  ) {
    if (current.disposeRequested || current.disposing || current.disposed) {
      return true;
    }
  }
  return false;
}

/// The phase that the fields of [scope] give.
ScopePhase coreScopePhase<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(CoreScope<S, P, N> scope) {
  if (scope.disposed) return ScopePhase.disposed;
  if (scope.disposing) return ScopePhase.disposing;
  if (coreDisposalRequested(scope)) return ScopePhase.disposeRequested;
  if (scope.initialized) return ScopePhase.initialized;
  if (scope.initializing) return ScopePhase.initializing;
  return ScopePhase.declared;
}

/// [scope] and its descendants, parents first.
List<S> coreSubtree<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(S scope) {
  final subtree = <S>[];
  void collect(S current) {
    subtree.add(current);
    current.children.forEach(collect);
  }

  collect(scope);
  return subtree;
}

/// The number of open holds of [scope] and of its descendants.
int coreSubtreeHolds<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(S scope) {
  var count = scope.holdCount;
  for (final child in scope.children) {
    count += coreSubtreeHolds<S, P, N>(child);
  }
  return count;
}

/// [scope] as `describe` of its root names it.
String corePathOf<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(S scope) {
  final indexes = <int>[];
  for (var current = scope; current.parent != null; current = current.parent!) {
    indexes.add(current.parent!.children.toList().indexOf(current) + 1);
  }
  if (indexes.isEmpty) return 'scope';
  return 'child scope ${indexes.reversed.join('.')}';
}

/// The first key that more than one member of [module] publishes, with the
/// labels of those members, or null.
({DiKeyBase key, List<String> labels})? coreDuplicate(Module module) {
  final publishers = <DiKeyBase, List<String>>{};
  for (final member in module.components) {
    final key = member.key;
    if (key != null) {
      publishers.putIfAbsent(key, () => <String>[]).add(member.label);
    }
  }
  for (final MapEntry(:key, value: members) in publishers.entries) {
    if (members.length > 1) return (key: key, labels: members);
  }
  return null;
}

/// The required keys of [module] that no other member and no member declared
/// by an ancestor of [scope] publishes, in declaration order.
///
/// The declarations are fixed, so such a member could never activate. An
/// ancestor counts whether or not it is initialized, so a child may still
/// initialize before its parent.
List<({String label, DiKeyBase key})> coreUnresolvable<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(CoreScope<S, P, N> scope, Module module) {
  if (module.requires.isEmpty) return const [];
  final declared = <DiKeyBase>{};
  for (var s = scope.parent; s != null; s = s.parent) {
    declared.addAll(s.declared.publishes);
  }
  final result = <({String label, DiKeyBase key})>[];
  for (final member in module.components) {
    for (final key in member.requires) {
      if (declared.contains(key)) continue;
      if (!publishedByOtherMember(module, member, key)) {
        result.add((label: member.label, key: key));
      }
    }
  }
  return result;
}

/// Whether a scope from [scope] to the root can still publish [key].
///
/// A scope can when it declares [key], its disposal is not requested, and it
/// has no nodes yet, runs `initialize`, or has a node of [key] that is not
/// disposed and not in [NodePhase.disposeFailed].
bool coreCanPublish<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(CoreScope<S, P, N> scope, DiKeyBase key) {
  for (CoreScope<S, P, N>? s = scope; s != null; s = s.parent) {
    if (coreDisposalRequested(s) || !s.declared.publishes.contains(key)) {
      continue;
    }
    if (s.initializing || s.nodes.isEmpty) return true;
    final CoreNode<S, P, N>? node = coreNodeOf(s, key);
    if (node != null && coreNodePhase(node) != NodePhase.disposeFailed) {
      return true;
    }
  }
  return false;
}
