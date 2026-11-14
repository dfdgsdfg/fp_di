import 'key.dart';
import 'state.dart';

/// A failure while the program runs, which a caller may catch and handle.
///
/// Following Dart, a `DiException` is an [Exception]. `Scope.errors`
/// reports the exceptions that no caller receives.
///
/// {@category Exceptions}
sealed class DiException implements Exception {
  const DiException(this.message);

  /// The description of the failure.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// A key has no value.
///
/// `Scope.get` throws it with the cause: its [message] states whether a
/// node publishes [key] and what that node waits for, and [failedNodeStates]
/// holds the activation failures behind the key. A read inside an
/// activation throws it with the key only.
///
/// {@category Exceptions}
final class UnavailableKeyException extends DiException {
  /// Creates the exception for [key]. [message] replaces the default message,
  /// and [failedNodeStates] lists the failed nodes behind [key].
  const UnavailableKeyException(
    this.key, {
    String? message,
    this.failedNodeStates = const [],
  }) : super(message ?? 'No active publisher is available for $key.');

  /// The key that has no value.
  final DiKeyBase key;

  /// The state of each failed node behind [key], each one time.
  ///
  /// Each value has the phase `activationFailed`. Its `activationException`
  /// holds the cause and the stack trace of the failure, and its `label`
  /// and `key` name the node. The list starts with the node of [key] when
  /// that node failed. Otherwise the node of [key] waits, and the list
  /// holds the failed nodes that a depth-first search finds behind its
  /// `missing` keys, also behind the contributions of a collection key.
  ///
  /// Empty when no activation failure explains the lookup: no node
  /// publishes the key, or the nodes behind it only wait.
  final List<NodeState> failedNodeStates;
}

/// A single dispose function that failed.
///
/// {@category Exceptions}
final class DisposeFailure {
  /// Creates the record of a failed dispose function.
  const DisposeFailure(this.owner, this.error, this.stackTrace);

  /// The label of the node whose dispose function failed, or `acquire` or
  /// `Lazy` for a dispose function that a step or a `Lazy` registered.
  final String owner;

  /// The error that the dispose function threw.
  final Object error;

  /// The stack trace of [error].
  final StackTrace stackTrace;

  @override
  String toString() => '$owner: $error';
}

/// The activation of a node failed. The runtime rolled back the steps that
/// completed, and [rollbackFailures] lists the dispose functions that failed.
///
/// {@category Exceptions}
final class ActivationException extends DiException {
  /// Creates the exception of an activation that threw [cause].
  ActivationException(
    this.cause,
    this.stackTrace, [
    Iterable<DisposeFailure> rollbackFailures = const <DisposeFailure>[],
  ]) : rollbackFailures = List.unmodifiable(rollbackFailures),
       super('Component activation failed: $cause');

  /// The error that the activation threw.
  final Object cause;

  /// The stack trace of [cause].
  final StackTrace stackTrace;

  /// The dispose functions that failed during the rollback.
  final List<DisposeFailure> rollbackFailures;
}

/// An activation stopped because the disposal of its owner was requested.
///
/// It is not an activation failure: nothing was published, the completed
/// steps were disposed in reverse order, and the runtime does not suppress a
/// later activation. [cause] holds an error that the activation threw after
/// the cancellation, if any. [rollbackFailures] lists the dispose functions
/// that failed during the rollback; report them even when the cancellation
/// itself is expected.
///
/// {@category Exceptions}
final class ActivationCanceledException extends DiException {
  /// Creates the exception of a canceled activation.
  ActivationCanceledException({
    this.cause,
    this.stackTrace,
    Iterable<DisposeFailure> rollbackFailures = const <DisposeFailure>[],
  }) : rollbackFailures = List.unmodifiable(rollbackFailures),
       super(
         cause == null
             ? 'The activation was canceled because its owner is being '
                   'disposed.'
             : 'The activation was canceled because its owner is being '
                   'disposed. It then failed: $cause',
       );

  /// The error that the activation threw after the cancellation, or null.
  final Object? cause;

  /// The stack trace of [cause], or null without a cause.
  final StackTrace? stackTrace;

  /// The dispose functions that failed during the rollback.
  final List<DisposeFailure> rollbackFailures;
}

/// One or more dispose functions failed.
///
/// The runtime always attempts the remaining callbacks before reporting this
/// aggregate.
///
/// {@category Exceptions}
final class DisposeException extends DiException {
  /// Creates the exception that aggregates [disposeFailures].
  DisposeException(Iterable<DisposeFailure> disposeFailures)
    : disposeFailures = List.unmodifiable(disposeFailures),
      super(
        'One or more dispose functions failed (${disposeFailures.length}).',
      );

  /// The dispose functions that failed.
  final List<DisposeFailure> disposeFailures;
}

/// A node currently has no active value.
///
/// [missing] lists the required keys that do not resolve. It is empty when
/// the node is inactive for another reason, such as a failed
/// reactivation or a disposed node.
///
/// {@category Exceptions}
final class InactiveNodeException extends DiException {
  /// Creates the exception for a node without a value. [missing] lists the
  /// required keys that do not resolve.
  InactiveNodeException([Iterable<DiKeyBase> missing = const []])
    : missing = List.unmodifiable(missing),
      super(
        missing.isEmpty
            ? 'The node is inactive: it is disposed, or its last '
                  'activation failed.'
            : 'The node is inactive while it waits for '
                  '${missing.join(', ')}.',
      );

  /// The required keys that do not resolve.
  final List<DiKeyBase> missing;
}

/// A `Lazy` was read after the component owning it was disposed.
///
/// {@category Exceptions}
final class DisposedLazyException extends DiException {
  /// Creates the exception of a `Lazy` that its owner disposed.
  const DisposedLazyException()
    : super('Lazy.force was called after its owning component was disposed.');
}

/// A listener threw and was detached from the runtime.
///
/// {@category Exceptions}
final class DiListenerException extends DiException {
  /// Creates the exception of a listener that threw [cause].
  DiListenerException(this.cause, this.stackTrace)
    : super('A DI lifecycle listener failed: $cause');

  /// The error that the listener threw.
  final Object cause;

  /// The stack trace of [cause].
  final StackTrace stackTrace;
}
