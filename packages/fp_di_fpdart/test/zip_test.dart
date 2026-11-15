// Record zip: the order of the steps, the shape, and the release order.
import 'dart:async';

import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

/// A Dependency that reads the seed key named [tag], then creates a value
/// whose creation blocks until [gate] opens. The log shows when it starts
/// and when it is ready, so the order of two of them is visible without timing.
Dependency<String> _gated(
  String tag,
  Completer<void> started,
  Future<void> gate,
  List<String> events,
) => Dependency.require<int>(key: DiKey<int>(name: tag)).mapTask<String>(
  (_) => Task(() async {
    events.add('$tag+');
    if (!started.isCompleted) started.complete();
    await gate;
    events.add('$tag ready');
    return tag;
  }),
  dispose: (_) => events.add('$tag-'),
);

Dependency<String> _logged(String tag, List<String> events) =>
    Dependency.require<int>(
      key: DiKey<int>(name: tag),
    ).map((_) => tag, dispose: (_) => events.add('$tag-'));

/// Declares one seed key per tag so that a Dependency reading it can resolve.
List<Component<Object?>> _seeds(Iterable<String> tags) => [
  for (final tag in tags)
    Component<int>.value(value: 0, key: DiKey<int>(name: tag)),
];

void main() {
  group('record zip value', () {
    test('yields the values in record order', () async {
      // from: zip_test.dart: yields the values in record order
      final di = Scope(
        components: [
          Component<int>.value(value: 1, key: const DiKey<int>(name: 'count')),
          Component<String>.value(
            value: 'b',
            key: const DiKey<String>(name: 'text'),
          ),
          Component<bool>.value(
            value: true,
            key: const DiKey<bool>(name: 'enabled'),
          ),
          Component<(int, String)>.effect(
            dependency: (
              Dependency.require<int>(key: const DiKey(name: 'count')),
              Dependency.require<String>(key: const DiKey(name: 'text')),
            ).zip,
          ),
          Component<(int, String, bool)>.effect(
            dependency: (
              Dependency.require<int>(key: const DiKey(name: 'count')),
              Dependency.require<String>(key: const DiKey(name: 'text')),
              Dependency.require<bool>(key: const DiKey(name: 'enabled')),
            ).zip,
          ),
        ],
      );
      rightOf(await di.run());
      final two = di.nodes[3];
      final three = di.nodes[4];
      expect(rightOf(two.value), (1, 'b'));
      expect(rightOf(three.value), (1, 'b', true));
      rightOf(await di.dispose());
    });

    test('supports eight Dependency values', () async {
      // from: zip_test.dart: supports eight Dependency values
      Dependency<int> k(int i) =>
          Dependency.require<int>(key: DiKey<int>(name: 'k$i'));
      final di = Scope(
        components: [
          for (var i = 1; i <= 8; i++)
            Component<int>.value(
              value: i,
              key: DiKey<int>(name: 'k$i'),
            ),
          Component<(int, int, int, int, int, int, int, int)>.effect(
            dependency: (k(1), k(2), k(3), k(4), k(5), k(6), k(7), k(8)).zip,
          ),
        ],
      );
      rightOf(await di.run());
      expect(rightOf(di.nodes.last.value), (1, 2, 3, 4, 5, 6, 7, 8));
      rightOf(await di.dispose());
    });

    test('feeds mapN', () async {
      // from: zip_test.dart: feeds mapN
      final di = Scope(
        components: [
          Component<int>.value(value: 2, key: const DiKey<int>(name: 'a')),
          Component<int>.value(value: 3, key: const DiKey<int>(name: 'b')),
          Component<int>.effect(
            dependency: (
              Dependency.require<int>(key: const DiKey<int>(name: 'a')),
              Dependency.require<int>(key: const DiKey<int>(name: 'b')),
            ).zip.mapN<int>((a, b) => a * b),
          ),
        ],
      );
      rightOf(await di.run());
      expect(rightOf(di.nodes.last.value), 6);
      rightOf(await di.dispose());
    });
  });

  group('record zip shape', () {
    test('requires the same keys as require2', () {
      // from: zip_test.dart: requires the same keys as requireN
      final zipped = Component<(String, int)>.effect(
        dependency: (
          Dependency.require<String>(key: const DiKey(name: 'text')),
          Dependency.require<int>(key: const DiKey(name: 'port')),
        ).zip,
      );
      final required = Component<(String, int)>.effect(
        dependency: Dependency.require2<String, int>(
          key2: const DiKey(name: 'port'),
          key1: const DiKey(name: 'text'),
        ),
      );
      expect(zipped.requires, required.requires);
      expect(zipped.optional, isEmpty);
      expect(zipped.hasKey, isFalse);
    });

    test('stays dormant until every key resolves', () async {
      // from: zip_test.dart: stays dormant until every key resolves
      final di = Scope(components: []);
      final strings = di.kid(
        components: [
          Component<String>.value(
            value: 'host',
            key: const DiKey<String>(name: 'text'),
          ),
        ],
      );
      final ints = strings.kid(
        components: [
          Component<int>.value(value: 80, key: const DiKey<int>(name: 'count')),
        ],
      );
      final consumer = ints.kid(
        components: [
          Component<(String, int)>.effect(
            dependency: (
              Dependency.require<String>(key: const DiKey(name: 'text')),
              Dependency.require<int>(key: const DiKey(name: 'count')),
            ).zip,
          ),
        ],
      );
      rightOf(await consumer.run());
      final handle = consumer.nodes.single;
      expect(handle.isActive, isFalse);
      rightOf(await strings.run());
      expect(handle.isActive, isFalse);
      rightOf(await ints.run());
      expect(handle.isActive, isTrue);
      expect(rightOf(handle.value), ('host', 80));
      rightOf(await di.dispose());
    });
  });

  group('record zip lifecycle', () {
    test('runs the Dependency values left to right', () async {
      // from: zip_test.dart: runs the Dependency values left to right
      final events = <String>[];
      final leftStarted = Completer<void>();
      final rightStarted = Completer<void>();
      final leftGate = Completer<void>();
      final di = Scope(
        components: [
          ..._seeds(['left', 'right']),
          Component<(String, String)>.effect(
            dependency: (
              _gated('left', leftStarted, leftGate.future, events),
              _gated('right', rightStarted, Future<void>.value(), events),
            ).zip,
          ),
        ],
      );
      final pending = di.run();

      // The left acquisition is blocked on its gate. The right acquisition
      // must not start while the left acquisition is still in flight.
      await leftStarted.future;
      await Future<void>.delayed(Duration.zero);
      expect(events, ['left+']);
      expect(rightStarted.isCompleted, isFalse);

      leftGate.complete();
      rightOf(await pending);
      expect(rightOf(di.nodes.last.value), ('left', 'right'));
      expect(events, ['left+', 'left ready', 'right+', 'right ready']);
      rightOf(await di.dispose());
    });

    test('tears down right to left', () async {
      // from: zip_test.dart: tears down right to left
      final events = <String>[];
      final di = Scope(
        components: [
          ..._seeds(['a', 'b', 'c']),
          Component<(String, String, String)>.effect(
            dependency: (
              _logged('a', events),
              _logged('b', events),
              _logged('c', events),
            ).zip,
          ),
        ],
      );
      rightOf(await di.run());
      rightOf(await di.nodes.last.dispose());
      expect(events, ['c-', 'b-', 'a-']);
      rightOf(await di.dispose());
    });

    test('starts a release only after the later release finished', () async {
      // The formal counterexample `ParallelSteps` (Teardown.tla) overlaps the
      // dispose functions of one node; this fixture holds the later release
      // open and fails if the earlier one starts meanwhile.
      // from: zip_test.dart: starts a release only after the later release
      // finished
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
        components: [
          ..._seeds(['a', 'b']),
          Component<(String, String)>.effect(
            dependency: (gated('a'), gated('b')).zip,
          ),
        ],
      );
      rightOf(await di.run());
      final released = di.nodes.last.dispose();
      await pumpEventQueue();
      expect(events, ['b start']);

      gate.complete();
      rightOf(await released);
      expect(events, ['b start', 'b end', 'a start', 'a end']);
      rightOf(await di.dispose());
    });
  });
}
