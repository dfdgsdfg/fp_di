/// A lifecycle mutation that has run longer than the root's
/// `slowMutationThreshold`. See `Scope(onSlowMutation:)`.
///
/// Every mutation of one root runs on one queue, so a slow one delays the
/// [queued] mutations behind it. [running] names the activations still in
/// flight. [ignoringCancellation] names those whose token is canceled but
/// whose step has not returned: a `create` that does not read its token.
/// [disposing] names the owners whose dispose functions run, such as a
/// dispose function that does not return.
///
/// {@category Observation}
final class SlowMutation {
  /// Creates a report of a slow mutation. The constructor copies each list.
  SlowMutation({
    required this.operation,
    required this.elapsed,
    required Iterable<String> running,
    required Iterable<String> ignoringCancellation,
    Iterable<String> disposing = const [],
    required this.queued,
    Iterable<HoldState> holds = const [],
  }) : running = List.unmodifiable(running),
       ignoringCancellation = List.unmodifiable(ignoringCancellation),
       disposing = List.unmodifiable(disposing),
       holds = List.unmodifiable(holds);

  /// The mutation, such as `initialize` or `Scope.dispose`.
  final String operation;

  /// How long the mutation has run.
  final Duration elapsed;

  /// The labels of the activations in flight, in node order.
  final List<String> running;

  /// The labels of the activations in flight whose token is canceled.
  final List<String> ignoringCancellation;

  /// The owners whose dispose functions run, in the order they started. A
  /// dispose function has no token, so one that does not return holds the
  /// queue until it returns. An activation rollback has the owner
  /// `<label> activation rollback`.
  final List<String> disposing;

  /// The mutations waiting behind this one.
  final int queued;

  /// The open holds of a disposal that waits for them outside the queue,
  /// with the operation `Scope.dispose (waiting for holds)`. Empty for a
  /// mutation that runs.
  final List<HoldState> holds;

  @override
  String toString() =>
      'SlowMutation($operation, ${elapsed.inMilliseconds} ms, '
      'running: ${running.isEmpty ? 'none' : running.join(', ')}'
      '${ignoringCancellation.isEmpty ? '' : ', ignoring cancellation: '
                '${ignoringCancellation.join(', ')}'}'
      '${disposing.isEmpty ? '' : ', disposing: ${disposing.join(', ')}'}'
      '${holds.isEmpty ? '' : ', holds: ${holds.map(_holdLabel).join(', ')}'}'
      ', queued: $queued)';
}

String _holdLabel(HoldState hold) => hold.debugLabel ?? 'hold';

/// An open hold of a disposal, as `Scope.openHolds`, a [SlowMutation], and an
/// `IgnoredHoldsException` report it.
///
/// The value names its scope by a path and holds no scope, so a report keeps
/// no scope alive.
///
/// {@category Observation}
final class HoldState {
  /// Creates the state of one open hold.
  const HoldState({
    this.debugLabel,
    required this.scopePath,
    required this.elapsed,
    this.debugStackTrace,
  });

  /// The label that the holder gave to `Scope.disposeHold`, or null.
  final String? debugLabel;

  /// The scope of the hold, as `describe` of the root names it: `scope` for
  /// the root, and `child scope 1.2` for the second child of its first child.
  final String scopePath;

  /// How long the hold has been open.
  final Duration elapsed;

  /// The stack trace of the `disposeHold` call. The runtime records it only
  /// inside an `assert`, so it is null in a build without assertions.
  final StackTrace? debugStackTrace;

  @override
  String toString() =>
      'HoldState(${_holdLabel(this)}, $scopePath, '
      '${elapsed.inMilliseconds} ms)';
}

/// Receives a [SlowMutation] report.
///
/// {@category Observation}
typedef SlowMutationListener = void Function(SlowMutation report);
