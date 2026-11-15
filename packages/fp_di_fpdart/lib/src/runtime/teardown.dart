part of 'runtime.dart';

// The teardown of the nodes of a disposed scope (inventory 5).

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
        final unstarted = [...owned];
        final inFlight = <NodeId, Future<(NodeId, Cause<DiFailure>)>>{};
        final failures = <NodeId, Cause<DiFailure>>{};

        void start(NodeId n) {
          unstarted.remove(n);
          inFlight[n] = deactivate(
            n,
            permanent: true,
          ).run().then((cause) => (n, cause));
        }

        while (true) {
          for (final n in [...unstarted]) {
            // A dependent of a publisher of the node is done when it is
            // neither active nor releasing.
            if (dependentsOf(state, n).isEmpty) start(n);
          }
          if (inFlight.isEmpty && unstarted.isNotEmpty) start(unstarted.first);
          if (inFlight.isEmpty && unstarted.isEmpty) break;
          final (n, cause) = await Future.any(inFlight.values);
          unawaited(inFlight.remove(n));
          failures[n] = cause;
        }
        return owned.fold<Cause<DiFailure>>(
          const Empty<DiFailure>(),
          (all, n) => all + (failures[n] ?? const Empty<DiFailure>()),
        );
      });
}
