// The teardown scheduler on read graphs that the public API cannot build
// (Teardown.tla). A committed read cycle needs two nodes that
// read each other's current publisher; a feedback rebuild always gives one
// of them a new publisher, so a public scope never keeps such a cycle.
import 'dart:async';

import 'package:fp_di_fpdart/src/runtime/runtime.dart';
import 'package:test/test.dart';

/// A node of a fake runtime: its reads, and a release that, like
/// `_Runtime.deactivate`, first releases its live dependents depth first in
/// descending id and skips a dependent that is releasing.
final class _Node {
  _Node(this.id);

  final int id;
  final Set<_Node> reads = {};
  String state = 'live'; // live | deactivating | released
}

final class _Graph {
  _Graph(int count, Map<int, Set<int>> reads, {this.fail = const {}}) {
    nodes = [for (var id = 1; id <= count; id++) _Node(id)];
    for (final MapEntry(:key, :value) in reads.entries) {
      nodes[key - 1].reads.addAll(value.map((id) => nodes[id - 1]));
    }
  }

  late final List<_Node> nodes;
  final Set<int> fail;
  final List<int> order = []; // the own releases, in the order they began
  final List<(int, int)> overlaps = []; // two own releases at the same time
  final Set<_Node> releasing = {};

  Iterable<_Node> dependentsOf(_Node node) =>
      nodes.where((d) => d.reads.contains(node));

  bool ready(_Node node) => dependentsOf(
    node,
  ).every((d) => identical(d, node) || d.state == 'released');

  Future<List<int>> release(_Node node) async {
    if (node.state != 'live') return const [];
    node.state = 'deactivating';
    final disposeFailures = <int>[];
    final dependents = dependentsOf(node).toList()
      ..sort((a, b) => b.id.compareTo(a.id));
    for (final dependent in dependents) {
      disposeFailures.addAll(await release(dependent));
    }
    for (final other in releasing) {
      overlaps.add((other.id, node.id));
    }
    releasing.add(node);
    order.add(node.id);
    await Future<void>.delayed(Duration.zero);
    releasing.remove(node);
    node.state = 'released';
    if (fail.contains(node.id)) disposeFailures.add(node.id);
    return disposeFailures;
  }

  Future<List<int>> run() async {
    final owned = nodes.reversed.toList(); // descending creation order
    final results = await TeardownScheduler<_Node, List<int>>(
      ready: ready,
      release: release,
    ).releaseAlongReads(owned).timeout(const Duration(seconds: 2));
    return [for (final node in owned) ...?results[node]];
  }
}

void main() {
  test(
    'a committed cycle that reads a publisher: Teardown.tla Cycle',
    () async {
      // 1 and 2 read each other; 3 reads 1; 1 also reads the publisher 4.
      // from: teardown_scheduler_test.dart: a committed cycle that reads a
      // publisher: Teardown.tla Cycle
      final graph = _Graph(
        4,
        {
          1: {2, 4},
          2: {1},
          3: {1},
        },
        fail: {1, 4},
      );
      final disposeFailures = await graph.run();
      // 3 is ready at once. Then nothing is ready: the fallback starts 4, the
      // node created last, whose release walks 1 and then 2 depth first.
      expect(graph.order, [3, 2, 1, 4]);
      expect(graph.nodes.every((n) => n.state == 'released'), isTrue);
      // The dispose failures of the fallback group report at the place of 4,
      // in the order of its release.
      expect(disposeFailures, [1, 4]);
    },
  );

  test('without a ready node or a release, the fallback still makes '
      'progress', () async {
    // Every node is in one cycle: 1 -> 2 -> 3 -> 1.
    // from: teardown_scheduler_test.dart: without a ready node or a release,
    // the fallback still makes progress
    final graph = _Graph(3, {
      1: {3},
      2: {1},
      3: {2},
    });
    await graph.run();
    expect(graph.nodes.every((n) => n.state == 'released'), isTrue);
    expect(graph.order, hasLength(3), reason: 'each node releases once');
  });

  test('a diamond releases its independent nodes together, readers '
      'first', () async {
    // 2 and 3 read 1; 4 reads 2 and 3; 5 is independent.
    // from: teardown_scheduler_test.dart: a diamond releases its independent
    // nodes together, readers first
    final graph = _Graph(
      5,
      {
        2: {1},
        3: {1},
        4: {2, 3},
      },
      fail: {2, 5},
    );
    final disposeFailures = await graph.run();
    expect(graph.order.indexOf(4), lessThan(graph.order.indexOf(2)));
    expect(graph.order.indexOf(4), lessThan(graph.order.indexOf(3)));
    expect(graph.order.indexOf(2), lessThan(graph.order.indexOf(1)));
    expect(graph.order.indexOf(3), lessThan(graph.order.indexOf(1)));
    expect(graph.overlaps, isNotEmpty, reason: '5 and 4 release together');
    expect(disposeFailures, [5, 2], reason: 'descending creation order');
  });

  test('a release that throws does not stop the others', () async {
    // from: teardown_scheduler_test.dart: a release that throws does not stop
    // the others
    final graph = _Graph(2, {});
    var released = 0;
    await expectLater(
      TeardownScheduler<_Node, List<int>>(
        ready: (_) => true,
        release: (node) async {
          released++;
          if (node.id == 2) throw StateError('release');
          return const [];
        },
      ).releaseAlongReads(graph.nodes.reversed.toList()),
      throwsStateError,
    );
    expect(released, 2);
  });
}
