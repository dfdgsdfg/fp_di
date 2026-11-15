import 'dart:async';

import 'package:fpdart/fpdart.dart';

/// Whether the activation that runs a `Dependency` is canceled.
///
/// The runtime cancels the token of an activation when the disposal of its
/// owner is requested, when a withdrawal of a value that the activation reads
/// is requested, and when an active activation starts to deactivate. A step
/// that fails cancels the token of its region before its dispose functions run.
/// The token changes from not canceled to canceled at most once.
/// [isCanceled] changes at that moment. The tasks of [whenCanceled] complete
/// later, like any listener of a future, and the runtime does not wait for
/// them.
///
/// Read the token with `Dependency.cancellation()`. A cooperative step stops
/// its work when the token is canceled. The runtime checks the token before
/// each step anyway, so a step that ignores it only delays its own settlement.
/// A canceled activation never commits. Its cause holds an `Interrupt`.
///
/// To call a cancelable function outside the runtime, for example in a test,
/// pass [CancellationToken.none] or the token of a [CancellationController].
abstract interface class CancellationToken {
  /// A token that is never canceled.
  static final CancellationToken none = _NeverCanceled();

  /// Whether the activation is canceled.
  bool get isCanceled;

  /// A task that completes once when the activation is canceled.
  ///
  /// The task is lazy: each run waits for the cancellation. It never fails, so
  /// it can be an abort trigger of a request, such as the `abortTrigger` of
  /// `package:http`. A task of a token that is canceled completes at once.
  Task<Unit> get whenCanceled;
}

/// A [CancellationToken] that its owner cancels, for code that calls a
/// cancelable function itself, such as a test.
///
/// The runtime cancels the tokens of activations on its own. A controller is
/// for the other side, like a `StreamController` for a stream.
final class CancellationController {
  /// Creates a controller with a token that is not canceled.
  CancellationController();

  final CancellationSource _source = CancellationSource();

  /// The token to pass to the cancelable function.
  CancellationToken get token => _source;

  /// Whether [cancel] was called.
  bool get isCanceled => _source.isCanceled;

  /// Cancels [token]. Safe to call more than once.
  void cancel() => _source.cancel(CancelReason.owner);
}

final class _NeverCanceled implements CancellationToken {
  static final Future<Unit> _never = Completer<Unit>().future;

  @override
  bool get isCanceled => false;

  @override
  Task<Unit> get whenCanceled => Task(() => _never);
}

/// Why the runtime canceled a token. The first reason stays.
enum CancelReason {
  /// The disposal of the owner was requested.
  owner,

  /// The withdrawal of a publisher that the activation reads was requested.
  withdrawal,

  /// The active activation started to deactivate.
  deactivation,

  /// A step of the region failed, and its rollback follows.
  failure,
}

/// The side of a [CancellationToken] that cancels it. The runtime uses it.
///
/// The cells are `IORef` values: the reason, and the completers of the tasks
/// that wait for the cancellation, one for each zone that asked. A completer
/// completes by a microtask of the zone that created it, so a waiter of
/// another zone cannot share it. That zone can be dead when the cancellation
/// comes.
final class CancellationSource implements CancellationToken {
  /// Creates a token for a root region.
  CancellationSource()
    : _reason = IORef.create<Option<CancelReason>>(const None()).run(),
      _waiters = IORef.create<Map<Zone, Completer<Unit>>>(const {}).run();

  /// Creates a token for a child region: canceled when [parent] is, or on its
  /// own.
  CancellationSource.child(CancellationToken parent)
    : _reason = IORef.create<Option<CancelReason>>(const None()).run(),
      _waiters = IORef.create<Map<Zone, Completer<Unit>>>(const {}).run() {
    if (parent.isCanceled) {
      cancel(CancelReason.owner);
    } else {
      unawaited(
        parent.whenCanceled.run().then((_) => cancel(CancelReason.owner)),
      );
    }
  }

  final IORef<Option<CancelReason>> _reason;
  final IORef<Map<Zone, Completer<Unit>>> _waiters;

  /// The reason of the first cancellation, or `None`.
  Option<CancelReason> get reason => _reason.read().run();

  @override
  bool get isCanceled => reason.isSome();

  @override
  Task<Unit> get whenCanceled => Task(() {
    if (isCanceled) return Future<Unit>.sync(() => unit);
    final waiting = _waiters.read().run();
    final completer = waiting[Zone.current] ?? Completer<Unit>();
    _waiters.write({...waiting, Zone.current: completer}).run();
    return completer.future;
  });

  /// Cancels the token for [why]. Safe to call more than once. The first
  /// reason stays.
  void cancel(CancelReason why) {
    if (isCanceled) return;
    _reason.write(Some(why)).run();
    final waiting = _waiters.read().run().values.toList();
    _waiters.write(const {}).run();
    for (final completer in waiting) {
      completer.complete(unit);
    }
  }
}
