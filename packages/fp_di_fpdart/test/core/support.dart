import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fp_di_fpdart/src/core/core.dart';
import 'package:fp_di_fpdart/src/finalizers.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

const a = DiKey<int>(name: 'a');
const b = DiKey<int>(name: 'b');
const c = DiKey<int>(name: 'c');
const d = DiKey<int>(name: 'd');

/// A component that publishes [key] and reads [requires] and [optional].
Component<int> comp(
  String label, {
  DiKey<int>? key,
  List<DiKey<int>> requires = const [],
  List<DiKey<int>> optional = const [],
}) {
  var reads = Dependency<int>.of(0);
  for (final read in requires) {
    reads = reads.map2<int, int>(
      Dependency.require<int>(key: read),
      (x, _) => x,
    );
  }
  for (final read in optional) {
    reads = reads.map2<Option<int>, int>(
      Dependency.option<int>(key: read),
      (x, _) => x,
    );
  }
  return Component<int>(key: key, debugLabel: label, dependency: reads);
}

/// An effect component that reads [requires].
Component<int> effect(String label, {List<DiKey<int>> requires = const []}) {
  var reads = Dependency<int>.of(0);
  for (final read in requires) {
    reads = reads.map2<int, int>(
      Dependency.require<int>(key: read),
      (x, _) => x,
    );
  }
  return Component<int>.effect(debugLabel: label, dependency: reads);
}

/// A root scope with [components].
(RuntimeState, ScopeId) root(List<Component<Object?>> components) =>
    declareScope(RuntimeState.empty, const None(), components);

/// A child scope of [parent] with [components].
(RuntimeState, ScopeId) child(
  RuntimeState s,
  ScopeId parent,
  List<Component<Object?>> components,
) => declareScope(s, Some(parent), components);

/// Runs one activation of [n] to its commit, with the dependencies [deps].
RuntimeState activate(
  RuntimeState s,
  NodeId n, {
  Object? value = 0,
  Set<NodeId> deps = const {},
}) {
  final (begun, _) = beginActivation(s, n);
  return commit(begun, n, value, target(begun, n), deps, Finalizers.empty);
}

/// Creates the nodes of [id] and activates each node whose keys resolve, in
/// declaration order. The dependencies of a node are the publishers that it
/// resolved. The scope is initialized.
(RuntimeState, List<NodeId>) initialize(RuntimeState s, ScopeId id) {
  final (created, ids) = createNodes(s, id);
  var next = created;
  for (final n in ids) {
    if (!satisfied(next, n)) continue;
    next = activate(next, n, deps: depsOf(next, n));
  }
  return (finishInitialize(next, id), ids);
}

/// The nodes that [n] resolves now.
Set<NodeId> depsOf(RuntimeState s, NodeId n) => {
  for (final publisher in target(s, n).values)
    if (publisher.toNullable() case final found?) found.node,
};

/// Releases the node [n]: begin, and end with success.
RuntimeState release(
  RuntimeState s,
  NodeId n, {
  bool permanent = false,
  bool ownFailed = false,
}) => endRelease(
  beginRelease(s, n),
  n,
  ownFailed: ownFailed,
  permanent: permanent,
);

/// The `Fail` that [cause] holds, as a list of the typed errors.
List<DiFailure> failuresOf(Cause<DiFailure> cause) => cause.failures;

/// Expects that [action] raises [UnsupportedError].
void expectUnmodifiable(void Function() action) =>
    expect(action, throwsUnsupportedError);
