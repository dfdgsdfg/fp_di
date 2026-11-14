// Concurrent teardown of a disposed scope (V-T-RT-LC-023, Teardown.tla).
import 'dart:async';

import 'package:fp_di/fp_di.dart';
import 'package:test/test.dart';

DiKey<int> _k(String name) => DiKey<int>(name: name);

/// A member that publishes `_k(name)`, reads [reads], and logs its release.
/// The release waits for [gate] or [delay] and throws [fail] if set.
Component<int> _member(
  String name,
  List<String> log, {
  List<String> reads = const [],
  Future<void>? gate,
  Duration delay = Duration.zero,
  Object? fail,
}) {
  Future<void> release(int _) async {
    log.add('start $name');
    await (gate ?? Future<void>.delayed(delay));
    log.add('end $name');
    if (fail != null) throw fail;
  }

  final Dependency<int> dependency = switch (reads) {
    [] => Dependency<int>(create: () => 0, dispose: release),
    [final only] => Dependency.require<int>(
      key: _k(only),
    ).map((v) => v + 1, dispose: release),
    [final a, final b] => (
      Dependency.require<int>(key: _k(a)),
      Dependency.require<int>(key: _k(b)),
    ).zip.mapN((x, y) => x + y, dispose: release),
    _ => throw ArgumentError('at most two reads'),
  };
  return Component<int>(
    key: _k(name),
    debugLabel: name,
    dependency: dependency,
  );
}

void main() {
  test('independent members release at the same time', () async {
    final log = <String>[];
    const delay = Duration(milliseconds: 100);
    final di = await Scope(
      module: Module(
        components: [
          for (var i = 0; i < 5; i++) _member('m$i', log, delay: delay),
        ],
      ),
    ).initialize();
    final watch = Stopwatch()..start();
    await di.dispose();
    watch.stop();
    // Five sequential releases would take 500 ms or more.
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 350)));
    final firstEnd = log.indexWhere((e) => e.startsWith('end'));
    expect(
      log.take(firstEnd).where((e) => e.startsWith('start')),
      hasLength(5),
    );
  });

  test('a publisher waits for every dependent to finish', () async {
    final log = <String>[];
    final gate = Completer<void>();
    final di = await Scope(
      module: Module(
        components: [
          _member('p1', log),
          _member('p2', log),
          _member('d', log, reads: ['p1', 'p2'], gate: gate.future),
        ],
      ),
    ).initialize();
    final teardown = di.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(log, ['start d'], reason: 'no publisher starts while d releases');
    gate.complete();
    await teardown;
    expect(log.sublist(0, 2), ['start d', 'end d']);
    expect(
      log.sublist(2),
      unorderedEquals(['start p1', 'end p1', 'start p2', 'end p2']),
    );
  });

  test('a chain releases dependents first', () async {
    final log = <String>[];
    final di = await Scope(
      module: Module(
        components: [
          _member('a', log),
          _member('b', log, reads: ['a']),
          _member('c', log, reads: ['b']),
        ],
      ),
    ).initialize();
    await di.dispose();
    expect(log, ['start c', 'end c', 'start b', 'end b', 'start a', 'end a']);
  });

  test('the read graph orders the release, not the creation order', () async {
    final log = <String>[];
    final di = await Scope(
      module: Module(
        components: [
          // Created first, but reads the publisher created last.
          _member(
            'reader',
            log,
            reads: ['publisher'],
            delay: const Duration(milliseconds: 20),
          ),
          _member('publisher', log),
        ],
      ),
    ).initialize();
    await di.dispose();
    expect(log, [
      'start reader',
      'end reader',
      'start publisher',
      'end publisher',
    ]);
  });

  test('a child scope releases before the parent values it read', () async {
    final log = <String>[];
    final root = Scope(module: Module(components: [_member('api', log)]));
    final child = root.child(
      module: Module(
        components: [
          _member(
            'screen',
            log,
            reads: ['api'],
            delay: const Duration(milliseconds: 20),
          ),
        ],
      ),
    );
    await root.initialize();
    await child.initialize();
    expect(child.nodes.single.isActive, isTrue);
    await root.dispose();
    expect(log.indexOf('end screen'), lessThan(log.indexOf('start api')));
  });

  test('the dispose failures follow node order', () async {
    Future<List<String>> owners({required bool lateFirst}) async {
      final log = <String>[];
      final di = await Scope(
        module: Module(
          components: [
            _member(
              'first',
              log,
              delay: Duration(milliseconds: lateFirst ? 40 : 0),
              fail: StateError('first'),
            ),
            _member(
              'second',
              log,
              delay: Duration(milliseconds: lateFirst ? 0 : 40),
              fail: StateError('second'),
            ),
          ],
        ),
      ).initialize();
      try {
        await di.dispose();
      } on DisposeException catch (error) {
        return [for (final failure in error.disposeFailures) failure.owner];
      }
      return const [];
    }

    final one = await owners(lateFirst: true);
    final other = await owners(lateFirst: false);
    expect(one, ['second', 'first']);
    expect(other, one);
  });

  test('a slow-mutation report names every release that runs', () async {
    final reports = <SlowMutation>[];
    final gate = Completer<void>();
    final log = <String>[];
    final di = await Scope(
      onSlowMutation: reports.add,
      slowMutationThreshold: const Duration(milliseconds: 30),
      module: Module(
        components: [
          _member('a', log, gate: gate.future),
          _member('b', log, gate: gate.future),
        ],
      ),
    ).initialize();
    final teardown = di.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(reports.last.disposing, unorderedEquals(['a', 'b']));
    gate.complete();
    await teardown;
  });

  // The feedback pair reads each other in its declaration, but every rebuild
  // gives one side a new publisher, so the committed reads form no cycle and
  // the teardown is a plain reverse walk. teardown_scheduler_test.dart checks
  // the cycle fallback on a committed cycle at the scheduler boundary.
  test('an optional feedback pair releases each node once', () async {
    final released = <String>[];
    final outside = DiKey<int>(name: 'outside');
    final k = DiKey<int>(name: 'K');
    final l = DiKey<int>(name: 'L');
    final root = Scope(
      module: Module(components: [Component.value(value: 0, key: outside)]),
    );
    final child = root.child(
      module: Module(
        components: [
          Component<int>(
            key: l,
            debugLabel: 'x',
            dependency:
                (
                  Dependency.require<int>(key: outside),
                  Dependency.maybe<int>(key: k),
                ).zip.mapN(
                  (_, v) => (v ?? 0) + 1,
                  dispose: (_) => released.add('x'),
                ),
          ),
          Component<int>(
            key: k,
            debugLabel: 'y',
            dependency: Dependency.require<int>(
              key: l,
            ).map((v) => v + 1, dispose: (_) => released.add('y')),
          ),
        ],
      ),
    );
    final errors = root.errors.listen((_) {}); // the feedback is reported
    await child.initialize();
    await root.initialize(); // wakes x and y, which read each other
    await Future<void>.delayed(Duration.zero);
    final active = [
      for (final node in child.nodes)
        if (node.isActive) node,
    ].length;
    expect(active, 2, reason: 'both sides of the feedback are active');
    released.clear(); // the rebuilds of the feedback released earlier values
    await root.dispose().timeout(const Duration(seconds: 5));
    expect(released, hasLength(active));
    expect(released.toSet(), hasLength(active), reason: 'each node once');
    await errors.cancel();
  });
}
