import 'package:fp_di/fp_di.dart';
import 'package:test/test.dart';

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
      final fromCreate = Component.effect(
        dependency: Dependency(create: () => 1),
      );
      expect(fromCreate.requires, isEmpty);
      expect(fromCreate.optional, isEmpty);
      expect(fromCreate.key, isNull);

      final required = Component.effect(
        dependency: Dependency.require<Database>(),
      );
      expect(required.requires, {DiKey<Database>()});
      expect(required.optional, isEmpty);
      expect(required.key, isNull);

      final optional = Component.effect(
        dependency: Dependency.maybe<Database>(),
      );
      expect(optional.optional, {DiKey<Database>()});
      expect(optional.requires, isEmpty);

      expect(Dependency.require<Database>().requires, {DiKey<Database>()});
      expect(Dependency.maybe<Database>().optional, {DiKey<Database>()});
      expect(Dependency.maybe<Database>().requires, isEmpty);

      final published = Component.value(
        value: Database('a'),
        key: DiKey<Database>(),
      );
      expect(published.key, DiKey<Database>());
      expect(published.requires, isEmpty);
    });

    test('map and a name preserve the shape', () {
      final source = Component.effect(
        dependency: Dependency.require<Database>().map((db) => db.dsn),
        debugLabel: 'repo',
      );
      expect(source.requires, {DiKey<Database>()});
      expect(source.debugLabel, 'repo');
    });
  });

  group('a declared component waits instead of failing', () {
    test('registration order stops mattering', () async {
      // The consumer sits in a child scope that initializes first, while
      // nothing publishes Database.
      final di = Scope(
        module: Module(
          components: [
            Component.value(
              value: Database('dsn'),
              debugLabel: 'database',
              key: DiKey<Database>(),
            ),
          ],
        ),
      );
      final child = di.child(
        module: Module(
          components: [
            Component(
              dependency: Dependency.require<Database>().map(
                UserRepository.new,
              ),
              debugLabel: 'repository',
              key: DiKey<UserRepository>(),
            ),
          ],
        ),
      );
      await child.initialize();
      final repository = child.nodes.single;
      expect(repository.isActive, isFalse);
      expect(
        () => repository.value,
        throwsA(
          isA<InactiveNodeException>()
              .having((e) => e.missing, 'missing', [DiKey<Database>()])
              .having((e) => e.message, 'message', contains('DiKey<Database>')),
        ),
      );

      // Initializing the ancestor later activates the waiting component.
      await di.initialize();
      final database = di.nodes.single;
      expect(repository.isActive, isTrue);
      expect((repository.value as UserRepository).database.dsn, 'dsn');
      expect(child.get<UserRepository>().database.dsn, 'dsn');

      // Withdrawing it puts the consumer back to sleep, not into an error.
      await database.dispose();
      expect(repository.isActive, isFalse);

      await repository.dispose();
      await child.dispose();
      await di.dispose();
    });

    test('a Dependency component waits for its requirement', () async {
      final di = Scope(
        module: Module(
          components: [
            Component.value(value: Database('dsn'), key: DiKey<Database>()),
          ],
        ),
      );
      final child = di.child(
        module: Module(
          components: [
            Component.effect(
              dependency: Dependency.require<Database>().map((db) => db.dsn),
            ),
          ],
        ),
      );
      await child.initialize();
      final handle = child.nodes.single;
      expect(handle.isActive, isFalse);

      await di.initialize();
      expect(handle.value, 'dsn');

      await handle.dispose();
      await di.nodes.single.dispose();
      await child.dispose();
      await di.dispose();
    });

    test('a declared component never runs while unsatisfied', () async {
      var runs = 0;
      final di = Scope(
        module: Module(
          components: [
            Component.value(value: Database('dsn'), key: DiKey<Database>()),
          ],
        ),
      );
      final child = di.child(
        module: Module(
          components: [
            Component.effect(
              dependency: Dependency.require<Database>().map((db) {
                runs++;
                return db.dsn;
              }),
            ),
          ],
        ),
      );
      await child.initialize();
      final handle = child.nodes.single;
      expect(runs, 0, reason: 'no partial effect is staged');
      expect(handle.isActive, isFalse);

      await di.initialize();
      expect(runs, 1);
      expect(handle.value, 'dsn');

      await handle.dispose();
      await di.nodes.single.dispose();
      await child.dispose();
      await di.dispose();
    });
  });

  group('optional reads', () {
    test('a key read while absent still reloads when it appears', () async {
      final seen = <String?>[];
      final di = Scope(
        module: Module(
          components: [
            Component.value(value: Database('dsn'), key: DiKey<Database>()),
          ],
        ),
      );
      final child = di.child(
        module: Module(
          components: [
            Component.effect(
              dependency: Dependency.maybe<Database>().map((db) {
                seen.add(db?.dsn);
                return db?.dsn;
              }),
            ),
          ],
        ),
      );
      await child.initialize();
      final handle = child.nodes.single;
      expect(handle.isActive, isTrue, reason: 'optional does not gate');
      expect(seen, [null]);

      await di.initialize();
      final database = di.nodes.single;
      expect(seen, [null, 'dsn'], reason: 'absence is tracked too');
      expect(handle.value, 'dsn');

      await database.dispose();
      expect(seen, [null, 'dsn', null]);

      await handle.dispose();
      await child.dispose();
      await di.dispose();
    });
  });

  group('key', () {
    test('adds its key to the source shape', () {
      final repo = DiKey<String>(name: 'repo');
      final c = Component(
        dependency: Dependency.require<int>(
          key: const DiKey(name: 'count'),
        ).map((n) => 'repo$n'),
        key: repo,
      );
      expect(c.requires, {DiKey<int>(name: 'count')});
      expect(c.key, repo);

      final declared = Component(
        dependency: Dependency<String>(create: () => 'x'),
        key: DiKey<String>(name: 'text'),
      );
      expect(declared.key, DiKey<String>(name: 'text'));
    });

    test('publishes a created value and releases it on disposal', () async {
      final events = <String>[];
      final di = Scope(
        module: Module(
          components: [
            Component(
              dependency: Dependency<String>(
                create: () => 'db',
                dispose: (_) => events.add('released'),
              ),
              key: DiKey<String>(name: 'text'),
            ),
          ],
        ),
      );
      await di.initialize();
      final handle = di.nodes.single;
      expect(handle.value, 'db');
      expect(di.get<String>(key: const DiKey(name: 'text')), 'db');
      await handle.dispose();
      expect(
        di.maybeGet<String>(key: const DiKey(name: 'text')),
        isNull,
      );
      expect(events, ['released']);
      await di.dispose();
    });

    test('a failed composition publishes nothing', () async {
      final events = <String>[];
      final failing = Component(
        dependency:
            Dependency.require<int>(key: const DiKey(name: 'count'))
                .map<String>((_) {
                  events.add('acquired');
                  return 'staged';
                }, dispose: (_) => events.add('released'))
                .map<String>((_) => throw StateError('boom')),
        key: DiKey<String>(name: 'text'),
      );
      final di = Scope(
        module: Module(
          components: [
            Component.value(value: 1, key: DiKey<int>(name: 'count')),
            failing,
          ],
        ),
      );
      await expectLater(di.initialize(), throwsA(isA<ActivationException>()));
      expect(di.isInitialized, isFalse);
      expect(
        di.maybeGet<String>(key: const DiKey(name: 'text')),
        isNull,
      );
      expect(events, ['acquired', 'released']);
      await di.dispose();
    });

    test('a second local binding for the key is rejected', () async {
      final di = Scope(
        module: Module(
          components: [
            Component.value(
              value: 'existing',
              key: DiKey<String>(name: 'text'),
            ),
            Component(
              dependency: Dependency(create: () => 'dup'),
              key: DiKey<String>(name: 'text'),
            ),
          ],
        ),
      );
      await expectLater(di.initialize(), throwsA(isA<DuplicateKeyError>()));
      expect(di.isInitialized, isFalse);
      expect(
        di.maybeGet<String>(key: const DiKey(name: 'text')),
        isNull,
      );
      await di.dispose();
    });
  });
}
