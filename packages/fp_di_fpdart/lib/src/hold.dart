/// An open hold of a disposal, as `Scope.openHolds`, a `SlowMutation`, and an
/// `IgnoredHoldsFailure` report it.
///
/// The value names its scope by a path and holds no scope, so a report keeps
/// no scope alive.
final class HoldState {
  /// Creates the state of one open hold.
  const HoldState({
    this.debugLabel,
    required this.scopePath,
    required this.elapsed,
    this.debugStackTrace,
  });

  /// The label that the holder gave to `Scope.disposeHold`, or `null`.
  final String? debugLabel;

  /// The scope of the hold, as `describe` of the root names it: `scope` for
  /// the root, and `child scope 1.2` for the second child of its first child.
  final String scopePath;

  /// How long the hold has been open.
  final Duration elapsed;

  /// The stack trace of the `disposeHold` call. The runtime records it only
  /// inside an `assert`, so it is `null` in a build without assertions.
  final StackTrace? debugStackTrace;

  /// The name of the hold in a message: its label, or `hold`.
  String get name => debugLabel ?? 'hold';

  @override
  String toString() =>
      'HoldState($name, $scopePath, ${elapsed.inMilliseconds} ms)';
}

/// A hold of the disposal of a scope, from `Scope.disposeHold`.
///
/// While the hold is open, a requested disposal of the scope or of an
/// ancestor waits, unless a call ignores the holds. Close the hold when the
/// consumer that took it leaves.
final class DisposeHold {
  DisposeHold._(this._close);

  final void Function() _close;
  bool _closed = false;

  /// Ends the hold. A waiting disposal starts when its last hold closes.
  ///
  /// A second call does nothing, and a call after the disposal started
  /// changes nothing. The call never throws, also inside a lifecycle
  /// operation, a listener, or a dispose function: the disposal then starts
  /// after that operation.
  void close() {
    if (_closed) return;
    _closed = true;
    _close();
  }
}

/// The hold that calls [close] when it ends. The runtime calls this
/// function. The library file does not export it.
DisposeHold createDisposeHold(void Function() close) => DisposeHold._(close);
