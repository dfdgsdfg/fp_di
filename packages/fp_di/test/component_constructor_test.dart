import 'dart:async';

import 'package:fp_di/fp_di.dart';
import 'package:test/test.dart';

final class Foo {
  Foo(this.id);
  final int id;
}

abstract interface class Database {
  String get dsn;
}

final class PgDatabase implements Database {
  PgDatabase(this.dsn);
  @override
  final String dsn;
}

const _dsnKey = DiKey<String>(name: 'dsn');

/// A consumer of the default key of [Database].
Component<String> _dsnReader() => Component<String>(
  dependency: Dependency.require<Database>().map((db) => db.dsn),
  key: _dsnKey,
);

Matcher _namesEffect() => throwsA(
  isA<ArgumentError>().having(
    (e) => e.message.toString(),
    'message',
    contains('Component.effect'),
  ),
);

void main() {
  group('Component constructor', () {
    test('rejects a key whose type is not the type argument', () {
      // Inference widens the type argument to Object, so this compiles.
      expect(
        () => Component(
          dependency: Dependency(create: () => Foo(1)),
          key: DiKey<String>(name: 'text'),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('Component<String>'),
          ),
        ),
      );
      expect(
        () => Component.value(
          value: Foo(1),
          key: DiKey<String>(name: 'text'),
        ),
        throwsArgumentError,
      );
    });

    test('infers a port type from the key, also inside a module', () async {
      final module = Module(
        components: [
          // No type argument: Dart infers Component<Object> from Foo and the
          // key, so the port key Object binds a Foo.
          Component(
            dependency: Dependency(create: () => Foo(7)),
            key: DiKey<Object>(name: 'port'),
          ),
          Component(
            dependency: Dependency.require<Object>(
              key: const DiKey<Object>(name: 'port'),
            ).map((port) => (port as Foo).id),
            key: DiKey<int>(name: 'count'),
          ),
        ],
      );
      final di = await Scope(module: module).initialize();
      expect(di.get<int>(key: const DiKey(name: 'count')), 7);
      expect(di.nodes.first, isA<ComponentNode<Object?>>());
      await di.dispose();
    });

    test('a key of the inferred type passes without a type argument', () {
      final component = Component(
        dependency: Dependency(create: () => Foo(1)),
        key: DiKey<Foo>(),
      );
      expect(component, isA<Component<Foo>>());
      expect(component.key, DiKey<Foo>());
    });

    test('does not acquire when the component is built', () {
      var calls = 0;
      final published = Component<Foo>(
        dependency: Dependency(create: () => Foo(++calls)),
        key: DiKey<Foo>(),
      );
      expect(calls, 0);
      expect(published.key, DiKey<Foo>());
      expect(calls, 0, reason: 'reading the shape does not acquire');
    });

    test(
      'a module of dependencies constructs nothing before initialize',
      () async {
        var calls = 0;
        final module = Module(
          components: [
            Component<Foo>(
              dependency: Dependency(create: () => Foo(++calls)),
              key: DiKey<Foo>(),
            ),
            Component<String>(
              dependency: Dependency(
                create: () {
                  calls++;
                  return 'x';
                },
              ),
              key: DiKey<String>(name: 'text'),
            ),
          ],
        );
        expect(calls, 0);
        final di = Scope(module: module);
        expect(calls, 0, reason: 'declaring a scope acquires nothing');
        await di.initialize();
        expect(calls, 2);
        expect(di.get<Foo>().id, 1);
        await di.dispose();
      },
    );

    test('acquires on initialize and yields the value', () async {
      var calls = 0;
      final di = Scope(
        module: Module(
          components: [
            Component<Foo>(dependency: Dependency(create: () => Foo(++calls))),
          ],
        ),
      );
      await di.initialize();
      final handle = di.nodes.single;
      expect(calls, 1);
      expect((handle.value! as Foo).id, 1);
      expect(handle.isActive, isTrue);
      await di.dispose();
    });

    test('has an empty derived shape', () {
      final component = Component<int>.effect(
        dependency: Dependency(create: () => 1),
      );
      expect(component.requires, isEmpty);
      expect(component.optional, isEmpty);
      expect(component.key, isNull);
      expect(component.reads, isEmpty);
      expect(component.debugLabel, isNull);
    });

    test('supports an asynchronous acquire', () async {
      final gate = Completer<Foo>();
      final di = Scope(
        module: Module(
          components: [
            Component<Foo>(
              dependency: Dependency(create: () => gate.future),
              key: DiKey<Foo>(),
            ),
          ],
        ),
      );
      var done = false;
      final pending = di.initialize().then((_) => done = true);
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse, reason: 'initialize waits for acquire');
      expect(di.maybeGet<Foo>(), isNull);
      gate.complete(Foo(7));
      await pending;
      expect((di.nodes.single.value! as Foo).id, 7);
      expect(di.get<Foo>().id, 7);
      await di.dispose();
    });

    test(
      'an asynchronous failure fails initialize and leaves no node',
      () async {
        final di = Scope(
          module: Module(
            components: [
              Component<Foo>(
                dependency: Dependency(
                  create: () async => throw StateError('boom'),
                ),
                key: DiKey<Foo>(),
              ),
            ],
          ),
        );
        await expectLater(di.initialize(), throwsA(isA<ActivationException>()));
        expect(di.isInitialized, isFalse);
        expect(di.maybeGet<Foo>(), isNull);
        await di.dispose();
      },
    );

    test('runs again on each reactivation and not otherwise', () async {
      var calls = 0;
      // The consumer sits in a child scope. Two ancestors initialize later
      // and publish the int key one after the other.
      final di = Scope();
      final outer = di.child(
        module: Module(
          components: [
            Component<int>.value(value: 2, key: DiKey<int>(name: 'count')),
          ],
        ),
      );
      final inner = outer.child(
        module: Module(
          components: [
            Component<int>.value(value: 1, key: DiKey<int>(name: 'count')),
          ],
        ),
      );
      final leaf = inner.child(
        module: Module(
          components: [
            Component(
              dependency: Dependency.require<int>(
                key: const DiKey(name: 'count'),
              ).map((n) => Foo(++calls * 100 + n)),
              key: DiKey<Foo>(),
            ),
            Component.effect(dependency: Dependency(create: () => 0)),
          ],
        ),
      );
      await leaf.initialize();
      final handle = leaf.nodes.first;
      expect(calls, 0, reason: 'dormant: acquire has not run');
      expect(handle.isActive, isFalse);

      await inner.initialize();
      expect(calls, 1);
      expect(leaf.get<Foo>().id, 101);
      // An unrelated withdrawal does not acquire again.
      await leaf.nodes.last.dispose();
      expect(calls, 1);

      await inner.nodes.single.dispose();
      expect(handle.isActive, isFalse);
      await outer.initialize();
      expect(calls, 2);
      expect(leaf.get<Foo>().id, 202);
      await di.dispose();
    });

    test('releases on teardown and acquires again on reuse', () async {
      final log = <String>[];
      var calls = 0;
      final component = Component<Foo>(
        dependency: Dependency(
          create: () {
            log.add('acquire ${++calls}');
            return Foo(calls);
          },
          dispose: (foo) => log.add('release ${foo.id}'),
        ),
        key: DiKey<Foo>(),
      );
      final di = Scope();
      final first = di.child(module: Module(components: [component]));
      await first.initialize();
      expect(di.maybeGet<Foo>(), isNull);
      expect(first.get<Foo>().id, 1);
      await first.dispose();
      final second = di.child(module: Module(components: [component]));
      await second.initialize();
      expect(
        second.get<Foo>().id,
        2,
        reason: 'a new scope for the same description creates a new value',
      );
      await second.dispose();
      expect(log, ['acquire 1', 'release 1', 'acquire 2', 'release 2']);
      await di.dispose();
    });

    test('a dependency without a dispose releases nothing', () async {
      final log = <String>[];
      final di = Scope(
        module: Module(
          components: [
            Component<Foo>.effect(dependency: Dependency(create: () => Foo(1))),
            Component<int>.effect(
              dependency: Dependency(create: () => Foo(2)).map((foo) => foo.id),
            ),
            Component<int>.effect(
              dependency: Dependency(
                create: () => Foo(3),
              ).map((foo) => foo.id, dispose: (id) => log.add('release $id')),
            ),
          ],
        ),
      );
      await di.initialize();
      final [plain, mapped, owned] = di.nodes;
      expect((plain.value! as Foo).id, 1);
      expect(mapped.value, 2);
      expect(owned.value, 3);
      await plain.dispose();
      await mapped.dispose();
      expect(log, isEmpty, reason: 'no dispose is registered for these');
      await owned.dispose();
      expect(log, ['release 3'], reason: 'only the dispose step runs');
      await di.dispose();
    });

    test('composes with map in teardown order', () async {
      final log = <String>[];
      final di = Scope(
        module: Module(
          components: [
            Component.effect(
              dependency:
                  Dependency(
                    create: () => Foo(2),
                    dispose: (_) => log.add('foo'),
                  ).map(
                    (foo) => 'r${foo.id}',
                    dispose: (value) => log.add('release $value'),
                  ),
            ),
          ],
        ),
      );
      await di.initialize();
      final handle = di.nodes.single;
      expect(handle.value, 'r2');
      await handle.dispose();
      expect(log, ['release r2', 'foo']);
      await di.dispose();
    });
  });

  group('default key and effects (V-T-RT-LC-028)', () {
    test('a Component without a key publishes the key of its type', () async {
      final component = Component<Database>(
        dependency: Dependency(create: () => PgDatabase('pg')),
      );
      expect(component.key, DiKey<Database>());
      expect(component.reads, isEmpty);
      final module = Module(components: [component, _dsnReader()]);
      expect(module.publishes, contains(DiKey<Database>()));

      final di = await Scope(module: module).initialize();
      expect(di.get<Database>().dsn, 'pg');
      expect(di.get<String>(key: _dsnKey), 'pg', reason: 'the consumer ran');
      await di.dispose();
    });

    test('a Component.value without a key publishes the key of its type', () {
      final component = Component<Database>.value(value: PgDatabase('value'));
      expect(component.key, DiKey<Database>());
      final module = Module(components: [component, _dsnReader()]);
      expect(module.publishes, contains(DiKey<Database>()));
    });

    test('a Component.value without a key activates its consumer', () async {
      final di = await Scope(
        module: Module(
          components: [
            Component<Database>.value(value: PgDatabase('value')),
            _dsnReader(),
          ],
        ),
      ).initialize();
      expect(di.get<Database>().dsn, 'value');
      expect(di.get<String>(key: _dsnKey), 'value');
      await di.dispose();
    });

    test('an explicit key is the key that the component publishes', () async {
      const primary = DiKey<Database>(name: 'primary');
      final created = Component<Database>(
        dependency: Dependency(create: () => PgDatabase('created')),
        key: primary,
      );
      final valued = Component<Database>.value(
        value: PgDatabase('valued'),
        key: const DiKey<Database>(name: 'replica'),
      );
      expect(created.key, primary);
      expect(valued.key, const DiKey<Database>(name: 'replica'));
      final module = Module(components: [created, valued]);
      expect(module.publishes, {
        primary,
        const DiKey<Database>(name: 'replica'),
      }, reason: 'the default key DiKey<Database>() is not published');

      final di = await Scope(module: module).initialize();
      expect(di.get<Database>(key: primary).dsn, 'created');
      expect(di.get<Database>(key: const DiKey(name: 'replica')).dsn, 'valued');
      expect(di.maybeGet<Database>(), isNull);
      await di.dispose();
    });

    test('a Component.effect publishes nothing and has a lifecycle', () async {
      final log = <String>[];
      final effect = Component<Database>.effect(
        dependency: Dependency(
          create: () {
            log.add('create');
            return PgDatabase('effect');
          },
          dispose: (_) => log.add('dispose'),
        ),
      );
      expect(effect.key, isNull);
      expect(effect.reads, isEmpty);
      final module = Module(components: [effect]);
      expect(module.publishes, isEmpty);
      expect(module.publishes, isNot(contains(DiKey<Database>())));

      final di = Scope(module: module);
      expect(log, isEmpty, reason: 'building acquires nothing');
      await di.initialize();
      expect(log, ['create']);
      expect(di.maybeGet<Database>(), isNull);
      expect((di.nodes.single.value! as Database).dsn, 'effect');
      await di.dispose();
      expect(log, ['create', 'dispose']);
    });

    test('a child Component.effect does not shadow the parent value', () async {
      final log = <String>[];
      final parent = await Scope(
        module: Module(
          components: [Component<Database>.value(value: PgDatabase('parent'))],
        ),
      ).initialize();
      final child = parent.child(
        module: Module(
          components: [
            Component<Database>.effect(
              dependency: Dependency(
                create: () {
                  log.add('create');
                  return PgDatabase('effect');
                },
                dispose: (_) => log.add('dispose'),
              ),
            ),
            _dsnReader(),
          ],
        ),
      );
      await child.initialize();
      expect(log, ['create']);
      expect(child.get<Database>().dsn, 'parent');
      expect(
        child.get<String>(key: _dsnKey),
        'parent',
        reason: 'the reader in the child scope reads the parent value',
      );
      await child.dispose();
      expect(log, ['create', 'dispose']);
      expect(parent.get<Database>().dsn, 'parent');
      await parent.dispose();
    });

    test('replacing, without, and overriddenBy cannot select an effect', () {
      final effect = Component<Database>.effect(
        dependency: Dependency(create: () => PgDatabase('effect')),
      );
      final fake = Component<Database>.value(value: PgDatabase('fake'));
      final module = Module(components: [effect]);
      const key = DiKey<Database>();

      expect(
        () => module.replacing(key: key, component: fake),
        throwsArgumentError,
        reason: 'no member publishes the key of the effect',
      );
      expect(
        () => module.replacing(key: key, component: effect),
        throwsArgumentError,
        reason: 'the effect does not publish the key',
      );
      expect(() => module.without(key: key), throwsArgumentError);
      expect(
        () => module.overriddenBy(Module(components: [fake])),
        throwsArgumentError,
        reason: 'the fake replaces nothing',
      );
      expect(
        () => Module(components: [fake]).overriddenBy(module),
        throwsArgumentError,
        reason: 'an effect among the overrides has no key',
      );
      expect(module.where((member) => member != effect).components, isEmpty);
    });

    test('Component<void>, <dynamic>, and <Null> name Component.effect', () {
      expect(
        () => Component<void>(dependency: Dependency<void>(create: () {})),
        _namesEffect(),
      );
      expect(
        () => Component<dynamic>(
          dependency: Dependency<dynamic>(create: () => 1),
        ),
        _namesEffect(),
      );
      expect(
        () => Component<Null>(dependency: Dependency<Null>(create: () => null)),
        _namesEffect(),
      );
      expect(() => Component<void>.value(value: null), _namesEffect());
      expect(() => Component<dynamic>.value(value: 1), _namesEffect());
      expect(() => Component<Null>.value(value: null), _namesEffect());
    });

    test('Component.effect accepts void, dynamic, and Null', () async {
      var runs = 0;
      final di = await Scope(
        module: Module(
          components: [
            Component<void>.effect(
              dependency: Dependency<void>(
                create: () {
                  runs++;
                },
              ),
            ),
            Component<dynamic>.effect(
              dependency: Dependency<dynamic>(create: () => runs++),
            ),
            Component<Null>.effect(
              dependency: Dependency<Null>(
                create: () {
                  runs++;
                  return null;
                },
              ),
            ),
          ],
        ),
      ).initialize();
      expect(runs, 3);
      await di.dispose();
    });
  });
}
