// The constructors of a component and the checks of a declaration. The
// constructors never throw: a declaration that does not fit is a value that
// `Scope.run` reports.
import 'dart:async';

import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

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

Matcher _namesEffect() => isA<InvalidComponentFailure>().having(
  (f) => f.reason,
  'reason',
  contains('Component.effect'),
);

void main() {
  group('Component constructor', () {
    test('a key whose type is not the type argument fails the run', () async {
      // Inference widens the type argument to Object, so this compiles.
      // from: component_constructor_test.dart: rejects a key whose type is not
      // the type argument
      final component = Component(
        dependency: Dependency<Object>(create: () => Foo(1)),
        key: DiKey<String>(name: 'text'),
      );
      final value = Component.value(
        value: Foo(1),
        key: DiKey<String>(name: 'text'),
      );
      for (final candidate in [component, value]) {
        expect(candidate.invalidReason, contains('Component<String>'));
        final failure = await failureOfRun(Scope(components: [candidate]));
        expect(
          failure,
          isA<InvalidComponentFailure>().having(
            (f) => f.reason,
            'reason',
            contains('Component<String>'),
          ),
        );
      }
    });

    test('a contribution whose set type is not the type argument fails the '
        'run', () async {
      final component = Component<Object>.into(
        dependency: Dependency<Object>(create: () => 1),
        key: const DiSetKey<int>(name: 'numbers'),
      );
      expect(component.invalidReason, isNotNull);
      final failure = await failureOfRun(Scope(components: [component]));
      expect(failure, isA<InvalidComponentFailure>());
    });

    test('infers a port type from the key, also inside a scope', () async {
      // from: component_constructor_test.dart: infers a port type from the key,
      // also inside a module
      final di = Scope(
        components: [
          // The type argument Object states that the port key binds a Foo. A
          // list of components gives the context Object?, so a missing type
          // argument is a failure of the run (the first test).
          Component<Object>(
            dependency: Dependency<Object>(create: () => Foo(7)),
            key: DiKey<Object>(name: 'port'),
          ),
          Component<int>(
            dependency: Dependency.require<Object>(
              key: const DiKey<Object>(name: 'port'),
            ).map((port) => (port as Foo).id),
            key: DiKey<int>(name: 'count'),
          ),
        ],
      );
      rightOf(await di.run());
      expect(rightOf(di.get<int>(key: const DiKey<int>(name: 'count'))), 7);
      expect(di.nodes.first, isA<ComponentNode<Object?>>());
      rightOf(await di.dispose());
    });

    test('a key of the inferred type passes without a type argument', () {
      // from: component_constructor_test.dart: a key of the inferred type
      // passes without a type argument
      final component = Component(
        dependency: Dependency(create: () => Foo(1)),
        key: DiKey<Foo>(),
      );
      expect(component, isA<Component<Foo>>());
      expect(component.key, DiKey<Foo>());
      expect(component.invalidReason, isNull);
    });

    test('does not acquire when the component is built', () {
      // from: component_constructor_test.dart: does not acquire when the
      // component is built
      var calls = 0;
      final published = Component<Foo>(
        dependency: Dependency(create: () => Foo(++calls)),
        key: DiKey<Foo>(),
      );
      expect(calls, 0);
      expect(published.key, DiKey<Foo>());
      expect(calls, 0, reason: 'reading the shape does not acquire');
    });

    test('a list of components constructs nothing before run', () async {
      // from: component_constructor_test.dart: a module of dependencies
      // constructs nothing before initialize
      var calls = 0;
      final components = <Component<Object?>>[
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
      ];
      expect(calls, 0);
      final di = Scope(components: components);
      expect(calls, 0, reason: 'declaring a scope acquires nothing');
      rightOf(await di.run());
      expect(calls, 2);
      expect(rightOf(di.get<Foo>()).id, 1);
      rightOf(await di.dispose());
    });

    test('acquires on run and yields the value', () async {
      // from: component_constructor_test.dart: acquires on initialize and
      // yields the value
      var calls = 0;
      final di = Scope(
        components: [
          Component<Foo>(dependency: Dependency(create: () => Foo(++calls))),
        ],
      );
      rightOf(await di.run());
      final handle = di.nodes.single;
      expect(calls, 1);
      expect((rightOf(handle.value) as Foo).id, 1);
      expect(handle.isActive, isTrue);
      rightOf(await di.dispose());
    });

    test('has an empty derived shape', () {
      // from: component_constructor_test.dart: has an empty derived shape
      final component = Component<int>.effect(
        dependency: Dependency(create: () => 1),
      );
      expect(component.requires, isEmpty);
      expect(component.optional, isEmpty);
      expect(component.hasKey, isFalse);
      expect(component.reads, isEmpty);
      expect(component.debugLabel, isNull);
    });

    test('supports an asynchronous acquire', () async {
      // from: component_constructor_test.dart: supports an asynchronous
      // acquire
      final gate = Completer<Foo>();
      final di = Scope(
        components: [
          Component<Foo>(
            dependency: Dependency(create: () => gate.future),
            key: DiKey<Foo>(),
          ),
        ],
      );
      var done = false;
      final pending = di.run().then((_) => done = true);
      await pause(1);
      expect(done, isFalse, reason: 'run waits for acquire');
      expect(di.getOption<Foo>(), isA<None>());
      gate.complete(Foo(7));
      await pending;
      expect((rightOf(di.nodes.single.value) as Foo).id, 7);
      expect(rightOf(di.get<Foo>()).id, 7);
      rightOf(await di.dispose());
    });

    test('an asynchronous failure fails run and leaves no node', () async {
      // from: component_constructor_test.dart: an asynchronous failure fails
      // initialize and leaves no node
      final di = Scope(
        components: [
          Component<Foo>(
            dependency: Dependency<Foo>(
              create: () async => throw StateError('boom'),
            ),
            key: DiKey<Foo>(),
          ),
        ],
      );
      expect(await failureOfRun(di), isA<ActivationFailure>());
      expect(di.isInitialized, isFalse);
      expect(di.getOption<Foo>(), isA<None>());
      rightOf(await di.dispose());
    });

    test('runs again on each reactivation and not otherwise', () async {
      // from: component_constructor_test.dart: runs again on each reactivation
      // and not otherwise
      var calls = 0;
      const count = DiKey<int>(name: 'count');
      // The consumer sits in a child scope. Two ancestors run later and
      // publish the int key one after the other.
      final di = Scope(components: []);
      final outer = di.kid(
        components: [Component<int>.value(value: 2, key: count)],
      );
      final inner = outer.kid(
        components: [Component<int>.value(value: 1, key: count)],
      );
      final leaf = inner.kid(
        components: [
          Component<Foo>(
            dependency: Dependency.require<int>(
              key: count,
            ).map((n) => Foo(++calls * 100 + n)),
            key: DiKey<Foo>(),
          ),
          Component<int>.effect(dependency: Dependency(create: () => 0)),
        ],
      );
      rightOf(await leaf.run());
      final handle = leaf.nodes.first;
      expect(calls, 0, reason: 'dormant: acquire has not run');
      expect(handle.isActive, isFalse);

      rightOf(await inner.run());
      expect(calls, 1);
      expect(rightOf(leaf.get<Foo>()).id, 101);
      // An unrelated withdrawal does not acquire again.
      rightOf(await leaf.nodes.last.dispose());
      expect(calls, 1);

      rightOf(await inner.nodes.single.dispose());
      expect(handle.isActive, isFalse);
      rightOf(await outer.run());
      expect(calls, 2);
      expect(rightOf(leaf.get<Foo>()).id, 202);
      rightOf(await di.dispose());
    });

    test('releases on teardown and acquires again on reuse', () async {
      // from: component_constructor_test.dart: releases on teardown and
      // acquires again on reuse
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
      final di = Scope(components: []);
      final first = di.kid(components: [component]);
      rightOf(await first.run());
      expect(di.getOption<Foo>(), isA<None>());
      expect(rightOf(first.get<Foo>()).id, 1);
      rightOf(await first.dispose());
      final second = di.kid(components: [component]);
      rightOf(await second.run());
      expect(
        rightOf(second.get<Foo>()).id,
        2,
        reason: 'a new scope for the same description creates a new value',
      );
      rightOf(await second.dispose());
      expect(log, ['acquire 1', 'release 1', 'acquire 2', 'release 2']);
      rightOf(await di.dispose());
    });

    test('a dependency without a dispose releases nothing', () async {
      // from: component_constructor_test.dart: a dependency without a dispose
      // releases nothing
      final log = <String>[];
      final di = Scope(
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
      );
      rightOf(await di.run());
      final [plain, mapped, owned] = di.nodes;
      expect((rightOf(plain.value) as Foo).id, 1);
      expect(rightOf(mapped.value), 2);
      expect(rightOf(owned.value), 3);
      rightOf(await plain.dispose());
      rightOf(await mapped.dispose());
      expect(log, isEmpty, reason: 'no dispose is registered for these');
      rightOf(await owned.dispose());
      expect(log, ['release 3'], reason: 'only the dispose step runs');
      rightOf(await di.dispose());
    });

    test('composes with map in teardown order', () async {
      // from: component_constructor_test.dart: composes with map in teardown
      // order
      final log = <String>[];
      final di = Scope(
        components: [
          Component<String>.effect(
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
      );
      rightOf(await di.run());
      final handle = di.nodes.single;
      expect(rightOf(handle.value), 'r2');
      rightOf(await handle.dispose());
      expect(log, ['release r2', 'foo']);
      rightOf(await di.dispose());
    });
  });

  group('default key and effects', () {
    test('a Component without a key publishes the key of its type', () async {
      // from: component_constructor_test.dart: a Component without a key
      // publishes the key of its type
      final component = Component<Database>(
        dependency: Dependency(create: () => PgDatabase('pg')),
      );
      expect(component.key, DiKey<Database>());
      expect(component.reads, isEmpty);
      final components = <Component<Object?>>[component, _dsnReader()];
      expect(components.publishes, contains(DiKey<Database>()));

      final di = Scope(components: components);
      rightOf(await di.run());
      expect(rightOf(di.get<Database>()).dsn, 'pg');
      expect(
        rightOf(di.get<String>(key: _dsnKey)),
        'pg',
        reason: 'the consumer ran',
      );
      rightOf(await di.dispose());
    });

    test('a Component.value without a key publishes the key of its type', () {
      // from: component_constructor_test.dart: a Component.value without a key
      // publishes the key of its type
      final component = Component<Database>.value(value: PgDatabase('value'));
      expect(component.key, DiKey<Database>());
      final components = <Component<Object?>>[component, _dsnReader()];
      expect(components.publishes, contains(DiKey<Database>()));
    });

    test('a Component.value without a key activates its consumer', () async {
      // from: component_constructor_test.dart: a Component.value without a key
      // activates its consumer
      final di = Scope(
        components: [
          Component<Database>.value(value: PgDatabase('value')),
          _dsnReader(),
        ],
      );
      rightOf(await di.run());
      expect(rightOf(di.get<Database>()).dsn, 'value');
      expect(rightOf(di.get<String>(key: _dsnKey)), 'value');
      rightOf(await di.dispose());
    });

    test('an explicit key is the key that the component publishes', () async {
      // from: component_constructor_test.dart: an explicit key is the key that
      // the component publishes
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
      final components = <Component<Object?>>[created, valued];
      expect(components.publishes, {
        primary,
        const DiKey<Database>(name: 'replica'),
      }, reason: 'the default key DiKey<Database>() is not published');

      final di = Scope(components: components);
      rightOf(await di.run());
      expect(rightOf(di.get<Database>(key: primary)).dsn, 'created');
      expect(
        rightOf(di.get<Database>(key: const DiKey(name: 'replica'))).dsn,
        'valued',
      );
      expect(di.getOption<Database>(), isA<None>());
      rightOf(await di.dispose());
    });

    test('a Component.effect publishes nothing and has a lifecycle', () async {
      // from: component_constructor_test.dart: a Component.effect publishes
      // nothing and has a lifecycle
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
      expect(effect.hasKey, isFalse);
      expect(effect.reads, isEmpty);
      final components = <Component<Object?>>[effect];
      expect(components.publishes, isEmpty);
      expect(components.publishes, isNot(contains(DiKey<Database>())));

      final di = Scope(components: components);
      expect(log, isEmpty, reason: 'building acquires nothing');
      rightOf(await di.run());
      expect(log, ['create']);
      expect(di.getOption<Database>(), isA<None>());
      expect((rightOf(di.nodes.single.value) as Database).dsn, 'effect');
      rightOf(await di.dispose());
      expect(log, ['create', 'dispose']);
    });

    test('a child Component.effect does not shadow the parent value', () async {
      // from: component_constructor_test.dart: a child Component.effect does
      // not shadow the parent value
      final log = <String>[];
      final parent = Scope(
        components: [Component<Database>.value(value: PgDatabase('parent'))],
      );
      rightOf(await parent.run());
      final child = parent.kid(
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
      );
      rightOf(await child.run());
      expect(log, ['create']);
      expect(rightOf(child.get<Database>()).dsn, 'parent');
      expect(
        rightOf(child.get<String>(key: _dsnKey)),
        'parent',
        reason: 'the reader in the child scope reads the parent value',
      );
      rightOf(await child.dispose());
      expect(log, ['create', 'dispose']);
      expect(rightOf(parent.get<Database>()).dsn, 'parent');
      rightOf(await parent.dispose());
    });

    test('overriddenBy cannot select an effect', () {
      // from: component_constructor_test.dart: replacing, without, and
      // overriddenBy cannot select an effect
      final effect = Component<Database>.effect(
        dependency: Dependency(create: () => PgDatabase('effect')),
      );
      final fake = Component<Database>.value(value: PgDatabase('fake'));
      expect(
        leftOf([effect].overriddenBy([fake])).only,
        isA<UnmatchedOverrideFailure>(),
        reason: 'the fake replaces nothing',
      );
      expect(
        leftOf([fake].overriddenBy([effect])).only,
        isA<UnmatchedOverrideFailure>(),
        reason: 'an effect among the overrides has no key',
      );
      expect([effect].where((member) => member != effect), isEmpty);
    });

    test(
      'Component<void>, <dynamic>, and <Null> name Component.effect',
      () async {
        // from: component_constructor_test.dart: Component<void>, <dynamic>,
        // and <Null> name Component.effect
        final components = <Component<Object?>>[
          Component<void>(dependency: Dependency<void>(create: () {})),
          Component<dynamic>(dependency: Dependency<dynamic>(create: () => 1)),
          Component<Null>(dependency: Dependency<Null>(create: () => null)),
          Component<void>.value(value: null),
          Component<dynamic>.value(value: 1),
          Component<Null>.value(value: null),
        ];
        for (final component in components) {
          expect(component.invalidReason, contains('Component.effect'));
          expect(
            await failureOfRun(Scope(components: [component])),
            _namesEffect(),
          );
        }
      },
    );

    test('Component.effect accepts void, dynamic, and Null', () async {
      // from: component_constructor_test.dart: Component.effect accepts void,
      // dynamic, and Null
      var runs = 0;
      final di = Scope(
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
      );
      rightOf(await di.run());
      expect(runs, 3);
      rightOf(await di.dispose());
    });
  });
}
