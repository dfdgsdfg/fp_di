// The failure value that travels inside the runtime. Not exported: the public
// API still throws the exceptions of `model/exception.dart` and
// `model/error.dart`, and the projections below make each one at the point
// where a failure leaves the runtime.
//
// The shape follows the `Cause` of `fp_di_fpdart`, without a dependency on
// it. A `CoreCause` is a tree. Its leaves hold the objects that the
// runtime threw before, so a caller that compares a thrown object with a
// recorded object still sees the same object.
import '../model/exception.dart';

/// Why an operation of the runtime did not end in success, as a tree.
///
/// [CoreEmpty] is the identity of [then] and of [both]. A [CoreThen]
/// joins two causes that happened one after the other. A [CoreBoth] joins
/// two causes of work that ran at the same time. The traversal order of the
/// leaves is the order of the tree, so a caller MUST build a [CoreBoth] in
/// declaration order, never in completion order.
sealed class CoreCause {
  const CoreCause();

  /// The cause of an operation that succeeded.
  static const CoreCause empty = CoreEmpty();

  /// Whether the cause has no leaf.
  bool get isEmpty;

  /// A cause that happened after this cause. An empty operand gives the
  /// other operand.
  CoreCause then(CoreCause next) {
    if (this is CoreEmpty) return next;
    if (next is CoreEmpty) return this;
    return CoreThen(this, next);
  }

  /// A cause that happened at the same time as this cause, with this cause
  /// first in the traversal. An empty operand gives the other operand.
  CoreCause both(CoreCause other) {
    if (this is CoreEmpty) return other;
    if (other is CoreEmpty) return this;
    return CoreBoth(this, other);
  }

  /// [causes] joined with [both], in the order of [causes].
  static CoreCause all(Iterable<CoreCause> causes) {
    var joined = empty;
    for (final cause in causes) {
      joined = joined.both(cause);
    }
    return joined;
  }

  /// [causes] joined with [then], in the order of [causes].
  static CoreCause sequence(Iterable<CoreCause> causes) {
    var joined = empty;
    for (final cause in causes) {
      joined = joined.then(cause);
    }
    return joined;
  }

  /// The failures of dispose functions as a sequence of [CoreDie] leaves.
  static CoreCause dying(Iterable<DisposeFailure> failures) =>
      sequence([for (final failure in failures) CoreDie(failure)]);

  /// The leaves, [CoreFail], [CoreInterrupt], and [CoreDie], from
  /// left to right.
  ///
  /// The walk keeps its own stack, so a long chain of causes costs no
  /// recursion.
  Iterable<CoreCause> get leaves sync* {
    final pending = <CoreCause>[this];
    while (pending.isNotEmpty) {
      switch (pending.removeLast()) {
        case CoreEmpty():
          break;
        case CoreThen(:final first, :final second):
          pending
            ..add(second)
            ..add(first);
        case CoreBoth(:final left, :final right):
          pending
            ..add(right)
            ..add(left);
        case final CoreCause leaf:
          yield leaf;
      }
    }
  }

  /// The failures of the [CoreDie] leaves, from left to right.
  List<DisposeFailure> get disposeFailures => [
    for (final leaf in leaves)
      if (leaf is CoreDie) leaf.failure,
  ];

  /// The first [CoreFail] leaf, or null.
  CoreFail? get firstFail {
    for (final leaf in leaves) {
      if (leaf is CoreFail) return leaf;
    }
    return null;
  }

  /// The error that `initialize` or an activation throws for this cause.
  ///
  /// The cause MUST have a [CoreFail] or [CoreInterrupt] leaf. The
  /// first such leaf, the head, gives the error and its stack trace. The
  /// rollback failures of every other such leaf follow, in the order of the
  /// tree, and then the failure of every [CoreDie] leaf. The error keeps
  /// its kind, as [withDisposeFailures] describes.
  ///
  /// With [dropOthers], the rollback failures of the other leaves stay out.
  /// Only the defect `DropLater` sets it.
  ({Object error, StackTrace stackTrace}) activationError({
    bool dropOthers = false,
  }) {
    final heads = [for (final leaf in leaves) ?_headOf(leaf)];
    if (heads.isEmpty) {
      throw StateError('The cause has no failure to throw.');
    }
    final head = heads.first;
    final extra = <DisposeFailure>[
      if (!dropOthers)
        for (final other in heads.skip(1)) ...disposeFailuresOf(other.error),
      ...disposeFailures,
    ];
    return (
      error: withDisposeFailures(head.error, head.stackTrace, extra),
      stackTrace: head.stackTrace,
    );
  }

  /// The error that a disposal throws for this cause, or null for success.
  ///
  /// A [CoreFail] leaf wins: its error is thrown with its stack trace, as
  /// a release that threw. Otherwise the [CoreDie] leaves give one
  /// [DisposeException].
  ({Object error, StackTrace stackTrace})? disposeError() {
    final fail = firstFail;
    if (fail != null) return (error: fail.error, stackTrace: fail.stackTrace);
    final failures = disposeFailures;
    if (failures.isEmpty) return null;
    return (error: DisposeException(failures), stackTrace: StackTrace.current);
  }

