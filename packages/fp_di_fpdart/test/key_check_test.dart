// The key checks of a component. The checks are values that `Scope.run`
// reports with the other pre-checks, not constructor throws. The unreachable
// key check also runs at the pre-check here, where fp_di raises it at the
// publication.
import 'dart:async';

import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

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

/// The ways to use [key] in a component. A null [key] selects the default key
/// of each read.
List<(String, Component<Object?>)> builders<T>(DiKey<T>? key) => [
  (
    'published key',
    Component<T>(
      dependency: Dependency<T>(create: _never),
      key: key ?? DiKey<T>(),
    ),
  ),
  (
    'required read',
    Component<int>(
      dependency: Dependency.require<T>(key: key).map((_) => 1),
      key: _out,
    ),
  ),
  (
    'optional read',
    Component<int>(
      dependency: Dependency.option<T>(key: key).map((_) => 1),
      key: _out,
    ),
  ),
  (
    'require2 default key',
    Component<int>(
      dependency: Dependency.require2<T, int>(
        key1: key,
        key2: _out,
      ).map((_) => 1),
      key: const DiKey<int>(name: 'sum'),
    ),
  ),
  (
    'Component.into read',
    Component<int>.into(
      key: _set,
      dependency: Dependency.require<T>(key: key).map((_) => 1),
    ),
  ),
];

/// The failures of the pre-check of [component], or none when the component
/// passes the checks. The scope of a passing component can run or fail in
/// another way, which the test ignores.
Future<List<DiFailure>> _failuresOf(Component<Object?> component) async {
  final scope = Scope(components: [component]);
  final exit = await scope.run();
  final failures = exit.match((cause) => cause.failures, (_) => <DiFailure>[]);
  rightOf(await scope.dispose());
  return failures;
}

Future<void> expectRejected<T>(String use, Component<Object?> build) async {
  final failures = await _failuresOf(build);
  expect(
    failures.whereType<UnnamedKeyFailure>(),
    isNotEmpty,
    reason: '$T as $use',
  );
  for (final failure in failures.whereType<UnnamedKeyFailure>()) {
    expect(failure.key.type, T, reason: '$T as $use');
    expect(failure.message, contains('${DiKey<T>()}'), reason: '$T as $use');
    expect(failure.message, contains('name'), reason: '$T as $use');
  }
}

Future<void> forEachCoreTypeAsync(Future<void> Function<T>() f) async {
  final calls = <Future<void> Function()>[
    f<bool>,
    f<bool?>,
    f<int>,
    f<int?>,
    f<double>,
    f<double?>,
    f<num>,
    f<num?>,
    f<String>,
    f<String?>,
    f<BigInt>,
    f<BigInt?>,
    f<DateTime>,
    f<DateTime?>,
    f<Duration>,
    f<Duration?>,
    f<Uri>,
    f<Uri?>,
    f<Symbol>,
    f<Symbol?>,
    f<Object>,
    f<Object?>,
  ];
  for (final call in calls) {
    await call();
  }
}

