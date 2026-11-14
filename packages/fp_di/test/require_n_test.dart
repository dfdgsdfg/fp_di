import 'package:fp_di/fp_di.dart';
import 'package:test/test.dart';

final class Config {
  Config(this.name, this.port, this.debug);
  final String name;
  final int port;
  final bool debug;
}

void main() {
  group('requireN shape', () {
    test('is the derived set of keys with no declaration', () {
      final shape = Component.effect(
        dependency: Dependency.require3<String, int, bool>(
          key1: const DiKey(name: 'text'),
          key2: const DiKey(name: 'count'),
          key3: const DiKey(name: 'enabled'),
        ),
      );
      expect(shape.requires, {
        DiKey<String>(name: 'text'),
        DiKey<int>(name: 'count'),
        DiKey<bool>(name: 'enabled'),
      });
      expect(shape.optional, isEmpty);
      expect(shape.key, isNull);
      expect(shape.reads, shape.requires);
      expect(shape.debugLabel, isNull);
    });

    test('uses named keys where given', () {
      final shape = Component.effect(
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
      final base = Dependency.require2<String, int>(
        key2: const DiKey(name: 'port'),
        key1: const DiKey(name: 'text'),
      );
      final expected = {
        DiKey<String>(name: 'text'),
        const DiKey<int>(name: 'port'),
      };
      expect(
        Component.effect(
          dependency: base.mapN((name, port) => '$name:$port'),
        ).requires,
        expected,
      );
      expect(
        Component.effect(
          dependency: base.mapN((name, port) => '$name:$port', dispose: (_) {}),
        ).requires,
        expected,
      );
      final published = Component(
        dependency: base.mapN((name, port) => '$name:$port'),
        key: DiKey<String>(name: 'text'),
      );
      expect(published.requires, expected);
      expect(published.key, DiKey<String>(name: 'text'));
    });

    test('composes with a record zip like any derived shape', () {
      final consumer = Dependency.require2<String, int>(
        key1: const DiKey(name: 'text'),
        key2: const DiKey(name: 'count'),
      );
      final other = Dependency.maybe<bool>(
        key: const DiKey(name: 'enabled'),
      );
      final both = Component.effect(dependency: (consumer, other).zip);
      expect(both.requires, {
        DiKey<String>(name: 'text'),
        DiKey<int>(name: 'count'),
      });
      expect(both.optional, {DiKey<bool>(name: 'enabled')});
      expect(both.key, isNull);
    });
  });

  group('requireN activation', () {
    test('yields values in key order through mapN and a constructor', () async {
      final di = Scope(
        module: Module(
          components: [
            Component.value(
              value: true,
              key: DiKey<bool>(name: 'enabled'),
            ),
            Component.value(
              value: 8080,
              key: DiKey<int>(name: 'count'),
            ),
            Component.value(
              value: 'api',
              key: DiKey<String>(name: 'text'),
            ),
            Component.effect(
              dependency: Dependency.require3<String, int, bool>(
                key1: const DiKey(name: 'text'),
                key2: const DiKey(name: 'count'),
                key3: const DiKey(name: 'enabled'),
              ).mapN(Config.new),
            ),
          ],
        ),
      );
      await di.initialize();
      final config = di.nodes.last.value! as Config;

      expect(config.name, 'api');
      expect(config.port, 8080);
      expect(config.debug, isTrue);
      await di.dispose();
    });

    test('keeps every arity from two to eight in order', () async {
      DiKey<int> k(int i) => DiKey<int>(name: 'k$i');
      final di = Scope(
        module: Module(
          components: [
            for (var i = 1; i <= 8; i++)
              Component.value(
                value: i,
                key: DiKey<int>(name: 'k$i'),
              ),
            Component.effect(
              dependency: Dependency.require2<int, int>(key1: k(1), key2: k(2)),
            ),
            Component.effect(
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
            Component.effect(
              dependency: Dependency.require5<int, int, int, int, int>(
                key1: k(5),
                key2: k(4),
                key3: k(3),
                key4: k(2),
                key5: k(1),
              ),
            ),
          ],
        ),
      );
      await di.initialize();
      final two = di.nodes[8];
      final eight = di.nodes[9];
      final five = di.nodes[10];
      expect(two.value, (1, 2));
      expect(eight.value, (1, 2, 3, 4, 5, 6, 7, 8));
      expect(five.value, (5, 4, 3, 2, 1));
      await di.dispose();
    });

    test('reads named keys of the same type separately', () async {
      final di = Scope(
        module: Module(
          components: [
            Component.value(
              value: 'localhost',
              key: const DiKey<String>(name: 'host'),
            ),
            Component.value(
              value: 'admin',
              key: const DiKey<String>(name: 'user'),
            ),
            Component.effect(
              dependency: Dependency.require2<String, String>(
                key1: const DiKey(name: 'host'),
                key2: const DiKey(name: 'user'),
              ).mapN((host, user) => '$user@$host'),
            ),
          ],
        ),
      );
      await di.initialize();
      expect(di.nodes.last.value, 'admin@localhost');
      await di.dispose();
    });

    test('stays dormant until every key is present', () async {
      var builds = 0;
      // Three nested ancestors each publish one key. They initialize after
      // the consumer scope, one by one.
      final di = Scope();
      final strings = di.child(
        module: Module(
          components: [
            Component.value(
              value: 'api',
              key: DiKey<String>(name: 'text'),
            ),
          ],
        ),
      );
      final ints = strings.child(
        module: Module(
          components: [
            Component.value(value: 1, key: DiKey<int>(name: 'count')),
          ],
        ),
      );
      final bools = ints.child(
        module: Module(
          components: [
            Component.value(
              value: false,
              key: DiKey<bool>(name: 'enabled'),
            ),
          ],
        ),
      );
      final consumer = bools.child(
        module: Module(
          components: [
            Component.effect(
              dependency:
                  Dependency.require3<String, int, bool>(
                    key1: const DiKey(name: 'text'),
                    key2: const DiKey(name: 'count'),
                    key3: const DiKey(name: 'enabled'),
                  ).mapN((name, port, debug) {
                    builds++;
                    return Config(name, port, debug);
                  }),
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
      expect(handle.isActive, isFalse);
      expect(builds, 0, reason: 'the body never runs on a partial set');
      expect(
        () => handle.value,
        throwsA(
          isA<InactiveNodeException>().having(
            (e) => e.missing,
            'missing',
            [DiKey<bool>(name: 'enabled')],
          ),
        ),
      );

      await bools.initialize();
      expect(handle.isActive, isTrue);
      expect(builds, 1);
      expect((handle.value! as Config).name, 'api');
      await di.dispose();
    });

    test('a withdrawn key makes it dormant again and it reactivates', () async {
      // `later` sits between the consumer and the first publisher of the int
      // key. It initializes only after the first publisher is withdrawn.
      final top = Scope(
        module: Module(
          components: [
            Component.value(
              value: 'api',
              key: DiKey<String>(name: 'text'),
            ),
          ],
        ),
      );
      final later = top.child(
        module: Module(
          components: [
            Component.value(value: 2, key: DiKey<int>(name: 'count')),
          ],
        ),
      );
      final first = later.child(
        module: Module(
          components: [
            Component.value(value: 1, key: DiKey<int>(name: 'count')),
          ],
        ),
      );
      final consumer = first.child(
        module: Module(
          components: [
            Component.effect(
              dependency: Dependency.require2<String, int>(
                key1: const DiKey(name: 'text'),
                key2: const DiKey(name: 'count'),
              ).mapN((n, p) => '$n:$p'),
            ),
          ],
        ),
      );
      await top.initialize();
      await first.initialize();
      await consumer.initialize();
      final handle = consumer.nodes.single;
      expect(handle.value, 'api:1');

      await first.nodes.single.dispose();
      expect(handle.isActive, isFalse);
      await later.initialize();
      expect(handle.value, 'api:2');
      await top.dispose();
    });

    test('mapN with dispose releases before its publishers', () async {
      final events = <String>[];
      final di = Scope(
        module: Module(
          components: [
            Component(
              dependency: Dependency(
                create: () => 'db',
                dispose: (_) => events.add('host'),
              ),
              key: DiKey<String>(name: 'text'),
            ),
            Component.value(value: 5, key: DiKey<int>(name: 'count')),
            Component(
              dependency:
                  Dependency.require2<String, int>(
                    key1: const DiKey(name: 'text'),
                    key2: const DiKey(name: 'count'),
                  ).mapN((name, size) {
                    events.add('open $name/$size');
                    return '$name/$size';
                  }, dispose: (value) => events.add('close $value')),
              key: const DiKey<String>(name: 'pool'),
            ),
          ],
        ),
      );
      await di.initialize();
      final host = di.nodes.first;
      final pool = di.nodes.last;
      expect(pool.value, 'db/5');
      expect(
        di.get<String>(key: const DiKey<String>(name: 'pool')),
        'db/5',
      );

      await host.dispose();
      expect(pool.isActive, isFalse);
      expect(events, ['open db/5', 'close db/5', 'host']);

      await di.dispose();
      expect(events.where((e) => e == 'close db/5'), hasLength(1));
    });

    test(
      'mapN with dispose releases once when its handle is disposed',
      () async {
        var released = 0;
        final di = Scope(
          module: Module(
            components: [
              Component.value(
                value: 'a',
                key: DiKey<String>(name: 'text'),
              ),
              Component.value(value: 1, key: DiKey<int>(name: 'count')),
              Component.effect(
                dependency: Dependency.require2<String, int>(
                  key1: const DiKey(name: 'text'),
                  key2: const DiKey(name: 'count'),
                ).mapN((a, b) => '$a$b', dispose: (_) => released++),
              ),
            ],
          ),
        );
        await di.initialize();
        final handle = di.nodes.last;
        expect(released, 0);
        await handle.dispose();
        await handle.dispose();
        expect(released, 1);
        await di.dispose();
      },
    );

    test('a missing key keeps mapN with dispose from creating', () async {
      var acquired = 0;
      // Declares the int key but never initializes, so the key stays absent.
      final pending = Scope(
        module: Module(
          components: [
            Component.value(value: 1, key: DiKey<int>(name: 'count')),
          ],
        ),
      );
      final di = pending.child(
        module: Module(
          components: [
            Component.value(
              value: 'a',
              key: DiKey<String>(name: 'text'),
            ),
            Component.effect(
              dependency:
                  Dependency.require2<String, int>(
                    key1: const DiKey(name: 'text'),
                    key2: const DiKey(name: 'count'),
                  ).mapN((a, b) {
                    acquired++;
                    return '$a$b';
                  }, dispose: (_) {}),
            ),
          ],
        ),
      );
      await di.initialize();
      final handle = di.nodes.last;
      expect(handle.isActive, isFalse);
      expect(acquired, 0);
      await pending.dispose();
    });
  });
}
