// The failure value that travels inside the runtime. Not exported: the public
// API still throws the exceptions of `model/exception.dart` and
// `model/error.dart`, and the projections below make each one at the point
// where a failure leaves the runtime.
//
// The shape follows the `Cause` of `fp_di_fpdart`, without a dependency on
// it. A `RuntimeCause` is a tree. Its leaves hold the objects that the
// runtime threw before, so a caller that compares a thrown object with a
// recorded object still sees the same object.
import '../model/exception.dart';

/// Why an operation of the runtime did not end in success, as a tree.
///
/// [RuntimeEmpty] is the identity of [then] and of [both]. A [RuntimeThen]
/// joins two causes that happened one after the other. A [RuntimeBoth] joins
/// two causes of work that ran at the same time. The traversal order of the
/// leaves is the order of the tree, so a caller MUST build a [RuntimeBoth] in
/// declaration order, never in completion order.
sealed class RuntimeCause {
  const RuntimeCause();

  /// The cause of an operation that succeeded.
  static const RuntimeCause empty = RuntimeEmpty();

  /// Whether the cause has no leaf.
  bool get isEmpty;

  /// A cause that happened after this cause. An empty operand gives the
  /// other operand.
  RuntimeCause then(RuntimeCause next) {
    if (this is RuntimeEmpty) return next;
    if (next is RuntimeEmpty) return this;
    return RuntimeThen(this, next);
  }

  /// A cause that happened at the same time as this cause, with this cause
  /// first in the traversal. An empty operand gives the other operand.
  RuntimeCause both(RuntimeCause other) {
    if (this is RuntimeEmpty) return other;
    if (other is RuntimeEmpty) return this;
    return RuntimeBoth(this, other);
  }

  /// [causes] joined with [both], in the order of [causes].
  static RuntimeCause all(Iterable<RuntimeCause> causes) {
    var joined = empty;
    for (final cause in causes) {
      joined = joined.both(cause);
    }
    return joined;
  }

  /// [causes] joined with [then], in the order of [causes].
  static RuntimeCause sequence(Iterable<RuntimeCause> causes) {
    var joined = empty;
    for (final cause in causes) {
      joined = joined.then(cause);
    }
    return joined;
  }

  /// The failures of dispose functions as a sequence of [RuntimeDie] leaves.
  static RuntimeCause dying(Iterable<DisposeFailure> failures) =>
      sequence([for (final failure in failures) RuntimeDie(failure)]);

  /// The leaves, [RuntimeFail], [RuntimeInterrupt], and [RuntimeDie], from
  /// left to right.
  ///
  /// The walk keeps its own stack, so a long chain of causes costs no
  /// recursion.
  Iterable<RuntimeCause> get leaves sync* {
    final pending = <RuntimeCause>[this];
    while (pending.isNotEmpty) {
      switch (pending.removeLast()) {
        case RuntimeEmpty():
          break;
        case RuntimeThen(:final first, :final second):
          pending
            ..add(second)
            ..add(first);
        case RuntimeBoth(:final left, :final right):
          pending
            ..add(right)
            ..add(left);
        case final RuntimeCause leaf:
          yield leaf;
      }
    }
  }

  /// The failures of the [RuntimeDie] leaves, from left to right.
  List<DisposeFailure> get disposeFailures => [
    for (final leaf in leaves)
      if (leaf is RuntimeDie) leaf.failure,
  ];

  /// The first [RuntimeFail] leaf, or null.
  RuntimeFail? get firstFail {
    for (final leaf in leaves) {
      if (leaf is RuntimeFail) return leaf;
    }
    return null;
  }

  /// The error that `initialize` or an activation throws for this cause.
  ///
  /// The cause MUST have a [RuntimeFail] or [RuntimeInterrupt] leaf. The
  /// first such leaf, the head, gives the error and its stack trace. The
  /// rollback failures of every other such leaf follow, in the order of the
  /// tree, and then the failure of every [RuntimeDie] leaf. The error keeps
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
  /// A [RuntimeFail] leaf wins: its error is thrown with its stack trace, as
  /// a release that threw. Otherwise the [RuntimeDie] leaves give one
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
  /// - The head is a [RuntimeInterrupt]. A cancellation is not a failure, so
  ///   only the dispose failures count: those of the interrupt, then those
  ///   of the [RuntimeDie] leaves. They give one [DisposeException].
  /// - The head is a [RuntimeFail] whose error is a [DiException], and no
  ///   rollback failure follows. The error itself.
  /// - The head is any other [RuntimeFail]. An [ActivationException] of the
  ///   error, with the rollback failures that follow.
  /// - There is no head. The [RuntimeDie] leaves give one [DisposeException].
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

/// The error and the stack trace of a [RuntimeFail] or a [RuntimeInterrupt],
/// or null for any other leaf.
({Object error, StackTrace stackTrace})? _headOf(RuntimeCause leaf) =>
    switch (leaf) {
      RuntimeFail(:final error, :final stackTrace) => (
        error: error,
        stackTrace: stackTrace,
      ),
      RuntimeInterrupt(:final exception, :final stackTrace) => (
        error: exception,
        stackTrace: stackTrace,
      ),
      _ => null,
    };

/// The cause of an operation that succeeded. It has no leaf.
final class RuntimeEmpty extends RuntimeCause {
  /// Creates the empty cause. Use [RuntimeCause.empty].
  const RuntimeEmpty();

  @override
  bool get isEmpty => true;
}

/// A failure that an operation threw, with the object that it threw.
final class RuntimeFail extends RuntimeCause {
  /// Creates the failure of [error], which was thrown with [stackTrace].
  const RuntimeFail(this.error, this.stackTrace);

  /// The object that was thrown.
  final Object error;

  /// The stack trace of [error].
  final StackTrace stackTrace;

  @override
  bool get isEmpty => false;
}

/// An activation that the disposal of its owner canceled.
final class RuntimeInterrupt extends RuntimeCause {
  /// Creates the cancellation [exception], which was thrown with
  /// [stackTrace].
  const RuntimeInterrupt(this.exception, this.stackTrace);

  /// The exception that carries the rollback failures of the activation.
  final ActivationCanceledException exception;

  /// The stack trace of [exception].
  final StackTrace stackTrace;

  @override
  bool get isEmpty => false;
}

/// A dispose function that failed.
final class RuntimeDie extends RuntimeCause {
  /// Creates the leaf of a dispose [failure].
  const RuntimeDie(this.failure);

  /// The dispose function that failed.
  final DisposeFailure failure;

  @override
  bool get isEmpty => false;
}

/// Two causes that happened one after the other.
final class RuntimeThen extends RuntimeCause {
  /// Joins [first] and [second]. Use [RuntimeCause.then], which skips an
  /// empty operand.
  const RuntimeThen(this.first, this.second);

  /// The cause that happened first.
  final RuntimeCause first;

  /// The cause that happened after [first].
  final RuntimeCause second;

  @override
  bool get isEmpty => leaves.isEmpty;
}

/// Two causes of work that ran at the same time.
final class RuntimeBoth extends RuntimeCause {
  /// Joins [left] and [right]. Use [RuntimeCause.both], which skips an empty
  /// operand.
  const RuntimeBoth(this.left, this.right);

  /// The cause of the work that came first in declaration order.
  final RuntimeCause left;

  /// The cause of the work that came after [left] in declaration order.
  final RuntimeCause right;

  @override
  bool get isEmpty => leaves.isEmpty;
}
