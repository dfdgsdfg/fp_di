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
  }) : running = List.unmodifiable(running),
       ignoringCancellation = List.unmodifiable(ignoringCancellation),
       disposing = List.unmodifiable(disposing);

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

  @override
  String toString() =>
      'SlowMutation($operation, ${elapsed.inMilliseconds} ms, '
      'running: ${running.isEmpty ? 'none' : running.join(', ')}'
      '${ignoringCancellation.isEmpty ? '' : ', ignoring cancellation: '
                '${ignoringCancellation.join(', ')}'}'
      '${disposing.isEmpty ? '' : ', disposing: ${disposing.join(', ')}'}'
      ', queued: $queued)';
}

/// Receives a [SlowMutation] report.
///
/// {@category Observation}
typedef SlowMutationListener = void Function(SlowMutation report);
