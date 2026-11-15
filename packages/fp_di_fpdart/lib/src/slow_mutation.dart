import 'hold.dart';

/// A lifecycle operation that has run longer than the threshold of the root.
/// See `Scope(onSlowMutation:)`.
///
/// Every lifecycle operation of one root runs in one queue, so a slow
/// operation delays the [queued] operations behind it. [running] names the
/// activations still in flight. [ignoringCancellation] names the activations
/// whose token is canceled and whose step has not returned: a `create` that
/// does not read its token. [disposing] names the owners whose dispose
/// functions run, such as a dispose function that does not return.
final class SlowMutation {
  /// Creates a report of a slow operation. The constructor copies each list.
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

  /// The operation: `run`, `Scope.dispose`, or `ComponentNode.dispose`.
  final String operation;

  /// How long the operation has run.
  final Duration elapsed;

  /// The labels of the activations in flight, in node order.
  final List<String> running;

  /// The labels of the activations in flight whose token is canceled.
  final List<String> ignoringCancellation;

  /// The owners whose dispose functions run, in the order they started. A
  /// dispose function has no token, so one that does not return holds the
  /// queue until it returns. The rollback of an activation has the owner
  /// `<label> activation rollback`.
  final List<String> disposing;

  /// The operations that wait behind this one.
  final int queued;

  /// The open holds of a disposal that waits for them outside the queue,
  /// with the operation `Scope.dispose (waiting for holds)`. The list is
  /// empty for an operation that runs.
  final List<HoldState> holds;

  @override
  String toString() =>
      'SlowMutation($operation, ${elapsed.inMilliseconds} ms, '
      'running: ${running.isEmpty ? 'none' : running.join(', ')}'
      '${ignoringCancellation.isEmpty ? '' : ', ignoring cancellation: '
                '${ignoringCancellation.join(', ')}'}'
      '${disposing.isEmpty ? '' : ', disposing: ${disposing.join(', ')}'}'
      '${holds.isEmpty ? '' : ', holds: ${_names(holds)}'}'
      ', queued: $queued)';
}

/// Receives a [SlowMutation] report.
typedef SlowMutationListener = void Function(SlowMutation report);

String _names(List<HoldState> holds) =>
    holds.map((hold) => hold.name).join(', ');
