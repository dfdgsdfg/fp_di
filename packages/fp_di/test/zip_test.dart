import 'dart:async';

import 'package:fp_di/fp_di.dart';
import 'package:test/test.dart';

/// A Dependency that reads the seed key named [tag], then creates a value
/// whose creation blocks until [gate] opens. The log shows when it starts
/// and when it is ready, so the order of two of them is visible without timing.
Dependency<String> _gated(
  String tag,
  Completer<void> started,
  Future<void> gate,
  List<String> events,
) => Dependency.require<int>(key: DiKey<int>(name: tag)).map((_) async {
  events.add('$tag+');
  if (!started.isCompleted) started.complete();
  await gate;
  events.add('$tag ready');
  return tag;
}, dispose: (_) => events.add('$tag-'));

Dependency<String> _logged(String tag, List<String> events) =>
    Dependency.require<int>(
      key: DiKey<int>(name: tag),
    ).map((_) => tag, dispose: (_) => events.add('$tag-'));

/// Declares one seed key per tag so that a Dependency reading it can resolve.
List<ComponentBase> _seeds(Iterable<String> tags) => [
  for (final tag in tags)
    Component.value(value: 0, key: DiKey<int>(name: tag)),
];

void main() {
  group('record zip value', () {
    test('yields the values in record order', () async {
      final di = Scope(
        module: Module(
          components: [
            Component.value(value: 1, key: DiKey<int>(name: 'count')),
            Component.value(
              value: 'b',
              key: DiKey<String>(name: 'text'),
            ),
            Component.value(
              value: true,
              key: DiKey<bool>(name: 'enabled'),
            ),
            Component.effect(
              dependency: (
                Dependency.require<int>(
                  key: const DiKey(name: 'count'),
                ),
                Dependency.require<String>(
                  key: const DiKey(name: 'text'),
                ),
              ).zip,
            ),
            Component.effect(
              dependency: (
                Dependency.require<int>(
                  key: const DiKey(name: 'count'),
                ),
                Dependency.require<String>(
                  key: const DiKey(name: 'text'),
                ),
                Dependency.require<bool>(
                  key: const DiKey(name: 'enabled'),
                ),
              ).zip,
            ),
          ],
        ),
      );
      await di.initialize();
      final two = di.nodes[3];
      final three = di.nodes[4];
      expect(two.value, (1, 'b'));
      expect(three.value, (1, 'b', true));
      await di.dispose();
    });

    test('supports eight Dependency values', () async {
      Dependency<int> k(int i) =>
          Dependency.require<int>(key: DiKey<int>(name: 'k$i'));
      final di = Scope(
        module: Module(
          components: [
            for (var i = 1; i <= 8; i++)
              Component.value(
                value: i,
                key: DiKey<int>(name: 'k$i'),
              ),
            Component.effect(
              dependency: (k(1), k(2), k(3), k(4), k(5), k(6), k(7), k(8)).zip,
            ),
          ],
        ),
      );
      await di.initialize();
      expect(di.nodes.last.value, (1, 2, 3, 4, 5, 6, 7, 8));
      await di.dispose();
    });

    test('feeds mapN', () async {
      final di = Scope(
        module: Module(
          components: [
            Component.value(value: 2, key: DiKey<int>(name: 'a')),
            Component.value(value: 3, key: DiKey<int>(name: 'b')),
            Component.effect(
              dependency: (
                Dependency.require<int>(key: DiKey<int>(name: 'a')),
                Dependency.require<int>(key: DiKey<int>(name: 'b')),
              ).zip.mapN((a, b) => a * b),
            ),
          ],
        ),
      );
      await di.initialize();
      expect(di.nodes.last.value, 6);
      await di.dispose();
    });
  });

  group('record zip shape', () {
    test('requires the same keys as requireN', () {
      final zipped = Component.effect(
        dependency: (
          Dependency.require<String>(key: const DiKey(name: 'text')),
          Dependency.require<int>(key: const DiKey(name: 'port')),
        ).zip,
      );
      final required = Component.effect(
        dependency: Dependency.require2<String, int>(
          key2: const DiKey(name: 'port'),
          key1: const DiKey(name: 'text'),
        ),
      );
      expect(zipped.requires, required.requires);
      expect(zipped.optional, isEmpty);
      expect(zipped.key, isNull);
    });

    test('stays dormant until every key resolves', () async {
      final di = Scope();
      final strings = di.child(
        module: Module(
          components: [
            Component.value(
              value: 'host',
              key: DiKey<String>(name: 'text'),
            ),
          ],
        ),
      );
      final ints = strings.child(
        module: Module(
          components: [
            Component.value(value: 80, key: DiKey<int>(name: 'count')),
          ],
        ),
      );
      final consumer = ints.child(
        module: Module(
          components: [
            Component.effect(
              dependency: (
                Dependency.require<String>(
                  key: const DiKey(name: 'text'),
                ),
                Dependency.require<int>(
                  key: const DiKey(name: 'count'),
                ),
              ).zip,
            ),
          ],
        ),
      );
      await consumer.initialize();
      final handle = consumer.nodes.single;
      expect(handle.isActive, isFalse);
      await strings.initialize();
      expect(handle.isActive, isFalse);
      await ints.initialize();
      expect(handle.isActive, isTrue);
      expect(handle.value, ('host', 80));
      await di.dispose();
    });
  });

  group('record zip lifecycle', () {
    test('runs the Dependency values left to right', () async {
      final events = <String>[];
      final leftStarted = Completer<void>();
      final rightStarted = Completer<void>();
      final leftGate = Completer<void>();
      final di = Scope(
        module: Module(
          components: [
            ..._seeds(['left', 'right']),
            Component.effect(
              dependency: (
                _gated('left', leftStarted, leftGate.future, events),
                _gated('right', rightStarted, Future<void>.value(), events),
              ).zip,
            ),
          ],
        ),
      );
      final pending = di.initialize();

      // The left acquisition is blocked on its gate. The right acquisition
      // must not start while the left acquisition is still in flight.
      await leftStarted.future;
      await Future<void>.delayed(Duration.zero);
      expect(events, ['left+']);
      expect(rightStarted.isCompleted, isFalse);

      leftGate.complete();
      await pending;
      expect(di.nodes.last.value, ('left', 'right'));
      expect(events, ['left+', 'left ready', 'right+', 'right ready']);
      await di.dispose();
    });

    test('tears down right to left', () async {
      final events = <String>[];
      final di = Scope(
        module: Module(
          components: [
            ..._seeds(['a', 'b', 'c']),
            Component.effect(
              dependency: (
                _logged('a', events),
                _logged('b', events),
                _logged('c', events),
              ).zip,
            ),
          ],
        ),
      );
      await di.initialize();
      await di.nodes.last.dispose();
      expect(events, ['c-', 'b-', 'a-']);
      await di.dispose();
    });

    test('starts a release only after the later release finished', () async {
      // The formal counterexample `ParallelSteps` (Teardown.tla) overlaps the
      // dispose functions of one node; this fixture holds the later release
      // open and fails if the earlier one starts meanwhile.
      final events = <String>[];
      final gate = Completer<void>();
      Dependency<String> gated(String tag) =>
          Dependency.require<int>(key: DiKey<int>(name: tag)).map(
            (_) => tag,
            dispose: (_) async {
              events.add('$tag start');
              if (tag == 'b') await gate.future;
              events.add('$tag end');
            },
          );
      final di = Scope(
        module: Module(
          components: [
            ..._seeds(['a', 'b']),
            Component.effect(dependency: (gated('a'), gated('b')).zip),
          ],
        ),
      );
      await di.initialize();
      final released = di.nodes.last.dispose();
      await pumpEventQueue();
      expect(events, ['b start']);

      gate.complete();
      await released;
      expect(events, ['b start', 'b end', 'a start', 'a end']);
      await di.dispose();
    });
  });
}
