// The scheduler of a scope teardown (Teardown.tla). Not exported: the
// runtime calls it from `_Runtime._releaseOwned`, and its tests drive it
// with read graphs that the public API cannot build, such as a committed
// read cycle.
import 'dart:async';

import 'runtime_faults.dart';

/// The scheduler of a scope teardown over nodes of type [N], whose releases
/// report dispose failures of type [F].
final class RuntimeTeardownScheduler<N extends Object, F> {
  /// Creates a scheduler that checks [ready] and runs [release].
  RuntimeTeardownScheduler({required this.ready, required this.release});

  /// Whether every node that read a value of a node has finished its release.
  final bool Function(N node) ready;

  /// Releases one node and returns its dispose failures. It may first
  /// release the live dependents of the node, depth first, as the runtime's
  /// `deactivate` does.
  final Future<List<F>> Function(N node) release;

  /// Releases [owned], ordered by descending creation order, along the
  /// reverse of their reads, and returns the dispose failures of every
  /// release.
  ///
  /// Every ready node starts at once, so nodes that do not wait for each
  /// other release at the same time. When nothing runs and no node is ready,
  /// the reads form a cycle: the first unstarted node, the one created last,
  /// starts alone, and its [release] releases the cycle. Readiness is checked
  /// again only when a release returns, so nothing else starts meanwhile.
  ///
  /// The method returns after every started release has settled, then
  /// rethrows the first error of a [release] if one threw. The dispose
  /// failures follow [owned], whatever order the releases finished in; the
  /// dependents that one [release] released report at the place of that node.
  Future<List<F>> releaseAlongReads(List<N> owned) async {
    final disposeFailuresOf = <N, List<F>>{};
    final unstarted = <N>[...owned];
    final finished = Completer<void>();
    (Object, StackTrace)? failure;
    var inFlight = 0;

    late final void Function() pump;

    void start(N node) {
      unstarted.remove(node);
      inFlight++;
      unawaited(() async {
        try {
          disposeFailuresOf[node] = await release(node);
        } on Object catch (error, stackTrace) {
          failure ??= (error, stackTrace);
        }
        inFlight--;
        pump();
      }());
    }

    pump = () {
      for (final node in [...unstarted]) {
        // The defect starts a release only when no other release runs.
        final sequential = RuntimeFaults.injects(
          RuntimeDefect.sequentialTeardown,
        );
        if (sequential && inFlight > 0) break;
        if (ready(node)) start(node);
      }
      // A read cycle: nothing runs and nothing is ready.
      if (inFlight == 0 && unstarted.isNotEmpty) start(unstarted.first);
      if (inFlight == 0 && unstarted.isEmpty && !finished.isCompleted) {
        finished.complete();
      }
    };

    pump();
    await finished.future;
    if (failure case (final error, final stackTrace)?) {
      Error.throwWithStackTrace(error, stackTrace);
    }
    return [for (final node in owned) ...?disposeFailuresOf[node]];
  }
}
