import 'core/phases.dart';
import 'core/snapshots.dart' show NodeState;
import 'key.dart';

/// One dispose function that failed.
///
/// A [Die] holds the failure as its defect. A dispose function that throws is
/// a defect, not a typed failure.
final class DisposeFailure {
  /// Creates the record of a failed dispose function of the component that
  /// has the label [owner].
  const DisposeFailure(this.owner, this.error);

  /// The label of the component whose dispose function failed.
  final String owner;

  /// The error that the dispose function threw.
  final Object error;

  @override
  bool operator ==(Object other) =>
      other is DisposeFailure && other.owner == owner && other.error == error;

  @override
  int get hashCode => Object.hash(DisposeFailure, owner, error);

  @override
  String toString() => '$owner: $error';
}

/// The reason why a scope operation failed with a typed error.
///
/// No operation of this library throws. A scope operation returns an `Exit`.
/// Each typed error is a value of one final subclass, inside a `Fail` of a
/// `Cause`.
sealed class DiFailure {
  /// Creates a failure.
  const DiFailure();

  /// A short text that describes the failure.
  String get message;

  @override
  String toString() => '$runtimeType: $message';
}

/// A required key has no publisher.
///
/// Neither the scope nor an ancestor of the scope publishes the key.
final class UndeclaredKeyFailure extends DiFailure {
  /// Creates the failure for [key], which the component with the label
  /// [owner] requires.
  const UndeclaredKeyFailure(this.key, {required this.owner});

  /// The key that no component publishes.
  final DiKey<Object?> key;

  /// The label of the component that requires [key].
  final String owner;

  @override
  String get message => '$owner requires $key, which no component publishes';
}

/// Two components of one scope publish the same key.
final class DuplicateKeyFailure extends DiFailure {
  /// Creates the failure for [key], which the components with the [labels]
  /// publish.
  const DuplicateKeyFailure(this.key, this.labels);

  /// The key that more than one component publishes.
  final DiKey<Object?> key;

  /// The labels of the components that publish [key].
  final List<String> labels;

  @override
  String get message => '$key is provided by ${labels.join(', ')}';
}

/// An override has no single component to replace.
///
/// Either no component publishes the key of the override, or the override is
/// an effect component, which publishes no key.
final class UnmatchedOverrideFailure extends DiFailure {
  /// Creates the failure for [key], which the override with the label
  /// [owner] names.
  const UnmatchedOverrideFailure(this.key, {required this.owner});

  /// The key that the override names.
  final DiKey<Object?> key;

  /// The label of the override.
  final String owner;

  @override
  String get message =>
      '$owner overrides $key, which no single component publishes';
}

/// A read inside an activation would close a cycle of committed reads.
///
/// Components that require each other wait and are no failure, so only a read
/// of a node that already reads the reader can raise this failure.
final class DependencyCycleFailure extends DiFailure {
  /// Creates the failure for the cycle that [path] lists.
  const DependencyCycleFailure(this.path);

  /// The keys of the cycle, in reading order.
  ///
  /// The first key and the last key are equal. A component that reads its own
  /// key gives a path of two equal keys.
  final List<DiKey<Object?>> path;

  @override
  String get message => 'cycle ${path.join(' -> ')}';
}

/// A create step of a component threw an error or returned a `Left`.
///
/// A throw is a typed failure here, like the `attempt` of ZIO. The `Cause`
/// that holds the failure also holds the dispose failures of the rollback.
final class ActivationFailure extends DiFailure {
  /// Creates the failure of the component with the label [owner].
  const ActivationFailure(this.owner, this.error);

  /// The label of the component that failed to activate.
  final String owner;

  /// The error that a step threw, or the `Left` value that a step returned.
  ///
  /// The value is not wrapped.
  final Object? error;

  @override
  String get message => '$owner failed to activate: $error';
}

