import 'dart:async';

import 'package:fp_di/fp_di.dart';
import 'package:test/test.dart';

final class Repo {
  Repo(this.id);
  final int id;
}

void main() {
  late List<String> events;
  late int acquisitions;

  Future<Repo> create({Completer<void>? gate, bool Function()? fail}) async {
    acquisitions++;
    events.add('acquire');
    if (gate != null) await gate.future;
    if (fail != null && fail()) throw StateError('acquire failed');
    return Repo(acquisitions);
  }

  void release(Repo r) => events.add('release${r.id}');

  Dependency<Repo> repo({Completer<void>? gate, bool Function()? fail}) =>
      Dependency(
        create: () => create(gate: gate, fail: fail),
        dispose: release,
      );

  setUp(() {
    events = [];
    acquisitions = 0;
  });

  test('has an empty shape and composes with a key', () {
    final c = Component(dependency: repo().lazy(), key: DiKey<Lazy<Repo>>());
    expect(c.requires, isEmpty);
    expect(c.key, DiKey<Lazy<Repo>>());
  });

  test('acquires on first force only and shares the value', () async {
    final di = Scope(
      module: Module(
        components: [
          Component(dependency: repo().lazy(), key: DiKey<Lazy<Repo>>()),
        ],
      ),
    );
    await di.initialize();
    final handle = di.nodes.single;
    final holder = di.get<Lazy<Repo>>();
    expect(acquisitions, 0);
    expect(holder.isCreated, isFalse);

    final a = await holder.force();
    final b = await holder.force();
    expect(identical(a, b), isTrue);
    expect(acquisitions, 1);
    expect(holder.isCreated, isTrue);

    await handle.dispose();
    expect(events, ['acquire', 'release1']);
    await di.dispose();
  });

  test('concurrent first forces share one acquisition', () async {
    final gate = Completer<void>();
    final di = Scope(
      module: Module(
        components: [Component.effect(dependency: repo(gate: gate).lazy())],
      ),
    );
    await di.initialize();
    final holder = di.nodes.single.value! as Lazy<Repo>;
    final first = holder.force();
    final second = holder.force();
    gate.complete();
    expect(identical(await first, await second), isTrue);
    expect(acquisitions, 1);
    await di.dispose();
  });

  test('an unaccessed holder neither acquires nor releases', () async {
    final di = Scope(
      module: Module(components: [Component.effect(dependency: repo().lazy())]),
    );
    await di.initialize();
    await di.dispose();
    expect(events, isEmpty);
  });

  test('force after disposal is rejected without acquiring', () async {
    final di = Scope(
      module: Module(components: [Component.effect(dependency: repo().lazy())]),
    );
    await di.initialize();
    final handle = di.nodes.single;
    final holder = handle.value! as Lazy<Repo>;
    await handle.dispose();
    await expectLater(holder.force(), throwsA(isA<DisposedLazyException>()));
    expect(acquisitions, 0);
    await di.dispose();
  });

  test('disposal waits for an in-flight acquisition, releases it once, '
      'and before the dependencies composed to its left', () async {
    final gate = Completer<void>();
    final di = Scope(
      module: Module(
        components: [
          Component.value(value: 1, key: DiKey<int>(name: 'count')),
          Component.effect(
            dependency: (
              Dependency.require<int>(
                key: const DiKey(name: 'count'),
              ).map(
                (_) => 'dep',
                dispose: (_) => events.add('dependency released'),
              ),
              repo(gate: gate).lazy(),
            ).zip.map((v) => v.$2),
          ),
        ],
      ),
    );
    await di.initialize();
    final seed = di.nodes.first;
    final handle = di.nodes.last;
    final pending = (handle.value! as Lazy<Repo>).force();
    final pendingResult = expectLater(
      pending,
      throwsA(isA<DisposedLazyException>()),
    );

    final disposal = handle.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(events, ['acquire'], reason: 'disposal waits for settlement');

    gate.complete();
    await disposal;
    await pendingResult;
    expect(events, ['acquire', 'release1', 'dependency released']);
    await seed.dispose();
    await di.dispose();
  });

  test('a failed acquisition is not cached and does not deactivate', () async {
    var shouldFail = true;
    final di = Scope(
      module: Module(
        components: [
          Component.effect(dependency: repo(fail: () => shouldFail).lazy()),
        ],
      ),
    );
    await di.initialize();
    final handle = di.nodes.single;
    final holder = handle.value! as Lazy<Repo>;
    await expectLater(holder.force(), throwsA(isA<StateError>()));
    expect(handle.isActive, isTrue);
    expect(holder.isCreated, isFalse);

    shouldFail = false;
    final value = await holder.force();
    expect(value.id, 2);
    await handle.dispose();
    expect(events, ['acquire', 'acquire', 'release2']);
    await di.dispose();
  });

  group('dispose steps and lazy dependencies', () {
    test('keep the shape', () {
      final eager = Component(
        dependency: Dependency.require<int>(
          key: const DiKey(name: 'count'),
        ).map((_) => create(), dispose: release),
        key: DiKey<Repo>(),
      );
      expect(eager.requires, {DiKey<int>(name: 'count')});
      expect(eager.key, DiKey<Repo>());

      final memo = Component(
        dependency: Dependency.require<int>(
          key: const DiKey(name: 'count'),
        ).map((_) => create(), dispose: release).lazy(),
        key: DiKey<Lazy<Repo>>(),
      );
      expect(memo.requires, {DiKey<int>(name: 'count')});
      expect(memo.key, DiKey<Lazy<Repo>>());
    });

    test('a dispose step builds from the result and releases first', () async {
      final di = Scope(
        module: Module(
          components: [
            Component(
              dependency: Dependency(
                create: () => 10,
                dispose: (_) => events.add('seed released'),
              ),
              key: DiKey<int>(name: 'count'),
            ),
            Component(
              dependency: Dependency.require<int>(
                key: const DiKey(name: 'count'),
              ).map((n) => Repo(n), dispose: release),
              key: DiKey<Repo>(),
            ),
          ],
        ),
      );
      await di.initialize();
      final seed = di.nodes.first;
      final handle = di.nodes.last;
      expect((handle.value! as Repo).id, 10);
      expect(di.get<Repo>().id, 10);

      await seed.dispose();
      expect(handle.isActive, isFalse);
      expect(events, ['release10', 'seed released']);
      await di.dispose();
    });

    test(
      'a lazy dependency waits for its input and creates on force',
      () async {
        final di = Scope(
          module: Module(
            components: [
              Component.value(value: 1, key: DiKey<int>(name: 'count')),
            ],
          ),
        );
        final child = di.child(
          module: Module(
            components: [
              Component(
                dependency: Dependency.require<int>(
                  key: const DiKey(name: 'count'),
                ).map((_) => create(), dispose: release).lazy(),
                key: DiKey<Lazy<Repo>>(),
              ),
            ],
          ),
        );
        await child.initialize();
        final handle = child.nodes.single;
        expect(handle.isActive, isFalse);

        await di.initialize();
        final seed = di.nodes.single;
        expect(handle.isActive, isTrue);
        expect(acquisitions, 0);
        expect((await child.get<Lazy<Repo>>().force()).id, 1);

        await seed.dispose();
        expect(events, ['acquire', 'release1']);
        await di.dispose();
      },
    );

    test('the keys of a lazy dependency stay tracked', () async {
      final version = DiKey<int>(name: 'version');
      final root = Scope(
        module: Module(components: [Component.value(value: 1, key: version)]),
      );
      final mid = root.child(
        module: Module(components: [Component.value(value: 2, key: version)]),
      );
      final leaf = mid.child(
        module: Module(
          components: [
            Component(
              dependency: Dependency.require<int>(
                key: version,
              ).map(Repo.new, dispose: release).lazy(),
              key: DiKey<Lazy<Repo>>(),
            ),
          ],
        ),
      );
      await root.initialize();
      await leaf.initialize();
      final owner = leaf.nodes.single;
      final stale = owner.value! as Lazy<Repo>;
      expect((await stale.force()).id, 1);

      await mid.initialize();
      expect(owner.isActive, isTrue, reason: 'the owner reactivated');
      expect(events, ['release1'], reason: 'the old creation was released');
      final fresh = owner.value! as Lazy<Repo>;
      expect(identical(fresh, stale), isFalse);
      await expectLater(stale.force(), throwsA(isA<DisposedLazyException>()));
      expect(
        (await fresh.force()).id,
        2,
        reason: 'the new Lazy creates from the new publisher value',
      );

      await root.dispose();
    });
  });
}
