import 'dart:async';

import 'package:fpdart/fpdart.dart';

import 'cause.dart';
import 'failure.dart';
import 'finalizers.dart';

/// A value that exists after its first use, and that the component which made
/// the `Lazy` owns.
///
/// A `Dependency.lazy()` gives a `Lazy`. The steps of the source dependency do
/// not run when the owner activates. They run on the first [force], against the
/// values that the owner read when it activated.
///
/// A failed creation is a failure of the call, and it is not cached, so a later
/// [force] tries again. It never deactivates the owner.
final class Lazy<A> {
  Lazy._(this._create, this._ownerClosed)
    : _cells = IORef.create<_Cells<A>>(_Cells<A>.initial()).run();

  /// A creation: it gives a value and the stack that releases what the steps
  /// own, or the cause of the failed creation. A failed creation has released
  /// its own steps already.
  final Future<Either<Cause<DiFailure>, (A, Finalizers)>> Function() _create;

  final bool Function() _ownerClosed;

  /// The state of the holder. The record is immutable, and the cell holds the
  /// current one.
  final IORef<_Cells<A>> _cells;

  _Cells<A> get _now => _cells.read().run();

  void _become(_Cells<A> next) => _cells.write(next).run();

  /// Whether the value is created now.
  ///
  /// The value is `true` after a successful creation, until the owner releases
  /// it.
  bool get isCreated => _now.lease.isSome();

  /// A task that creates the value on its first run. Concurrent and later runs
  /// give that value.
  ///
  /// The task is lazy: each run reads the holder again. Runs that start while a
  /// creation is in flight share it. A run after the disposal of the owner was
  /// requested, and a run after the release, fail with a
  /// [DisposedLazyFailure], and the run does not create.
  ///
  /// A creation that settles after the release of the owner began releases its
  /// value once, and its caller gets a [DisposedLazyFailure]. The rollback
  /// failures of such a creation go to the release.
  ///
  /// A failed creation gives its cause: the failure of the step, then the
  /// dispose failures of the rollback. The holder does not keep the failure.
  TaskEither<Cause<DiFailure>, A> force() => TaskEither(_force);

  Future<Exit<DiFailure, A>> _force() {
    final state = _now;
    if (state.released || _ownerClosed()) {
      return Future.value(_disposed<A>());
    }
    if (state.acquiring) return state.pending.toNullable()!;
    final lease = state.lease.toNullable();
    if (lease != null) {
      return Future<Exit<DiFailure, A>>.sync(() => Right(lease.$1));
    }
    _become(state.copyWith(acquiring: true));
    final pending = _acquire();
    _become(_now.copyWith(pending: Some(pending)));
    return pending;
  }

  Future<Exit<DiFailure, A>> _acquire() async {
    final created = await _create();
    return created.match(
      (cause) {
        final state = _now;
        _become(
          state.copyWith(
            pending: const None(),
            acquiring: false,
            releaseFailures: state.released
                ? state.releaseFailures + cause.onlyDefects
                : state.releaseFailures,
          ),
        );
        // A creation that was in flight when the owner released reports that to
        // the caller. Its rollback failures go to the release.
        return state.released
            ? _disposed<A>()
            : Left<Cause<DiFailure>, A>(cause);
      },
      (lease) {
        // The holder owns the value until `release`, which awaits this
        // settlement.
        final state = _now;
        _become(state.copyWith(lease: Some(lease), acquiring: false));
        return state.released
            ? _disposed<A>()
            : Right<Cause<DiFailure>, A>(lease.$1);
      },
    );
  }

  /// A task that releases the holder and gives the cause of the dispose
  /// failures. The owner calls it when it releases its values.
  ///
  /// The call is idempotent. It waits for a creation in flight, releases the
  /// value of the creation when one exists, and gives the failures of the
  /// release and of a late rollback.
  Task<Cause<DiFailure>> release() => Task(() async {
    final first = _now;
    if (first.released) return const Empty<DiFailure>();
    _become(first.copyWith(released: true));
    if (first.pending case Some(:final value)) {
      // A creation in flight settles first. A settled creation has a stale
      // future, so the release takes one hop on a fresh future instead.
      await (first.acquiring ? value : Future<void>.sync(() {}));
      _become(_now.copyWith(pending: const None()));
    }
    final state = _now;
    final failures = state.releaseFailures;
    _become(
      state.copyWith(
        releaseFailures: const Empty<DiFailure>(),
        lease: const None(),
      ),
    );
    final own = switch (state.lease) {
      Some(:final value) => await value.$2.release().run(),
      None() => const Empty<DiFailure>(),
    };
    return failures + own;
  });
}

/// Creates a [Lazy] with the creation [create], which gives a value and the
/// stack of its dispose functions. [ownerClosed] tells whether the disposal of
/// the owner was requested. The runtime calls it.
Lazy<A> createLazy<A>(
  Future<Either<Cause<DiFailure>, (A, Finalizers)>> Function() create,
  bool Function() ownerClosed,
) => Lazy<A>._(create, ownerClosed);

Exit<DiFailure, A> _disposed<A>() => Left<Cause<DiFailure>, A>(
  Fail<DiFailure>(const DisposedLazyFailure(), StackTrace.current),
);

/// The state of one [Lazy]. The record is immutable.
final class _Cells<A> {
  const _Cells({
    required this.lease,
    required this.pending,
    required this.acquiring,
    required this.released,
    required this.releaseFailures,
  });

  factory _Cells.initial() => _Cells<A>(
    lease: const None(),
    pending: const None(),
    acquiring: false,
    released: false,
    releaseFailures: const Empty<DiFailure>(),
  );

  /// The created value and the stack that releases it.
  final Option<(A, Finalizers)> lease;

  /// The result that concurrent runs share while [acquiring].
  final Option<Future<Exit<DiFailure, A>>> pending;

  /// Whether a creation runs: it started and did not settle.
  final bool acquiring;

  /// Whether the owner released the holder.
  final bool released;

  /// Rollback failures of a creation that settled after the release began.
  final Cause<DiFailure> releaseFailures;

  _Cells<A> copyWith({
    Option<(A, Finalizers)>? lease,
    Option<Future<Exit<DiFailure, A>>>? pending,
    bool? acquiring,
    bool? released,
    Cause<DiFailure>? releaseFailures,
  }) => _Cells<A>(
    lease: lease ?? this.lease,
    pending: pending ?? this.pending,
    acquiring: acquiring ?? this.acquiring,
    released: released ?? this.released,
    releaseFailures: releaseFailures ?? this.releaseFailures,
  );
}