  /// Throws the [disposeError] of this cause, if it has one.
  void throwDisposeError() {
    if (disposeError() case (:final error, :final stackTrace)) {
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// What `Scope.errors` receives for this cause, or null for nothing.
  ///
  /// - The head is a [CoreInterrupt]. A cancellation is not a failure, so
  ///   only the dispose failures count: those of the interrupt, then those
  ///   of the [CoreDie] leaves. They give one [DisposeException].
  /// - The head is a [CoreFail] whose error is a [DiException], and no
  ///   rollback failure follows. The error itself.
  /// - The head is any other [CoreFail]. An [ActivationException] of the
  ///   error, with the rollback failures that follow.
  /// - There is no head. The [CoreDie] leaves give one [DisposeException].
  DiException? reportedError() {
    final heads = [for (final leaf in leaves) ?_headOf(leaf)];
    if (heads.isEmpty) {
      final failures = disposeFailures;
      return failures.isEmpty ? null : DisposeException(failures);
    }
    final head = heads.first;
    final extra = <DisposeFailure>[
      for (final other in heads.skip(1)) ...disposeFailuresOf(other.error),
      ...disposeFailures,
    ];
    if (head.error is ActivationCanceledException) {
      final failures = <DisposeFailure>[
        ...disposeFailuresOf(head.error),
        ...extra,
      ];
      return failures.isEmpty ? null : DisposeException(failures);
    }
    if (head.error is DiException && extra.isEmpty) {
      return head.error as DiException;
    }
    return switch (withDisposeFailures(head.error, head.stackTrace, extra)) {
      final DiException error => error,
      final Object error => ActivationException(error, head.stackTrace, extra),
    };
  }

  /// The rollback failures that [error] carries.
  static List<DisposeFailure> disposeFailuresOf(Object error) =>
      switch (error) {
        ActivationException(:final rollbackFailures) => rollbackFailures,
        ActivationCanceledException(:final rollbackFailures) =>
          rollbackFailures,
        _ => const <DisposeFailure>[],
      };

  /// [error] with [extra] rollback failures attached, keeping its kind.
  static Object withDisposeFailures(
    Object error,
    StackTrace stackTrace,
    List<DisposeFailure> extra,
  ) {
    if (extra.isEmpty) return error;
    return switch (error) {
      ActivationException() => ActivationException(
        error.cause,
        error.stackTrace,
        <DisposeFailure>[...error.rollbackFailures, ...extra],
      ),
      ActivationCanceledException() => ActivationCanceledException(
        cause: error.cause,
        stackTrace: error.stackTrace,
        rollbackFailures: <DisposeFailure>[...error.rollbackFailures, ...extra],
      ),
      _ => ActivationException(error, stackTrace, extra),
    };
  }
}

/// The error and the stack trace of a [CoreFail] or a [CoreInterrupt],
/// or null for any other leaf.
({Object error, StackTrace stackTrace})? _headOf(CoreCause leaf) =>
    switch (leaf) {
      CoreFail(:final error, :final stackTrace) => (
        error: error,
        stackTrace: stackTrace,
      ),
      CoreInterrupt(:final exception, :final stackTrace) => (
        error: exception,
        stackTrace: stackTrace,
      ),
      _ => null,
    };

/// The cause of an operation that succeeded. It has no leaf.
final class CoreEmpty extends CoreCause {
  /// Creates the empty cause. Use [CoreCause.empty].
  const CoreEmpty();

  @override
  bool get isEmpty => true;
}

/// A failure that an operation threw, with the object that it threw.
final class CoreFail extends CoreCause {
  /// Creates the failure of [error], which was thrown with [stackTrace].
  const CoreFail(this.error, this.stackTrace);

  /// The object that was thrown.
  final Object error;

  /// The stack trace of [error].
  final StackTrace stackTrace;

  @override
  bool get isEmpty => false;
}

/// An activation that the disposal of its owner canceled.
final class CoreInterrupt extends CoreCause {
  /// Creates the cancellation [exception], which was thrown with
  /// [stackTrace].
  const CoreInterrupt(this.exception, this.stackTrace);

  /// The exception that carries the rollback failures of the activation.
  final ActivationCanceledException exception;

  /// The stack trace of [exception].
  final StackTrace stackTrace;

  @override
  bool get isEmpty => false;
}

/// A dispose function that failed.
final class CoreDie extends CoreCause {
  /// Creates the leaf of a dispose [failure].
  const CoreDie(this.failure);

  /// The dispose function that failed.
  final DisposeFailure failure;

  @override
  bool get isEmpty => false;
}

/// Two causes that happened one after the other.
final class CoreThen extends CoreCause {
  /// Joins [first] and [second]. Use [CoreCause.then], which skips an
  /// empty operand.
  const CoreThen(this.first, this.second);

  /// The cause that happened first.
  final CoreCause first;

  /// The cause that happened after [first].
  final CoreCause second;

  @override
  bool get isEmpty => leaves.isEmpty;
}

/// Two causes of work that ran at the same time.
final class CoreBoth extends CoreCause {
  /// Joins [left] and [right]. Use [CoreCause.both], which skips an empty
  /// operand.
  const CoreBoth(this.left, this.right);

  /// The cause of the work that came first in declaration order.
  final CoreCause left;

  /// The cause of the work that came after [left] in declaration order.
  final CoreCause right;

  @override
  bool get isEmpty => leaves.isEmpty;
}
