// V-T-RT-LC-027: a key without a name of a core value type is rejected at
// construction (R-UC-RT-LC-025).
import 'package:fp_di/fp_di.dart';
import 'package:test/test.dart';

extension type const PoolSize(int value) implements int {
  static const key = DiKey<PoolSize>(name: 'PoolSize');
}

extension type const Timeout(int value) implements int {
  static const key = DiKey<Timeout>(name: 'Timeout');
}

final class Service {}

const _out = DiKey<int>(name: 'out');
const _set = DiSetKey<int>(name: 'numbers');

Never _never() => throw StateError('the test never creates a value');

/// Calls [f] with each core value type and its nullable form.
void forEachCoreType(void Function<T>() f) {
  f<bool>();
  f<bool?>();
  f<int>();
  f<int?>();
  f<double>();
  f<double?>();
  f<num>();
  f<num?>();
  f<String>();
  f<String?>();
  f<BigInt>();
  f<BigInt?>();
  f<DateTime>();
  f<DateTime?>();
  f<Duration>();
  f<Duration?>();
  f<Uri>();
  f<Uri?>();
  f<Symbol>();
  f<Symbol?>();
  f<Object>();
  f<Object?>();
}

/// The ways to use [key] in a `Component`. A null [key] selects the default
/// key of each read.
List<(String, Object Function())> builders<T>(DiKey<T>? key) => [
  (
    'published key',
    () => Component<T>(
      dependency: Dependency<T>(create: _never),
      key: key ?? DiKey<T>(),
    ),
  ),
  (
    'required read',
    () => Component<int>(
      dependency: Dependency.require<T>(key: key).map((_) => 1),
      key: _out,
    ),
  ),
  (
    'optional read',
    () => Component<int>(
      dependency: Dependency.maybe<T>(key: key).map((_) => 1),
      key: _out,
    ),
  ),
  (
    'Dependency1 default key',
    () => Component<int>(
      dependency: Dependency1<T, int>(key1: key, create: (_) => 1),
      key: _out,
    ),
  ),
  (
    'Component.into read',
    () => Component<int>.into(
      key: _set,
      dependency: Dependency.require<T>(key: key).map((_) => 1),
    ),
  ),
];

void expectRejected<T>(String use, Object Function() build) {
  expect(
    build,
    throwsA(
      isA<ArgumentError>()
          .having((e) => '$e', 'text', contains('${DiKey<T>()}'))
          .having((e) => '${e.message}', 'message', contains('name')),
    ),
    reason: '$T as $use',
  );
}

void main() {
  group('a key without a name', () {
    test('of a core value type is rejected in every use', () {
      forEachCoreType(<T>() {
        for (final key in <DiKey<T>?>[null, DiKey<T>()]) {
          for (final (use, build) in builders<T>(key)) {
            expectRejected<T>(use, build);
          }
        }
      });
    });

    test('of a core value type is rejected by Component.value', () {
      expect(
        () => Component.value(value: 1, key: DiKey<int>()),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('of a class type builds in every use', () {
      for (final key in <DiKey<Service>?>[null, DiKey<Service>()]) {
        for (final (use, build) in builders<Service>(key)) {
          expect(build, returnsNormally, reason: 'Service as $use');
        }
      }
    });
  });

  group('a named key', () {
    test('of a core value type builds in every use', () {
      forEachCoreType(<T>() {
        final key = DiKey<T>(name: 'n');
        for (final (use, build) in builders<T>(key)) {
          expect(build, returnsNormally, reason: '$T as $use');
        }
      });
    });

    test('of a core value type builds with Component.value', () {
      expect(
        () => Component.value(
          value: 1,
          key: const DiKey<int>(name: 'port'),
        ),
        returnsNormally,
      );
    });

    test('a map entry of a core value type builds', () {
      final entry = const DiMapKey<int>(name: 'm').entryKey('a');
      expect(
        () => Component<int>(
          dependency: Dependency<int>(create: () => 1),
          key: entry,
        ),
        returnsNormally,
      );
      expect(
        () => Component<int>(
          dependency: Dependency.require<int>(key: entry).map((v) => v),
          key: _out,
        ),
        returnsNormally,
      );
    });
  });

  group('extension types over int', () {
    test('keep their own value in one scope', () async {
      final scope = Scope(
        module: Module(
          components: [
            Component<PoolSize>(
              key: PoolSize.key,
              dependency: Dependency<PoolSize>(create: () => PoolSize(8)),
            ),
            Component<Timeout>(
              key: Timeout.key,
              dependency: Dependency<Timeout>(create: () => Timeout(30)),
            ),
            Component<String>(
              key: const DiKey<String>(name: 'summary'),
              dependency: Dependency.require2<PoolSize, Timeout>(
                key1: PoolSize.key,
                key2: Timeout.key,
              ).mapN((pool, timeout) => 'pool=$pool timeout=$timeout'),
            ),
          ],
        ),
      );
      await scope.initialize();
      expect(scope.get<PoolSize>(key: PoolSize.key), 8);
      expect(scope.get<Timeout>(key: Timeout.key), 30);
      expect(
        scope.get<String>(key: const DiKey<String>(name: 'summary')),
        'pool=8 timeout=30',
      );
      await scope.dispose();
    });

    test('have different keys although they erase to int', () {
      expect(PoolSize.key, isNot(Timeout.key));
      expect(PoolSize.key.type, int);
      expect(Timeout.key.type, int);
    });
  });
}
