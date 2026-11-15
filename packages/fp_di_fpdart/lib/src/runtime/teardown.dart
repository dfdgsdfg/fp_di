part of 'runtime.dart';

// The teardown of the nodes of a disposed scope (inventory 5).

/// The scheduler of a teardown: it starts the release of each node when the
/// nodes that read it are done, and lets the other releases run at the same
/// time.
///
/// The scheduler knows no runtime. It takes the test [ready], which tells that
/// no node that reads a node is still active, and the function [release] that
/// releases one node. A fake node and a fake runtime can run it, which the
/// tests do for read graphs that the public API cannot build.
final class TeardownScheduler<N, R> {
  /// Creates a scheduler.
  ///
  /// [freed] gives the nodes that the release of a node can make ready: the
  /// nodes that it read. A scheduler without it looks at every node that did
  /// not start after each release that ends.
  TeardownScheduler({required this.ready, required this.release, this.freed});

  /// Whether the readers of a node are done.
  final bool Function(N node) ready;

  /// Releases one node, and gives its result.
  final Future<R> Function(N node) release;

  /// The nodes that the release of a node can make ready, read before the
  /// release starts. `null` stands for every node that did not start.
  final Iterable<N> Function(N node)? freed;

  /// Releases [owned] along the reverse of the reads of the nodes.
  ///
  /// A node starts when [ready] holds for it. Nodes that do not wait for each
  /// other release at the same time. A read cycle leaves no node ready, so
  /// the first unstarted node of [owned] starts alone.
  ///
  /// The result maps each node to the result of its release. A release that
  /// throws does not stop the others. The first error goes to the caller after
  /// every release ended.
  Future<Map<N, R>> releaseAlongReads(List<N> owned) async {
    final unstarted = LinkedHashSet<N>.of(owned);
    final finished = Completions<(N, R)>();
    final results = <N, R>{};
    var inFlight = 0;
    Object? firstError;
    StackTrace? firstStack;
    final rank = {for (var i = 0; i < owned.length; i++) owned[i]: i};

    // The nodes to look at before the next wait.
    final candidates = LinkedHashSet<N>.of(owned);

    void start(N node) {
      unstarted.remove(node);
      inFlight++;
      if (freed case final freed?) {
        candidates.addAll(freed(node));
      } else {
        candidates.addAll(unstarted);
      }
      unawaited(
        release(node).then(
          (result) => finished.add((node, result)),
          onError: finished.addError,
        ),
      );
    }

    while (true) {
      // Only the nodes that a finished release freed can have become ready.
      final look = candidates.where(unstarted.contains).toList()
        ..sort((a, b) => rank[a]!.compareTo(rank[b]!));
      candidates.clear();
      for (final node in look) {
        if (unstarted.contains(node) && ready(node)) start(node);
      }
      if (inFlight == 0 && unstarted.isNotEmpty) {
        // A release that this loop did not start can free a node. Look at every
        // node once before the cycle rule.
        for (final node in [...unstarted]) {
          if (ready(node)) start(node);
        }
        // A read cycle leaves no node ready, so the first unstarted node
        // starts alone.
        if (inFlight == 0) start(unstarted.first);
      }
      if (inFlight == 0 && unstarted.isEmpty) break;
      try {
        final (node, result) = await finished.next();
        results[node] = result;
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        firstStack ??= stackTrace;
      }
      inFlight--;
    }
    if (firstError != null) Error.throwWithStackTrace(firstError, firstStack!);
    return results;
  }
}

/// The teardown of the nodes of a disposed scope.
extension RuntimeTeardown on Runtime {
  /// The task that releases [owned], which lists the nodes in descending id,
  /// along the reverse of their committed reads.
  ///
  /// A node starts when no active or deactivating node reads one of its
  /// values, so it releases while the values that it read are alive. Nodes
  /// that do not wait for each other release at the same time. A read cycle
  /// leaves no node ready, so the first unstarted node starts alone.
  ///
  /// The result is the cause of every dispose failure, in the order of
  /// [owned], whatever order the releases finished in.
  Task<Cause<DiFailure>> releaseAlongReads(List<NodeId> owned) =>
      Task(() async {
        final results = await TeardownScheduler<NodeId, Cause<DiFailure>>(
          ready: (n) => !hasDependents(state, n),
          freed: (n) => nodeRecord(state, n).dependencies,
          release: (n) => deactivate(n, permanent: true).run(),
        ).releaseAlongReads(owned);
        return owned.fold<Cause<DiFailure>>(
          const Empty<DiFailure>(),
          (all, n) => all + (results[n] ?? const Empty<DiFailure>()),
        );
      });
}
