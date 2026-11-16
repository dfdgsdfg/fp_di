// The scheduler of a scope teardown (Teardown.tla). Not exported: the
// runtime calls it from `_Runtime._releaseOwned`, and its tests drive it
// with read graphs that the public API cannot build, such as a committed
// read cycle.
import 'dart:async';

import 'runtime_faults.dart';

/// The scheduler of a scope teardown over nodes of type [N], whose releases
/// report dispose failures of type [F].
final class RuntimeTeardownScheduler<N extends Object, F> {
  /// Creates a scheduler that checks [ready], runs [release], and after a
  /// release checks again the nodes that [reads] gives.
  RuntimeTeardownScheduler({
    required this.ready,
    required this.release,
    required this.reads,
  });

  /// Whether every node that read a value of a node has finished its release.
  final bool Function(N node) ready;

  /// The nodes whose values a node read. The scheduler reads them before the
  /// release of the node starts. The end of that release can make only these
  /// nodes ready, outside the read-cycle fallback.
  final Iterable<N> Function(N node) reads;

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
    final position = <N, int>{
      for (var i = 0; i < owned.length; i++) owned[i]: i,
    };
    // Insertion order is [owned] order, and a removal costs constant time.
    final unstarted = <N>{...owned};
    final finished = Completer<void>();
    (Object, StackTrace)? failure;
    var inFlight = 0;

    late final void Function(Iterable<N>? woken) pump;

    void start(N node, {bool fallback = false}) {
      unstarted.remove(node);
      inFlight++;
      // A release clears the reads of its node, so the scheduler reads them
      // first.
      final woken = fallback ? null : reads(node).toList();
      unawaited(() async {
        try {
          disposeFailuresOf[node] = await release(node);
        } on Object catch (error, stackTrace) {
          failure ??= (error, stackTrace);
        }
        inFlight--;
        // A fallback release also releases other nodes, so its end checks
        // every unstarted node again.
        pump(woken);
      }());
    }

    void startReady(Iterable<N> candidates) {
      for (final node in candidates) {
        // The defect starts a release only when no other release runs.
        final sequential = RuntimeFaults.injects(
          RuntimeDefect.sequentialTeardown,
        );
        if (sequential && inFlight > 0) break;
        if (unstarted.contains(node) && ready(node)) start(node);
      }
    }

    // A node becomes ready only when a node that read one of its values
    // finishes its release. The end of a release therefore checks only the
    // nodes that the released node read, so a teardown costs time
    // near-linear in the nodes and their reads. A check of every unstarted
    // node runs at the start, after a fallback, under the defect, and
    // whenever nothing runs.
    pump = (woken) {
      final sequential = RuntimeFaults.injects(
        RuntimeDefect.sequentialTeardown,
      );
      if (woken != null && !sequential) {
        startReady(
          [
            for (final node in woken)
              if (unstarted.contains(node)) node,
          ]..sort((a, b) => position[a]!.compareTo(position[b]!)),
        );
      } else {
        startReady([...unstarted]);
      }
      if (inFlight == 0 && unstarted.isNotEmpty && woken != null) {
        startReady([...unstarted]);
      }
      // A read cycle: nothing runs and nothing is ready.
      if (inFlight == 0 && unstarted.isNotEmpty) {
        start(unstarted.first, fallback: true);
      }
      if (inFlight == 0 && unstarted.isEmpty && !finished.isCompleted) {
        finished.complete();
      }
    };

    pump(null);
    await finished.future;
    if (failure case (final error, final stackTrace)?) {
      Error.throwWithStackTrace(error, stackTrace);
    }
    return [for (final node in owned) ...?disposeFailuresOf[node]];
  }
}
