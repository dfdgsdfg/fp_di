import 'package:fp_di/fp_di.dart';
import 'package:test/test.dart';

final class Api {
  const Api(this.name);
  final String name;
}

final class Clock {
  const Clock(this.now);
  final int now;
}

final class Repository {
  Repository(this.api, this.clock);
  final Api api;
  final Clock clock;
}

Module _inputs(List<String> log) => Module(
  components: [
    Component<Api>(
      key: DiKey<Api>(),
      dependency: Dependency(
        create: () {
          log.add('up api');
          return const Api('main');
        },
        dispose: (_) => log.add('down api'),
      ),
    ),
    Component<Clock>.value(key: DiKey<Clock>(), value: const Clock(7)),
  ],
);

void main() {
  group('Dependency1 to Dependency8', () {
    test('derive the shape of the matching requireN', () {
      final dependency = Dependency2<Api, Clock, Repository>(
        key1: const DiKey<Api>(name: 'remote'),
        create: Repository.new,
      );
      expect(dependency.requires, {
        const DiKey<Api>(name: 'remote'),
        DiKey<Clock>(),
      });
      expect(dependency.optional, isEmpty);
      expect(Dependency1<Api, String>(create: (api) => api.name).requires, {
        DiKey<Api>(),
      });
    });

    test('infer the type arguments from a constructor tear-off', () {
      final dependency = Dependency2(create: Repository.new);
      expect(dependency, isA<Dependency2<Api, Clock, Repository>>());
      expect(dependency, isA<Dependency<Repository>>());
    });

    test('without dispose, create is a plain step', () async {
      final log = <String>[];
      final di = Scope(module: _inputs(log));
      final feature = di.child(
        module: Module(
          components: [
            Component<Repository>(
              key: DiKey<Repository>(),
              dependency: Dependency2(create: Repository.new),
            ),
          ],
        ),
      );
      await di.initialize();
      await feature.initialize();
      final repository = feature.get<Repository>();
      expect(repository.api.name, 'main');
      expect(repository.clock.now, 7);
      await di.dispose();
      expect(log, ['up api', 'down api']);
    });

    test('with dispose, the value releases before its publishers', () async {
      final log = <String>[];
      final di = Scope(module: _inputs(log));
      final feature = di.child(
        module: Module(
          components: [
            Component<Repository>(
              key: DiKey<Repository>(),
              dependency: Dependency2<Api, Clock, Repository>(
                create: (api, clock) {
                  log.add('up repository');
                  return Repository(api, clock);
                },
                dispose: (_) => log.add('down repository'),
              ),
            ),
          ],
        ),
      );
      await di.initialize();
      await feature.initialize();
      await di.dispose();
      expect(log, ['up api', 'up repository', 'down repository', 'down api']);
    });

    test('a failing create rolls back and publishes nothing', () async {
      final log = <String>[];
      final di = await Scope(module: _inputs(log)).initialize();
      final feature = di.child(
        module: Module(
          components: [
            Component<String>(
              key: DiKey<String>(name: 'text'),
              dependency: Dependency1<Api, String>(
                create: (_) => throw StateError('boom'),
                dispose: (_) => log.add('down text'),
              ),
            ),
          ],
        ),
      );
      await expectLater(
        feature.initialize(),
        throwsA(isA<ActivationException>()),
      );
      expect(feature.isInitialized, isFalse);
      expect(feature.maybeGet<String>(key: const DiKey(name: 'text')), isNull);
      expect(log, ['up api'], reason: 'nothing was created to release');
      await di.dispose();
    });

    test('Dependency8 passes eight values in key order', () async {
      final di = Scope(
        module: Module(
          components: [
            for (var i = 1; i <= 8; i++)
              Component<int>.value(
                key: DiKey<int>(name: 'k$i'),
                value: i,
              ),
            Component<List<int>>(
              key: DiKey<List<int>>(),
              dependency:
                  Dependency8<
                    int,
                    int,
                    int,
                    int,
                    int,
                    int,
                    int,
                    int,
                    List<int>
                  >(
                    key1: const DiKey<int>(name: 'k1'),
                    key2: const DiKey<int>(name: 'k2'),
                    key3: const DiKey<int>(name: 'k3'),
                    key4: const DiKey<int>(name: 'k4'),
                    key5: const DiKey<int>(name: 'k5'),
                    key6: const DiKey<int>(name: 'k6'),
                    key7: const DiKey<int>(name: 'k7'),
                    key8: const DiKey<int>(name: 'k8'),
                    create: (a, b, c, d, e, f, g, h) => [
                      a,
                      b,
                      c,
                      d,
                      e,
                      f,
                      g,
                      h,
                    ],
                  ),
            ),
          ],
        ),
      );
      await di.initialize();
      expect(di.get<List<int>>(), [1, 2, 3, 4, 5, 6, 7, 8]);
      await di.dispose();
    });

    test('chains like any Dependency', () async {
      final log = <String>[];
      final di = Scope(module: _inputs(log));
      final feature = di.child(
        module: Module(
          components: [
            Component<String>(
              key: DiKey<String>(name: 'text'),
              dependency: Dependency1<Api, String>(
                create: (api) => api.name,
              ).map((name) => name.toUpperCase()),
            ),
          ],
        ),
      );
      await di.initialize();
      await feature.initialize();
      expect(feature.get<String>(key: const DiKey(name: 'text')), 'MAIN');
      await di.dispose();
    });
  });
}
