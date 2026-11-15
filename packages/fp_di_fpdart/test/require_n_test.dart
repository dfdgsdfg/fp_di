import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

final class Config {
  Config(this.name, this.port, this.debug);

  final String name;
  final int port;
  final bool debug;
}

const text = DiKey<String>(name: 'text');
const count = DiKey<int>(name: 'count');
const enabled = DiKey<bool>(name: 'enabled');

void main() {
  group('requireN shape', () {
    test('is the derived set of keys with no declaration', () {
      // from: require_n_test.dart: is the derived set of keys with no
      // declaration
      final shape = Component<(String, int, bool)>.effect(
        dependency: Dependency.require3<String, int, bool>(
          key1: text,
          key2: count,
          key3: enabled,
        ),
      );
      expect(shape.requires, {text, count, enabled});
      expect(shape.optional, isEmpty);
      expect(shape.collectionKeys, isEmpty);
      expect(shape.isEffect, isTrue);
      expect(shape.debugLabel, isNull);
    });

    test('uses named keys where given', () {
      // from: require_n_test.dart: uses named keys where given
      final shape = Component<(String, String)>.effect(
        dependency: Dependency.require2<String, String>(
          key1: const DiKey(name: 'first'),
          key2: const DiKey(name: 'second'),
        ),
      );
      expect(shape.requires, {
        const DiKey<String>(name: 'first'),
        const DiKey<String>(name: 'second'),
      });
    });

    test('mapN, mapN with dispose, and a key keep the shape', () {
      // from: require_n_test.dart: mapN, mapN with dispose, and a key keep
      // the shape
      final base = Dependency.require2<String, int>(
        key2: const DiKey(name: 'port'),
        key1: text,
      );
      final expected = {text, const DiKey<int>(name: 'port')};
      expect(
        Component<String>.effect(
          dependency: base.mapN<String>((name, port) => '$name:$port'),
        ).requires,
        expected,
      );
      expect(
        Component<String>.effect(
          dependency: base.mapN<String>(
            (name, port) => '$name:$port',
            dispose: (_) {},
          ),
        ).requires,
        expected,
      );
      final published = Component<String>(
        dependency: base.mapN<String>((name, port) => '$name:$port'),
        key: text,
      );
      expect(published.requires, expected);
      expect(published.key, text);
    });

    test('composes with a record zip like any derived shape', () {
      // from: require_n_test.dart: composes with a record zip like any derived
      // shape
      final consumer = Dependency.require2<String, int>(
        key1: text,
        key2: count,
      );
      final other = Dependency.option<bool>(key: enabled);
      final both = Component<((String, int), Option<bool>)>.effect(
        dependency: (consumer, other).zip,
      );
      expect(both.requires, {text, count});
      expect(both.optional, {enabled});
    });

    test('has the shape of the zip of the same reads', () {
      final viaRecord = Dependency.require2<String, int>(
        key1: text,
        key2: count,
      );
      final viaZip = (
        Dependency.require<String>(key: text),
        Dependency.require<int>(key: count),
      ).zip;
      expect(viaRecord.requires, viaZip.requires);
      expect(viaRecord.optional, viaZip.optional);
    });
  });

  group('requireN activation', () {
    test('yields values in key order through mapN and a constructor', () async {
      // from: require_n_test.dart: yields values in key order through mapN and
      // a constructor
      final di = Scope(
        components: [
          Component<bool>.value(value: true, key: enabled),
          Component<int>.value(value: 8080, key: count),
          Component<String>.value(value: 'api', key: text),
          Component<Config>.effect(
            dependency: Dependency.require3<String, int, bool>(
              key1: text,
              key2: count,
              key3: enabled,
            ).mapN<Config>(Config.new),
          ),
        ],
      );
      rightOf(await di.run());
      final config = rightOf(di.nodes.last.value) as Config;

      expect(config.name, 'api');
      expect(config.port, 8080);
      expect(config.debug, isTrue);
      rightOf(await di.dispose());
    });

    test('keeps every arity from two to eight in order', () async {
      // from: require_n_test.dart: keeps every arity from two to eight in
      // order
      DiKey<int> k(int i) => DiKey<int>(name: 'k$i');
      final di = Scope(
        components: [
          for (var i = 1; i <= 8; i++)
            Component<int>.value(value: i, key: k(i)),
          Component<(int, int)>.effect(
            dependency: Dependency.require2<int, int>(key1: k(1), key2: k(2)),
          ),
          Component<(int, int, int)>.effect(
            dependency: Dependency.require3<int, int, int>(
              key1: k(1),
              key2: k(2),
              key3: k(3),
            ),
          ),
          Component<(int, int, int, int)>.effect(
            dependency: Dependency.require4<int, int, int, int>(
              key1: k(4),
              key2: k(3),
              key3: k(2),
              key4: k(1),
            ),
          ),
          Component<(int, int, int, int, int)>.effect(
            dependency: Dependency.require5<int, int, int, int, int>(
              key1: k(5),
              key2: k(4),
              key3: k(3),
              key4: k(2),
              key5: k(1),
            ),
          ),
          Component<(int, int, int, int, int, int)>.effect(
            dependency: Dependency.require6<int, int, int, int, int, int>(
              key1: k(1),
              key2: k(2),
              key3: k(3),
              key4: k(4),
              key5: k(5),
              key6: k(6),
            ),
          ),
          Component<(int, int, int, int, int, int, int)>.effect(
            dependency: Dependency.require7<int, int, int, int, int, int, int>(
              key1: k(7),
              key2: k(6),
              key3: k(5),
              key4: k(4),
              key5: k(3),
              key6: k(2),
              key7: k(1),
            ),
          ),
          Component<(int, int, int, int, int, int, int, int)>.effect(
            dependency:
                Dependency.require8<int, int, int, int, int, int, int, int>(
                  key1: k(1),
                  key2: k(2),
                  key3: k(3),
                  key4: k(4),
                  key5: k(5),
                  key6: k(6),
                  key7: k(7),
                  key8: k(8),
                ),
          ),
        ],
      );
      rightOf(await di.run());
      Object? at(int i) => rightOf(di.nodes[8 + i].value);
      expect(at(0), (1, 2));
      expect(at(1), (1, 2, 3));
      expect(at(2), (4, 3, 2, 1));
      expect(at(3), (5, 4, 3, 2, 1));
      expect(at(4), (1, 2, 3, 4, 5, 6));
      expect(at(5), (7, 6, 5, 4, 3, 2, 1));
      expect(at(6), (1, 2, 3, 4, 5, 6, 7, 8));
      rightOf(await di.dispose());
    });

    test('reads named keys of the same type separately', () async {
      // from: require_n_test.dart: reads named keys of the same type
      // separately
      const host = DiKey<String>(name: 'host');
      const user = DiKey<String>(name: 'user');
      final di = Scope(
        components: [
          Component<String>.value(value: 'localhost', key: host),
          Component<String>.value(value: 'admin', key: user),
          Component<String>.effect(
            dependency: Dependency.require2<String, String>(
              key1: host,
              key2: user,
            ).mapN<String>((host, user) => '$user@$host'),
          ),
        ],
      );
      rightOf(await di.run());
      expect(rightOf(di.nodes.last.value), 'admin@localhost');
      rightOf(await di.dispose());
    });

    test('a key without an argument is the key of its type', () async {
      final di = Scope(
        components: [
          Component<List<int>>.value(value: [1]),
          Component<Set<String>>.value(value: {'a'}),
          Component<String>.effect(
            dependency: Dependency.require2<List<int>, Set<String>>()
                .mapN<String>((a, b) => '$a $b'),
          ),
        ],
      );
      rightOf(await di.run());
      expect(rightOf(di.nodes.last.value), '[1] {a}');
      rightOf(await di.dispose());
    });

    test('stays dormant until every key is present', () async {
      // from: require_n_test.dart: stays dormant until every key is present
      var builds = 0;
      // Three nested ancestors each publish one key. They run after the
      // consumer scope, one by one.
      final di = Scope(components: []);
      final strings = di.kid(
        components: [Component<String>.value(value: 'api', key: text)],
      );
      final ints = strings.kid(
        components: [Component<int>.value(value: 1, key: count)],
      );
      final bools = ints.kid(
        components: [Component<bool>.value(value: false, key: enabled)],
      );
      final consumer = bools.kid(
        components: [
          Component<Config>.effect(
            dependency:
                Dependency.require3<String, int, bool>(
                  key1: text,
                  key2: count,
                  key3: enabled,
                ).mapN<Config>((name, port, debug) {
                  builds++;
                  return Config(name, port, debug);
                }),
          ),
        ],
      );
      rightOf(await consumer.run());
      final handle = consumer.nodes.single;
      expect(handle.isActive, isFalse);

      rightOf(await strings.run());
      expect(handle.isActive, isFalse);
      rightOf(await ints.run());
      expect(handle.isActive, isFalse);
      expect(builds, 0, reason: 'the body never runs on a partial set');
      final failure = leftOf(handle.value) as InactiveNodeFailure;
      expect(failure.missing, [enabled]);

      rightOf(await bools.run());
      expect(handle.isActive, isTrue);
      expect(builds, 1);
      expect((rightOf(handle.value) as Config).name, 'api');
      rightOf(await di.dispose());
    });

    test('a withdrawn key makes it dormant again and it reactivates', () async {
      // `later` sits between the consumer and the first publisher of the int
      // key. It runs only after the first publisher is withdrawn.
      // from: require_n_test.dart: a withdrawn key makes it dormant again and
      // it reactivates
      final top = Scope(
        components: [Component<String>.value(value: 'api', key: text)],
      );
      final later = top.kid(
        components: [Component<int>.value(value: 2, key: count)],
      );
      final first = later.kid(
        components: [Component<int>.value(value: 1, key: count)],
      );
      final consumer = first.kid(
        components: [
          Component<String>.effect(
            dependency: Dependency.require2<String, int>(
              key1: text,
              key2: count,
            ).mapN<String>((n, p) => '$n:$p'),
          ),
        ],
      );
      rightOf(await top.run());
      rightOf(await first.run());
      rightOf(await consumer.run());
      final handle = consumer.nodes.single;
      expect(rightOf(handle.value), 'api:1');

      rightOf(await first.nodes.single.dispose());
      expect(handle.isActive, isFalse);
      rightOf(await later.run());
      expect(rightOf(handle.value), 'api:2');
      rightOf(await top.dispose());
    });

    test('mapN with dispose releases before its publishers', () async {
      // from: require_n_test.dart: mapN with dispose releases before its
      // publishers
      final events = <String>[];
      const pool = DiKey<String>(name: 'pool');
      final di = Scope(
        components: [
          Component<String>(
            key: text,
            dependency: Dependency<String>(
              create: () => 'db',
              dispose: (_) => events.add('host'),
            ),
          ),
          Component<int>.value(value: 5, key: count),
          Component<String>(
            key: pool,
            dependency:
                Dependency.require2<String, int>(
                  key1: text,
                  key2: count,
                ).mapN<String>((name, size) {
                  events.add('open $name/$size');
                  return '$name/$size';
                }, dispose: (value) => events.add('close $value')),
          ),
        ],
      );
      rightOf(await di.run());
      final host = di.nodes.first;
      final poolNode = di.nodes.last;
      expect(rightOf(poolNode.value), 'db/5');
      expect(rightOf(di.get<String>(key: pool)), 'db/5');

      rightOf(await host.dispose());
      expect(poolNode.isActive, isFalse);
      expect(events, ['open db/5', 'close db/5', 'host']);

      rightOf(await di.dispose());
      expect(events.where((e) => e == 'close db/5'), hasLength(1));
    });

    test(
      'mapN with dispose releases once when its handle is disposed',
      () async {
        // from: require_n_test.dart: mapN with dispose releases once when its
        // handle is disposed
        var released = 0;
        final di = Scope(
          components: [
            Component<String>.value(value: 'a', key: text),
            Component<int>.value(value: 1, key: count),
            Component<String>.effect(
              dependency: Dependency.require2<String, int>(
                key1: text,
                key2: count,
              ).mapN<String>((a, b) => '$a$b', dispose: (_) => released++),
            ),
          ],
        );
        rightOf(await di.run());
        final handle = di.nodes.last;
        expect(released, 0);
        rightOf(await handle.dispose());
        rightOf(await handle.dispose());
        expect(released, 1);
        rightOf(await di.dispose());
      },
    );

    test('a missing key keeps mapN with dispose from creating', () async {
      // from: require_n_test.dart: a missing key keeps mapN with dispose from
      // creating
      var acquired = 0;
      // The parent declares the int key but never runs, so the key stays
      // absent.
      final pending = Scope(
        components: [Component<int>.value(value: 1, key: count)],
      );
      final di = pending.kid(
        components: [
          Component<String>.value(value: 'a', key: text),
          Component<String>.effect(
            dependency:
                Dependency.require2<String, int>(
                  key1: text,
                  key2: count,
                ).mapN<String>((a, b) {
                  acquired++;
                  return '$a$b';
                }, dispose: (_) {}),
          ),
        ],
      );
      rightOf(await di.run());
      final handle = di.nodes.last;
      expect(handle.isActive, isFalse);
      expect(acquired, 0);
      rightOf(await pending.dispose());
    });
  });
}
