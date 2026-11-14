import 'dart:async';

/// Whether the activation that runs a `Dependency` is canceled.
///
/// The runtime cancels the token of an activation when the disposal of its
/// owner is requested, and when an active activation starts to deactivate.
/// The token changes from not canceled to canceled at most once.
/// [isCanceled] changes at that moment; [whenCanceled] listeners run later,
/// like any Dart future listener, and the runtime does not wait for them.
///
/// Read it with `Dependency.cancellation()`. A cooperative `create` stops its
/// work when the token is canceled; the runtime checks the token between steps
/// anyway, so a `create` that ignores it only delays its own settlement.
///
/// To call such a `create` outside the runtime, for example in a unit test,
/// pass [CancellationToken.none] or the token of a [CancellationController].
///
/// {@category Dependency}
abstract interface class CancellationToken {
  /// A token that is never canceled.
  static final CancellationToken none = _NeverCanceled();

  /// Whether the activation is canceled.
  bool get isCanceled;

  /// Completes once when the activation is canceled. It never completes with
  /// an error, so it can be an abort trigger, such as the `abortTrigger` of a
  /// `package:http` `AbortableRequest`.
  Future<void> get whenCanceled;
}

/// A [CancellationToken] that its owner cancels, for code that calls a
/// cancelable function itself, such as a test.
///
/// The runtime cancels the tokens of activations on its own; a controller is
/// for the other side, like a `StreamController` for a stream.
///
/// {@category Dependency}
final class CancellationController {
  final CancellationSource _source = CancellationSource();

  /// The token to pass to the cancelable function.
  late final CancellationToken token = _ControlledToken(this);

  /// Whether [cancel] was called.
  bool get isCanceled => _source.isCanceled;

  /// Cancels [token]. Safe to call more than once.
  void cancel() => _source.cancel(CancelReason.owner);
}

final class _ControlledToken implements CancellationToken {
  _ControlledToken(this._controller);

  final CancellationController _controller;

  @override
  bool get isCanceled => _controller.isCanceled;

  @override
  Future<void> get whenCanceled => _controller._source.whenCanceled;
}

final class _NeverCanceled implements CancellationToken {
  static final Future<void> _never = Completer<void>().future;

  @override
  bool get isCanceled => false;

  @override
  Future<void> get whenCanceled => _never;
}

/// Why the runtime canceled a token. Not part of the public API.
enum CancelReason {
  /// The disposal of the owner was requested.
  owner,

  /// The withdrawal of a publisher that the activation reads was requested.
  withdrawal,

  /// The active activation started to deactivate.
  deactivation,

  /// A step of the region failed; its rollback follows.
  failure,
}

/// The runtime's side of a [CancellationToken]. Not part of the public API.
final class CancellationSource implements CancellationToken {
  /// The completers of [whenCanceled] that wait for the cancellation, one for
  /// each zone that asked. A completer completes by a microtask of the zone
  /// that created it, so a listener of another zone cannot share it: that zone
  /// can be dead when the cancellation comes.
  Map<Zone, Completer<void>>? _waiters;
  bool _canceled = false;

  /// A token for a child region: canceled when [parent] is, or on its own.
  CancellationSource.child(CancellationToken parent) {
    if (parent.isCanceled) {
      cancel(CancelReason.owner);
    } else {
      unawaited(parent.whenCanceled.then((_) => cancel(CancelReason.owner)));
    }
  }

  /// A token for a root region.
  CancellationSource();

  /// The reason of the first cancellation, or null.
  CancelReason? reason;

  @override
  bool get isCanceled => _canceled;

  @override
  Future<void> get whenCanceled => _canceled
      ? Future<void>.sync(() {})
      : (_waiters ??= <Zone, Completer<void>>{})
            .putIfAbsent(Zone.current, Completer<void>.new)
            .future;

  /// Cancels the token for [why]. Safe to call more than once; the first
  /// reason stays.
  void cancel(CancelReason why) {
    if (_canceled) return;
    reason = why;
    _canceled = true;
    final waiters = _waiters?.values.toList();
    _waiters = null;
    if (waiters == null) return;
    for (final waiter in waiters) {
      waiter.complete();
    }
  }
}
