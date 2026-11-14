import 'package:fp_di/fp_di.dart';
import 'package:fpdart/fpdart.dart';

/// A failure of an fp_di operation as a value: the error that fp_di threw,
/// with its stack trace.
///
/// The error stays the original one, so nothing about it is lost: an
/// `ActivationException` keeps its `cause` and `rollbackFailures`, and a
/// `DisposeException` keeps its `disposeFailures`. The getter
/// [disposeFailures] reads them for either kind.
final class DiFailure {
  /// Creates a failure of [error] with its [stackTrace].
  const DiFailure(this.error, this.stackTrace);

  /// The error that fp_di threw.
  final Object error;

  /// The stack trace of [error].
  final StackTrace stackTrace;

  /// The error that caused an activation to fail or to be canceled, or
  /// [error] itself.
  Object get cause => switch (error) {
    ActivationException(:final cause) => cause,
    ActivationCanceledException(:final cause?) => cause,
    _ => error,
  };

  /// The dispose functions that failed during a rollback or a disposal.
  List<DisposeFailure> get disposeFailures => switch (error) {
    ActivationException(:final rollbackFailures) => rollbackFailures,
    ActivationCanceledException(:final rollbackFailures) => rollbackFailures,
    DisposeException(:final disposeFailures) => disposeFailures,
    _ => const [],
  };

  /// Whether the operation was canceled by the disposal of its owner.
  bool get isCanceled => error is ActivationCanceledException;

  @override
  String toString() => 'DiFailure($error)';
}

/// Why a bracketed use of a scope failed. See `Scope.use`.
sealed class ScopeFailure<E> {
  const ScopeFailure();
}

/// `initialize` failed; the use did not run, and the scope was disposed.
final class InitializeFailed<E> extends ScopeFailure<E> {
  /// Creates the failure of `initialize` that [failure] describes.
  const InitializeFailed(this.failure);

  /// The failure that `initialize` reported.
  final DiFailure failure;

  @override
  String toString() => 'InitializeFailed(${failure.error})';
}

/// The use returned a `Left`; the scope was disposed.
final class UseFailed<E> extends ScopeFailure<E> {
  /// Creates the failure of the use with the `Left` value [error].
  const UseFailed(this.error);

  /// The `Left` value that the use returned.
  final E error;

  @override
  String toString() => 'UseFailed($error)';
}

/// `dispose` failed after the use. [useError] keeps the use's own `Left`,
/// if it had one, so neither failure hides the other.
final class DisposeFailed<E> extends ScopeFailure<E> {
  /// Creates the failure of `dispose` that [failure] describes. [useError]
  /// holds the `Left` value of the use.
  const DisposeFailed(this.failure, this.useError);

  /// The failure that `dispose` reported.
  final DiFailure failure;

  /// The `Left` value of the use, if the use returned one.
  final Option<E> useError;

  @override
  String toString() => 'DisposeFailed(${failure.error}, use: $useError)';
}

/// Thrown inside a `Dependency` step when a `TaskEither` returned a `Left`
/// that the host treats as a setup failure. See `mapTaskEither`.
///
/// The activation then fails like any other: its completed steps are
/// disposed in reverse order, and `initialize` reports an
/// `ActivationException` whose `cause` is this exception.
final class DependencyLeft<E> implements Exception {
  /// Creates the exception for the `Left` value [left].
  const DependencyLeft(this.left);

  /// The `Left` value of the step.
  final E left;

  @override
  String toString() => 'DependencyLeft($left)';
}