/// The scope and its ancestors have no value for the key.
///
/// The failure of `get` explains why. No node publishes the key, or a node
/// waits, or an activation failed. [failedNodeStates] lists the failed nodes
/// behind the key.
final class UnavailableKeyFailure extends DiFailure {
  /// Creates the failure for [key].
  ///
  /// [message] replaces the default message. [failedNodeStates] lists the
  /// failed nodes behind [key].
  const UnavailableKeyFailure(
    this.key, {
    String? message,
    this.failedNodeStates = const [],
  }) : _message = message;

  /// The key that no active scope publishes.
  final DiKeyBase key;

  /// The state of each failed node behind [key], each one time.
  ///
  /// Each value has the phase `activationFailed`. Its `activationFailure`
  /// holds the cause of the failure, and its `label` and `key` name the node.
  /// The list starts with the node of [key] when that node failed. Otherwise
  /// the node of [key] waits, and the list holds the failed nodes that a
  /// depth-first search finds behind its `missing` keys.
  ///
  /// The list is empty when no activation failure explains the lookup: no
  /// node publishes the key, or the nodes behind it only wait.
  final List<NodeState> failedNodeStates;

  final String? _message;

  @override
  String get message => _message ?? '$key is not available';
}

/// An operation is not valid in the current phase of the scope.
///
/// Examples are a second `run`, or a `get` before a `run` succeeded.
final class ScopePhaseFailure extends DiFailure {
  /// Creates the failure of [operation] in [phase].
  const ScopePhaseFailure({required this.operation, required this.phase});

  /// The name of the operation, such as `run` or `get`.
  final String operation;

  /// The phase of the scope when the operation started.
  final ScopePhase phase;

  @override
  String get message => '$operation is not valid in the phase ${phase.name}';
}

/// The scope is disposing or disposed, so the operation is not valid.
final class DisposedScopeFailure extends DiFailure {
  /// Creates the failure of [operation].
  const DisposedScopeFailure(this.operation);

  /// The name of the operation, such as `get` or `child`.
  final String operation;

  @override
  String get message => '$operation is not valid in a disposed scope';
}

/// A lifecycle operation started inside a lifecycle operation of the same
/// runtime.
///
/// A dispose function, a listener, or a callback of a running operation
/// cannot start `run`, `dispose`, or the `dispose` of a node.
final class ReentrantMutationFailure extends DiFailure {
  /// Creates the failure of [operation].
  const ReentrantMutationFailure(this.operation);

  /// The name of the operation that the runtime rejected.
  final String operation;

  @override
  String get message => '$operation started inside a running operation';
}

/// A node has no value now, so a read of its value failed.
final class InactiveNodeFailure extends DiFailure {
  /// Creates the failure of a node that waits for [missing].
  const InactiveNodeFailure([this.missing = const []]);

  /// The keys that the node waits for. A collection key stands for a
  /// contribution that does not resolve.
  final List<DiKeyBase> missing;

  @override
  String get message => missing.isEmpty
      ? 'the node is not active'
      : 'the node is not active, and waits for ${missing.join(', ')}';
}

/// A listener threw an error.
///
/// The runtime removes the listener and reports this failure to `errors`.
final class ListenerFailure extends DiFailure {
  /// Creates the failure for the [error] that a listener threw.
  const ListenerFailure(this.error);

  /// The error that the listener threw.
  final Object error;

  @override
  String get message => 'a listener threw: $error';
}

/// Optional reads feed back into each other, so the nodes never settle.
final class UnsettledFailure extends DiFailure {
  /// Creates the failure for the nodes with the [labels], after [passes]
  /// passes of the reconciliation.
  const UnsettledFailure(this.labels, this.passes);

  /// The labels of the nodes that still changed in the last pass.
  final List<String> labels;

  /// The number of passes that the reconciliation made.
  final int passes;

  @override
  String get message =>
      'the nodes ${labels.join(', ')} do not settle after $passes passes';
}

/// `Lazy.force` ran after the disposal of the owner was requested, or after the
/// owner released the value.
///
/// A creation that was in flight when the owner released settles with this
/// failure, too. The runtime releases the value of such a creation once.
final class DisposedLazyFailure extends DiFailure {
  /// Creates the failure.
  const DisposedLazyFailure();

  @override
  String get message =>
      'Lazy.force ran after its owning component was disposed';
}
