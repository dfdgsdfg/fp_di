// The derived shape of a component, and a declared component that waits for
// its requirement instead of failing.
import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

final class Database {
  Database(this.dsn);
  final String dsn;
}

final class UserRepository {
  UserRepository(this.database);
  final Database database;
}

void main() {
  group('derived shape', () {
    test('primitives report their own keys', () {
      // from: algebra_test.dart: primitives report their own keys
      final fromCreate = Component<int>.effect(
        dependency: Dependency(create: () => 1),
      );
      expect(fromCreate.requires, isEmpty);
      expect(fromCreate.optional, isEmpty);
      expect(fromCreate.hasKey, isFalse);

      final required = Component<Database>.effect(
        dependency: Dependency.require<Database>(),
      );
      expect(required.requires, {DiKey<Database>()});
      expect(required.optional, isEmpty);
      expect(required.hasKey, isFalse);

      final optional = Component<Option<Database>>.effect(
        dependency: Dependency.option<Database>(),
      );
      expect(optional.optional, {DiKey<Database>()});
      expect(optional.requires, isEmpty);

      expect(Dependency.require<Database>().requires, {DiKey<Database>()});
      expect(Dependency.option<Database>().optional, {DiKey<Database>()});
      expect(Dependency.option<Database>().requires, isEmpty);

      final published = Component<Database>.value(
        value: Database('a'),
        key: DiKey<Database>(),
      );
      expect(published.key, DiKey<Database>());
      expect(published.requires, isEmpty);
    });

    test('map and a name preserve the shape', () {
      // from: algebra_test.dart: map and a name preserve the shape
      final source = Component<String>.effect(
        dependency: Dependency.require<Database>().map((db) => db.dsn),
        debugLabel: 'repo',
      );
      expect(source.requires, {DiKey<Database>()});
      expect(source.debugLabel, 'repo');
    });
  });

  group('a declared component waits instead of failing', () {
    test('registration order stops mattering', () async {
      // The consumer sits in a child scope that runs first, while nothing
      // publishes Database.
      // from: algebra_test.dart: registration order stops mattering
      final di = Scope(
        components: [
          Component<Database>.value(
            value: Database('dsn'),
            debugLabel: 'database',
            key: DiKey<Database>(),
          ),
        ],
      );
      final child = di.kid(
        components: [
          Component<UserRepository>(
            dependency: Dependency.require<Database>().map(UserRepository.new),
            debugLabel: 'repository',
            key: DiKey<UserRepository>(),
          ),
        ],
      );
      rightOf(await child.run());
      final repository = child.nodes.single;
      expect(repository.isActive, isFalse);
      expect(
        leftOf(repository.value),
        isA<InactiveNodeFailure>()
            .having((f) => f.missing, 'missing', [DiKey<Database>()])
            .having((f) => f.message, 'message', contains('DiKey<Database>')),
      );

      // Running the ancestor later activates the waiting component.
      rightOf(await di.run());
      final database = di.nodes.single;
      expect(repository.isActive, isTrue);
      expect((rightOf(repository.value) as UserRepository).database.dsn, 'dsn');
      expect(rightOf(child.get<UserRepository>()).database.dsn, 'dsn');

      // Withdrawing it puts the consumer back to sleep, not into an error.
      rightOf(await database.dispose());
      expect(repository.isActive, isFalse);

      rightOf(await repository.dispose());
      rightOf(await child.dispose());
      rightOf(await di.dispose());
    });

    test('a Dependency component waits for its requirement', () async {
      // from: algebra_test.dart: a Dependency component waits for its
      // requirement
      final di = Scope(
        components: [
          Component<Database>.value(
            value: Database('dsn'),
            key: DiKey<Database>(),
          ),
        ],
      );
      final child = di.kid(
        components: [
          Component<String>.effect(
            dependency: Dependency.require<Database>().map((db) => db.dsn),
          ),
        ],
      );
      rightOf(await child.run());
      final handle = child.nodes.single;
      expect(handle.isActive, isFalse);

      rightOf(await di.run());
      expect(rightOf(handle.value), 'dsn');

      rightOf(await handle.dispose());
      rightOf(await di.nodes.single.dispose());
      rightOf(await child.dispose());
      rightOf(await di.dispose());
    });

    test('a declared component never runs while unsatisfied', () async {
      // from: algebra_test.dart: a declared component never runs while
      // unsatisfied
      var runs = 0;
      final di = Scope(
        components: [
          Component<Database>.value(
            value: Database('dsn'),
            key: DiKey<Database>(),
          ),
        ],
      );
      final child = di.kid(
        components: [
          Component<String>.effect(
            dependency: Dependency.require<Database>().map((db) {
              runs++;
              return db.dsn;
            }),
          ),
        ],
      );
      rightOf(await child.run());
      final handle = child.nodes.single;
      expect(runs, 0, reason: 'no partial effect is staged');
      expect(handle.isActive, isFalse);

      rightOf(await di.run());
      expect(runs, 1);
      expect(rightOf(handle.value), 'dsn');

      rightOf(await handle.dispose());
      rightOf(await di.nodes.single.dispose());
      rightOf(await child.dispose());
      rightOf(await di.dispose());
    });
  });

  group('optional reads', () {
    test('a key read while absent still reloads when it appears', () async {
      // from: algebra_test.dart: a key read while absent still reloads when it
      // appears
      final seen = <String?>[];
      final di = Scope(
        components: [
          Component<Database>.value(
            value: Database('dsn'),
            key: DiKey<Database>(),
          ),
        ],
      );
      final child = di.kid(
        components: [
          Component<String?>.effect(
            dependency: Dependency.option<Database>().map((db) {
              final dsn = db.toNullable()?.dsn;
              seen.add(dsn);
              return dsn;
            }),
          ),
        ],
      );
      rightOf(await child.run());
      final handle = child.nodes.single;
      expect(handle.isActive, isTrue, reason: 'optional does not gate');
      expect(seen, [null]);

      rightOf(await di.run());
      final database = di.nodes.single;
      expect(seen, [null, 'dsn'], reason: 'absence is tracked too');
      expect(rightOf(handle.value), 'dsn');

      rightOf(await database.dispose());
      expect(seen, [null, 'dsn', null]);

      rightOf(await handle.dispose());
      rightOf(await child.dispose());
      rightOf(await di.dispose());
    });
  });

  group('key', () {
    test('adds its key to the source shape', () {
      // from: algebra_test.dart: adds its key to the source shape
      final repo = DiKey<String>(name: 'repo');
      final c = Component<String>(
        dependency: Dependency.require<int>(
          key: const DiKey(name: 'count'),
        ).map((n) => 'repo$n'),
        key: repo,
      );
      expect(c.requires, {const DiKey<int>(name: 'count')});
      expect(c.key, repo);

      final declared = Component<String>(
        dependency: Dependency<String>(create: () => 'x'),
        key: DiKey<String>(name: 'text'),
      );
      expect(declared.key, DiKey<String>(name: 'text'));
    });

    test('publishes a created value and releases it on disposal', () async {
      // from: algebra_test.dart: publishes a created value and releases it on
      // disposal
      final events = <String>[];
      final di = Scope(
        components: [
          Component<String>(
            dependency: Dependency<String>(
              create: () => 'db',
              dispose: (_) => events.add('released'),
            ),
            key: DiKey<String>(name: 'text'),
          ),
        ],
      );
      rightOf(await di.run());
      final handle = di.nodes.single;
      expect(rightOf(handle.value), 'db');
      expect(rightOf(di.get<String>(key: const DiKey(name: 'text'))), 'db');
      rightOf(await handle.dispose());
      expect(di.getOption<String>(key: const DiKey(name: 'text')), isA<None>());
      expect(events, ['released']);
      rightOf(await di.dispose());
    });

    test('a failed composition publishes nothing', () async {
      // from: algebra_test.dart: a failed composition publishes nothing
      final events = <String>[];
      final failing = Component<String>(
        dependency: Dependency.require<int>(key: const DiKey(name: 'count'))
            .map<String>((_) {
              events.add('acquired');
              return 'staged';
            }, dispose: (_) => events.add('released'))
            .map<String>((_) => throw StateError('boom')),
        key: DiKey<String>(name: 'text'),
      );
      final di = Scope(
        components: [
          Component<int>.value(value: 1, key: DiKey<int>(name: 'count')),
          failing,
        ],
      );
      expect(await failureOfRun(di), isA<ActivationFailure>());
      expect(di.isInitialized, isFalse);
      expect(di.getOption<String>(key: const DiKey(name: 'text')), isA<None>());
      expect(events, ['acquired', 'released']);
      rightOf(await di.dispose());
    });

    test('a second local binding for the key is rejected', () async {
      // from: algebra_test.dart: a second local binding for the key is
      // rejected
      final di = Scope(
        components: [
          Component<String>.value(
            value: 'existing',
            key: DiKey<String>(name: 'text'),
          ),
          Component<String>(
            dependency: Dependency(create: () => 'dup'),
            key: DiKey<String>(name: 'text'),
          ),
        ],
      );
      expect(await failureOfRun(di), isA<DuplicateKeyFailure>());
      expect(di.isInitialized, isFalse);
      expect(di.getOption<String>(key: const DiKey(name: 'text')), isA<None>());
      rightOf(await di.dispose());
    });
  });
}
