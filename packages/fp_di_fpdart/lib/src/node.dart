import 'package:fpdart/fpdart.dart';

import 'cause.dart';
import 'core/core.dart';
import 'failure.dart';
import 'key.dart';
import 'runtime/runtime.dart';

/// The handle of one component of an initialized scope.
///
/// A node is a component instance in a scope. It is active when it has a
/// value and publishes its key. A node can leave the phase active and return
/// to it: a publisher that it reads is replaced, and the runtime creates the
/// value again.
///
/// No read of a node throws, and no read of a node changes the state of the
/// runtime.
final class ComponentNode<A> {
  ComponentNode._(this._runtime, this._id);

  final Runtime _runtime;
  final NodeId _id;

  /// The state of the node now.
  NodeState get state => nodeState(_runtime.state, _id);

  /// The name of the node in a message.
  String get label => state.label;

  /// The key that the node publishes, or `None` for an effect.
  Option<DiKey<Object?>> get key => state.key;

  /// Whether the node is active now.
  bool get isActive => state.phase == NodePhase.active;

  /// The value of the node, or an [InactiveNodeFailure] when the node is not
  /// active. A node that releases is not active.
  Either<DiFailure, A> get value {
    final s = _runtime.state;
    final phase = nodePhase(s, _id);
    if (phase != NodePhase.active) {
      return Left(InactiveNodeFailure(nodeState(s, _id).missing));
    }
    return Right(nodeRecord(s, _id).value.toNullable() as A);
  }

  /// The required keys that do not resolve for the node.
  List<DiKey<Object?>> get missing => state.missing;

  /// The failure of the last automatic activation of the node.
  ///
  /// The value is `Some` only in the phase [NodePhase.activationFailed].
  Option<Cause<DiFailure>> get activationFailure => state.activationFailure;

  /// The value of the node when the node is active, or after its next commit.
  ///
  /// The task is lazy: each run registers a wait. A failed automatic
  /// activation does not complete it. The task fails with an
  /// [InactiveNodeFailure] when the runtime removes the node.
  TaskEither<DiFailure, A> get whenActive => TaskEither(
    () async => (await _runtime.awaitActive(_id)).map((value) => value as A),
  );

  /// Disposes the node and every node that reads its value.
  ///
  /// The call is idempotent, and a repeated call shares the first result. A
  /// node that read the value of the node waits for another publisher. The
  /// call never fails with a [DisposedScopeFailure]. A call inside a running
  /// lifecycle operation fails with a [ReentrantMutationFailure].
  ///
  /// The result is a `Left` with the dispose failures of the release.
  Future<Exit<DiFailure, Unit>> dispose() => _runtime.disposeNodeCall(_id);

  @override
  bool operator ==(Object other) =>
      other is ComponentNode<Object?> &&
      identical(other._runtime, _runtime) &&
      other._id == _id;

  @override
  int get hashCode => Object.hash(identityHashCode(_runtime), _id.value);

  @override
  String toString() => 'ComponentNode($label: ${state.phase.name})';
}

/// The handle of the node [id] of [runtime].
ComponentNode<A> componentNodeOf<A>(Runtime runtime, NodeId id) =>
    ComponentNode<A>._(runtime, id);
