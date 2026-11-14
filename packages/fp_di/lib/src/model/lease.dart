import 'dart:async';

import 'cancellation.dart';
import 'context.dart';
import 'exception.dart';
import 'key.dart';

part 'dependency.dart';

/// The dispose function of one lease.
typedef DisposeFunction = FutureOr<void> Function();

/// A value paired with the function that disposes it. Internal to the runtime.
final class Lease<A> {
  /// Creates a lease of [value] that [dispose] releases.
  const Lease({required this.value, required this.dispose});

  /// The value of the lease.
  final A value;

  /// The function that releases [value].
  final DisposeFunction dispose;
}

/// Runs [create] and pairs its value with [dispose]. Only the runtime calls
/// it. Without [dispose], the lease disposes nothing.
Future<Lease<A>> createLease<A>(
  FutureOr<A> Function() create,
  FutureOr<void> Function(A value)? dispose,
) async {
  final value = await create();
  return Lease<A>(
    value: value,
    dispose: dispose == null ? _releaseNothing : () => dispose(value),
  );
}

/// A value created on first use and owned by the component that made it.
///
/// Created by [Dependency.lazy]. A failed acquisition is
/// reported to the caller and not cached, so a later [force] retries; it
/// never deactivates the owner.
///
/// {@category Dependency}
final class Lazy<A> {
  Lazy._(this._create);

  final Future<Lease<A>> Function() _create;
  Lease<A>? _lease;

  /// The result that concurrent callers of [force] share while [_acquiring].
  /// After the acquisition settles it is stale, and no call reads it again:
  /// a call waits on a future of the zone that created it, and that zone can
  /// be dead by then.
  Future<A>? _pending;

  /// Whether an acquisition runs: it started and has not settled yet.
  bool _acquiring = false;
  bool _released = false;

  /// Rollback failures of a creation that settled after the release began.
  final List<DisposeFailure> _releaseFailures = <DisposeFailure>[];

  /// Whether the value is currently created.
  bool get isCreated => _lease != null;

  /// Creates the value on the first call; concurrent and later calls share that
  /// result.
  ///
  /// Throws [DisposedLazyException] after the owner is disposed, including for
  /// an acquisition that was still in flight at that moment.
  Future<A> force() {
    if (_released) return Future<A>.error(const DisposedLazyException());
    if (_acquiring) return _pending!;
    final lease = _lease;
    if (lease != null) return Future<A>.sync(() => lease.value);
    _acquiring = true;
    return _pending = _acquire();
  }

  Future<A> _acquire() async {
    final Lease<A> lease;
    try {
      lease = await _create();
    } on Object catch (error) {
      _pending = null;
      _acquiring = false;
      // A creation in flight when the owner was released reports that to
      // the caller; its rollback failures go to the release instead.
      if (_released) {
        if (error is ActivationException) {
          _releaseFailures.addAll(error.rollbackFailures);
        } else if (error is ActivationCanceledException) {
          _releaseFailures.addAll(error.rollbackFailures);
        }
        throw const DisposedLazyException();
      }
      rethrow;
    }
    // Ownership stays here until [_release], which awaits this settlement.
    _lease = lease;
    _acquiring = false;
    if (_released) throw const DisposedLazyException();
    return lease.value;
  }

  Future<void> _release() async {
    if (_released) return;
    _released = true;
    final pending = _pending;
    if (pending != null) {
      try {
        // An acquisition in flight settles first. A settled one has a stale
        // future, so the release takes one hop on a fresh future instead.
        await (_acquiring ? pending : Future<void>.sync(() {}));
      } on Object {
        // Reported to the caller of force; release below covers any lease.
      }
      _pending = null;
    }
    final disposeFailures = <DisposeFailure>[..._releaseFailures];
    _releaseFailures.clear();
    final lease = _lease;
    _lease = null;
    if (lease != null) {
      try {
        await lease.dispose();
      } on DisposeException catch (failure) {
        disposeFailures.addAll(failure.disposeFailures);
      } on Object catch (error, stackTrace) {
        disposeFailures.add(DisposeFailure('Lazy', error, stackTrace));
      }
    }
    // The owner's teardown aggregates these with its other releases.
    if (disposeFailures.isNotEmpty) throw DisposeException(disposeFailures);
  }
}

void _releaseNothing() {}

Future<List<DisposeFailure>> _releaseAll(
  String owner,
  Iterable<DisposeFunction> releases,
) async {
  final disposeFailures = <DisposeFailure>[];
  for (final release in releases) {
    try {
      await release();
    } on DisposeException catch (failure) {
      disposeFailures.addAll(failure.disposeFailures);
    } on Object catch (error, stackTrace) {
      disposeFailures.add(DisposeFailure(owner, error, stackTrace));
    }
  }
  return disposeFailures;
}
