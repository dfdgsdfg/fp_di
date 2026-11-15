import 'key.dart';
import 'scope.dart';

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

/// The components of one scope read each other in a cycle.
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

/// The scope and its ancestors do not publish the key.
final class UnavailableKeyFailure extends DiFailure {
  /// Creates the failure for [key].
  const UnavailableKeyFailure(this.key);

  /// The key that no active scope publishes.
  final DiKey<Object?> key;

  @override
  String get message => '$key is not available';
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

/// A child scope ran while its parent was not active.
final class InactiveAncestorFailure extends DiFailure {
  /// Creates the failure for a parent in [phase].
  const InactiveAncestorFailure(this.phase);

  /// The phase of the parent scope.
  final ScopePhase phase;

  @override
  String get message => 'the parent scope is ${phase.name}, not active';
}