void main() {
  group('a key without a name', () {
    test('of a core value type is rejected in every use', () async {
      // from: key_name_test.dart: of a core value type is rejected in every
      // use
      await forEachCoreTypeAsync(<T>() async {
        for (final key in <DiKey<T>?>[null, DiKey<T>()]) {
          for (final (use, build) in builders<T>(key)) {
            await expectRejected<T>(use, build);
          }
        }
      });
    });

    test('of a core value type is rejected by Component.value', () async {
      // from: key_name_test.dart: of a core value type is rejected by
      // Component.value
      final failures = await _failuresOf(
        Component<int>.value(value: 1, key: DiKey<int>()),
      );
      expect(failures.single, isA<UnnamedKeyFailure>());
    });

    test('of a class type builds in every use', () async {
      // from: key_name_test.dart: of a class type builds in every use
      for (final key in <DiKey<Service>?>[null, DiKey<Service>()]) {
        for (final (use, build) in builders<Service>(key)) {
          final failures = await _failuresOf(build);
          expect(
            failures.whereType<UnnamedKeyFailure>(),
            isEmpty,
            reason: 'Service as $use',
          );
        }
      }
    });

    test('names the owner, the key, and the way to fix it', () async {
      final failures = await _failuresOf(
        Component<int>(
          debugLabel: 'pool',
          dependency: Dependency<int>(create: () => 1),
        ),
      );
      final failure = failures.single as UnnamedKeyFailure;
      expect(failure.owner, 'pool');
      expect(failure.key, DiKey<int>());
      expect(failure.message, contains("DiKey<int>(name: 'port')"));
    });

    test('reports each declaration, then the duplicates, then the undeclared '
        'keys, joined with Both', () async {
      final scope = Scope(
        components: [
          Component<String>(
            debugLabel: 'text',
            dependency: Dependency.require<String>(
              key: const DiKey<String>(name: 'gone'),
            ),
          ),
          Component<int>(
            debugLabel: 'one',
            dependency: Dependency<int>(create: () => 1),
          ),
          Component<int>(
            debugLabel: 'two',
            dependency: Dependency<int>(create: () => 2),
          ),
        ],
      );
      final cause = leftOf(await scope.run());
      expect(
        [for (final failure in cause.failures) failure.runtimeType],
        [
          UnnamedKeyFailure, // text publishes DiKey<String>
          UnnamedKeyFailure, // one publishes DiKey<int>
          UnnamedKeyFailure, // two publishes DiKey<int>
          DuplicateKeyFailure,
          UndeclaredKeyFailure,
        ],
      );
      expect(
        cause.fold<bool>(
          empty: () => false,
          fail: (_, _) => true,
          die: (_, _) => false,
          interrupt: (_) => false,
          then: (_, _) => false,
          both: (left, right) => true,
        ),
        isTrue,
      );
      expect(scope.phase, ScopePhase.declared);
    });

    test('of an effect and of a contribution is not checked', () async {
      final scope = Scope(
        components: [
          Component<int>.effect(dependency: Dependency<int>(create: () => 1)),
          Component<Object>.effect(
            dependency: Dependency<Object>(create: () => 1),
          ),
          Component<int>.into(
            key: _set,
            dependency: Dependency<int>(create: () => 2),
          ),
        ],
      );
      rightOf(await scope.run());
      rightOf(await scope.dispose());
    });
  });

  group('a named key', () {
    test('of a core value type builds in every use', () async {
      // from: key_name_test.dart: of a core value type builds in every use
      await forEachCoreTypeAsync(<T>() async {
        final key = DiKey<T>(name: 'n');
        for (final (use, build) in builders<T>(key)) {
          final failures = await _failuresOf(build);
          expect(
            failures.whereType<UnnamedKeyFailure>(),
            isEmpty,
            reason: '$T as $use',
          );
          expect(
            failures.whereType<InvalidComponentFailure>(),
            isEmpty,
            reason: '$T as $use',
          );
        }
      });
    });

    test('of a core value type builds with Component.value', () async {
      // from: key_name_test.dart: of a core value type builds with
      // Component.value
      final scope = Scope(
        components: [
          Component<int>.value(value: 1, key: const DiKey<int>(name: 'port')),
        ],
      );
      rightOf(await scope.run());
      rightOf(await scope.dispose());
    });

    test('a map entry of a core value type builds', () async {
      // from: key_name_test.dart: a map entry of a core value type builds
      final entry = const DiMapKey<int>(name: 'm').entryKey('a');
      final scope = Scope(
        components: [
          Component<int>(
            dependency: Dependency<int>(create: () => 1),
            key: entry,
          ),
          Component<int>(
            dependency: Dependency.require<int>(key: entry).map((v) => v),
            key: _out,
          ),
        ],
      );
      rightOf(await scope.run());
      rightOf(await scope.dispose());
    });
  });

  group('extension types over int', () {
    test('keep their own value in one scope', () async {
      // from: key_name_test.dart: keep their own value in one scope
      final scope = Scope(
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
      );
      rightOf(await scope.run());
      expect(rightOf(scope.get<PoolSize>(key: PoolSize.key)), 8);
      expect(rightOf(scope.get<Timeout>(key: Timeout.key)), 30);
      expect(
        rightOf(scope.get<String>(key: const DiKey<String>(name: 'summary'))),
        'pool=8 timeout=30',
      );
      rightOf(await scope.dispose());
    });

    test('have different keys although they erase to int', () {
      // from: key_name_test.dart: have different keys although they erase to
      // int
      expect(PoolSize.key, isNot(Timeout.key));
      expect(PoolSize.key.type, int);
      expect(Timeout.key.type, int);
    });
  });

  group('a key that no read can produce', () {
    test('a published Future key is an UnreachableKeyFailure at run', () async {
      final failures = await _failuresOf(
        Component<Future<int>>(
          key: const DiKey<Future<int>>(name: 'later'),
          dependency: Dependency<Future<int>>(
            create: () => Future<int>.value(1),
          ),
        ),
      );
      expect(failures.single, isA<UnreachableKeyFailure>());
    });

    test('a FutureOr key is rejected as unreachable', () async {
      // A component of FutureOr<String> publishes under a key that no lookup
      // can name. Silently publishing it would strand the binding.
      // from: regression_test.dart: a FutureOr key is rejected as unreachable
      final rejected = Scope(
        components: [
          Component<FutureOr<String>>(
            dependency: Dependency<FutureOr<String>>(create: () => 'inner'),
            key: DiKey<FutureOr<String>>(name: 'maybe'),
          ),
        ],
      );
      final failure = await failureOfRun(rejected);
      expect(
        failure,
        isA<UnreachableKeyFailure>().having(
          (f) => f.key,
          'key',
          const DiKey<FutureOr<String>>(name: 'maybe'),
        ),
      );
      expect(rejected.isInitialized, isFalse);
      expect(
        rejected.getOption<String>(key: const DiKey(name: 'text')),
        isA<None>(),
      );
      rightOf(await rejected.dispose());

      // The explicit type argument is the documented way out.
      final di = Scope(
        components: [
          Component<String>(
            dependency: Dependency<String>(create: () => 'inner'),
            key: const DiKey<String>(name: 'text'),
          ),
        ],
      );
      rightOf(await di.run());
      expect(rightOf(di.get<String>(key: const DiKey(name: 'text'))), 'inner');
      rightOf(await di.dispose());
    });

    test('isUnreachable and needsName state the rule on the key', () {
      expect(const DiKey<Future<int>>().isUnreachable, isTrue);
      expect(const DiKey<FutureOr<int>>(name: 'x').isUnreachable, isTrue);
      expect(const DiKey<int>().isUnreachable, isFalse);
      expect(const DiKey<int>().needsName, isTrue);
      expect(const DiKey<int>(name: 'x').needsName, isFalse);
      expect(const DiKey<List<int>>().needsName, isFalse);
      expect(DiKey<Service>().needsName, isFalse);
    });
  });
}
