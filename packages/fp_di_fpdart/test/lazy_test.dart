import 'dart:async';

import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

final class Repo {
  Repo(this.id);

  final int id;
}

const lazyKey = DiKey<Lazy<Repo>>();
const count = DiKey<int>(name: 'count');

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
      Dependency<Repo>(
        create: () => create(gate: gate, fail: fail),
        dispose: release,
      );

  Lazy<Repo> holderOf(ComponentNode<Object?> node) =>
      rightOf(node.value) as Lazy<Repo>;

  Component<Lazy<Repo>> effectOf(Dependency<Lazy<Repo>> dependency) =>
      Component<Lazy<Repo>>.effect(dependency: dependency);

  setUp(() {
    events = [];
    acquisitions = 0;
  });

  test('has an empty shape and composes with a key', () {
    // from: lazy_test.dart: has an empty shape and composes with a key
    final c = Component<Lazy<Repo>>(dependency: repo().lazy(), key: lazyKey);
    expect(c.requires, isEmpty);
    expect(c.key, lazyKey);
  });

  test('acquires on first force only and shares the value', () async {
    // from: lazy_test.dart: acquires on first force only and shares the value
    final di = Scope(
      components: [
        Component<Lazy<Repo>>(dependency: repo().lazy(), key: lazyKey),
      ],
    );
    rightOf(await di.run());
    final handle = di.nodes.single;
    final holder = rightOf(di.get<Lazy<Repo>>(key: lazyKey));
    expect(acquisitions, 0);
    expect(holder.isCreated, isFalse);

    final a = rightOf(await holder.force().run());
    final b = rightOf(await holder.force().run());
    expect(identical(a, b), isTrue);
    expect(acquisitions, 1);
    expect(holder.isCreated, isTrue);

    rightOf(await handle.dispose());
    expect(events, ['acquire', 'release1']);
    expect(holder.isCreated, isFalse);
    rightOf(await di.dispose());
  });

  test('the task is lazy: nothing is created until it runs', () async {
    final di = Scope(components: [effectOf(repo().lazy())]);
    rightOf(await di.run());
    final holder = holderOf(di.nodes.single);
    final task = holder.force();
    expect(acquisitions, 0);
    expect(rightOf(await task.run()).id, 1);
    expect(rightOf(await task.run()).id, 1, reason: 'the value is shared');
    rightOf(await di.dispose());
  });

  test('concurrent first forces share one acquisition', () async {
    // from: lazy_test.dart: concurrent first forces share one acquisition
    final gate = Completer<void>();
    final di = Scope(components: [effectOf(repo(gate: gate).lazy())]);
    rightOf(await di.run());
    final holder = holderOf(di.nodes.single);
    final first = holder.force().run();
    final second = holder.force().run();
    gate.complete();
    expect(identical(rightOf(await first), rightOf(await second)), isTrue);
    expect(acquisitions, 1);
    rightOf(await di.dispose());
  });

  test('an unaccessed holder neither acquires nor releases', () async {
    // from: lazy_test.dart: an unaccessed holder neither acquires nor
    // releases
    final di = Scope(components: [effectOf(repo().lazy())]);
    rightOf(await di.run());
    rightOf(await di.dispose());
    expect(events, isEmpty);
  });

  test('force after disposal is rejected without acquiring', () async {
    // from: lazy_test.dart: force after disposal is rejected without
    // acquiring
    final di = Scope(components: [effectOf(repo().lazy())]);
    rightOf(await di.run());
    final handle = di.nodes.single;
    final holder = holderOf(handle);
    rightOf(await handle.dispose());
    expect(leftOf(await holder.force().run()).only, isA<DisposedLazyFailure>());
    expect(acquisitions, 0);
    rightOf(await di.dispose());
  });

  test('force after the request of the disposal is rejected, before the '
      'release', () async {
    final gate = Completer<void>();
    final di = Scope(
      components: [
        Component<int>.effect(
          dependency: Dependency<int>(
            create: () => 1,
            dispose: (_) => gate.future,
          ),
        ),
        effectOf(repo().lazy()),
      ],
    );
    rightOf(await di.run());
    final holder = holderOf(di.nodes.last);
    final disposal = di.dispose();
    // The request is accepted, and the release waits on the gate.
    expect(leftOf(await holder.force().run()).only, isA<DisposedLazyFailure>());
    gate.complete();
    rightOf(await disposal);
    expect(acquisitions, 0);
  });

  test('disposal waits for an in-flight acquisition, releases it once, and '
      'before the dependencies composed to its left', () async {
    // from: lazy_test.dart: disposal waits for an in-flight acquisition,
    // releases it once, and before the dependencies composed to its left
    final gate = Completer<void>();
    final di = Scope(
      components: [
        Component<int>.value(value: 1, key: count),
        Component<Lazy<Repo>>.effect(
          dependency: (
            Dependency.require<int>(key: count).map<String>(
              (_) => 'dep',
              dispose: (_) => events.add('dependency released'),
            ),
            repo(gate: gate).lazy(),
          ).zip.map<Lazy<Repo>>((v) => v.$2),
        ),
      ],
    );
    rightOf(await di.run());
    final seed = di.nodes.first;
    final handle = di.nodes.last;
    final pending = holderOf(handle).force().run();

    final disposal = handle.dispose();
    await pause(1);
    expect(events, ['acquire'], reason: 'disposal waits for settlement');

    gate.complete();
    rightOf(await disposal);
    expect(leftOf(await pending).only, isA<DisposedLazyFailure>());
    expect(events, ['acquire', 'release1', 'dependency released']);
    rightOf(await seed.dispose());
    rightOf(await di.dispose());
  });

  test('a failed acquisition is not cached and does not deactivate', () async {
    // from: lazy_test.dart: a failed acquisition is not cached and does not
    // deactivate
    var shouldFail = true;
    final di = Scope(
      components: [effectOf(repo(fail: () => shouldFail).lazy())],
    );
    rightOf(await di.run());
    final handle = di.nodes.single;
    final holder = holderOf(handle);
    final cause = leftOf(await holder.force().run());
    expect(cause.only, isA<ActivationFailure>());
    expect(handle.isActive, isTrue);
    expect(holder.isCreated, isFalse);

    shouldFail = false;
    final value = rightOf(await holder.force().run());
    expect(value.id, 2);
    rightOf(await handle.dispose());
    expect(events, ['acquire', 'acquire', 'release2']);
    rightOf(await di.dispose());
  });

  group('dispose steps and lazy dependencies', () {
    test('keep the shape', () {
      // from: lazy_test.dart: keep the shape
      final eager = Component<Repo>(
        dependency: Dependency.require<int>(
          key: count,
        ).map<Repo>((_) => Repo(1), dispose: release),
        key: const DiKey<Repo>(),
      );
      expect(eager.requires, {count});
      expect(eager.key, const DiKey<Repo>());

      final memo = Component<Lazy<Repo>>(
        dependency: Dependency.require<int>(
          key: count,
        ).map<Repo>((_) => Repo(1), dispose: release).lazy(),
        key: lazyKey,
      );
      expect(memo.requires, {count});
      expect(memo.key, lazyKey);
    });

    test('a dispose step builds from the result and releases first', () async {
      // from: lazy_test.dart: a dispose step builds from the result and
      // releases first
      final di = Scope(
        components: [
          Component<int>(
            key: count,
            dependency: Dependency<int>(
              create: () => 10,
              dispose: (_) => events.add('seed released'),
            ),
          ),
          Component<Repo>(
            key: const DiKey<Repo>(),
            dependency: Dependency.require<int>(
              key: count,
            ).map<Repo>((n) => Repo(n), dispose: release),
          ),
        ],
      );
      rightOf(await di.run());
      final seed = di.nodes.first;
      final handle = di.nodes.last;
      expect((rightOf(handle.value) as Repo).id, 10);
      expect(rightOf(di.get<Repo>()).id, 10);

      rightOf(await seed.dispose());
      expect(handle.isActive, isFalse);
      expect(events, ['release10', 'seed released']);
      rightOf(await di.dispose());
    });

    test(
      'a lazy dependency waits for its input and creates on force',
      () async {
        // from: lazy_test.dart: a lazy dependency waits for its input and
        // creates on force
        final di = Scope(
          components: [Component<int>.value(value: 1, key: count)],
        );
        final child = di.kid(
          components: [
            Component<Lazy<Repo>>(
              key: lazyKey,
              dependency: Dependency.require<int>(key: count).map<Repo>((_) {
                acquisitions++;
                events.add('acquire');
                return Repo(acquisitions);
              }, dispose: release).lazy(),
            ),
          ],
        );
        rightOf(await child.run());
        final handle = child.nodes.single;
        expect(handle.isActive, isFalse);

        rightOf(await di.run());
        final seed = di.nodes.single;
        expect(handle.isActive, isTrue);
        expect(acquisitions, 0);
        final holder = rightOf(child.get<Lazy<Repo>>(key: lazyKey));
        expect(rightOf(await holder.force().run()).id, 1);

        rightOf(await seed.dispose());
        expect(events, ['acquire', 'release1']);
        rightOf(await di.dispose());
      },
    );

    test('the keys of a lazy dependency stay tracked', () async {
      // from: lazy_test.dart: the keys of a lazy dependency stay tracked
      const version = DiKey<int>(name: 'version');
      final root = Scope(
        components: [Component<int>.value(value: 1, key: version)],
      );
      final mid = root.kid(
        components: [Component<int>.value(value: 2, key: version)],
      );
      final leaf = mid.kid(
        components: [
          Component<Lazy<Repo>>(
            key: lazyKey,
            dependency: Dependency.require<int>(
              key: version,
            ).map<Repo>(Repo.new, dispose: release).lazy(),
          ),
        ],
      );
      rightOf(await root.run());
      rightOf(await leaf.run());
      final owner = leaf.nodes.single;
      final stale = holderOf(owner);
      expect(rightOf(await stale.force().run()).id, 1);

      rightOf(await mid.run());
      expect(owner.isActive, isTrue, reason: 'the owner reactivated');
      expect(events, ['release1'], reason: 'the old creation was released');
      final fresh = holderOf(owner);
      expect(identical(fresh, stale), isFalse);
      expect(
        leftOf(await stale.force().run()).only,
        isA<DisposedLazyFailure>(),
      );
      expect(
        rightOf(await fresh.force().run()).id,
        2,
        reason: 'the new Lazy creates from the new publisher value',
      );
      rightOf(await root.dispose());
    });
  });

  test('a step that reads one key strictly and optionally keeps both '
      'reads', () async {
    final di = Scope(
      components: [
        Component<int>.value(value: 4, key: count),
        Component<Lazy<String>>(
          key: const DiKey<Lazy<String>>(),
          dependency: (
            Dependency.require<int>(key: count),
            Dependency.option<int>(key: count),
          ).zip.map<String>((pair) => '${pair.$1} ${pair.$2}').lazy(),
        ),
      ],
    );
    rightOf(await di.run());
    final holder = rightOf(di.get<Lazy<String>>());
    expect(rightOf(await holder.force().run()), '4 Some(4)');
    rightOf(await di.dispose());
  });

  test(
    'the optional read of a lazy step gives none when no key resolves',
    () async {
      final di = Scope(
        components: [
          Component<Lazy<String>>(
            key: const DiKey<Lazy<String>>(),
            dependency: Dependency.option<int>(
              key: count,
            ).map<String>((o) => '$o').lazy(),
          ),
        ],
      );
      rightOf(await di.run());
      final holder = rightOf(di.get<Lazy<String>>());
      expect(rightOf(await holder.force().run()), 'None');
      rightOf(await di.dispose());
    },
  );

  group('failure regions', () {
    test('a failed Lazy creation cancels only its own region and leaves the '
        'owner active', () async {
      // from: cancellation_test.dart: a failed Lazy creation cancels only its
      // own region and leaves the owner active (CaughtFailureIsolated)
      final ownerTokens = <CancellationToken>[];
      final seenAtDispose = <bool>[];
      var attempts = 0;
      final scope = Scope(
        components: [
          Component<Lazy<int>>(
            key: const DiKey<Lazy<int>>(),
            dependency: Dependency.cancellation()
                .map<CancellationToken>((token) {
                  ownerTokens.add(token);
                  return token;
                }, dispose: (token) => seenAtDispose.add(token.isCanceled))
                .map<int>((_) {
                  if (++attempts == 1) throw StateError('first force');
                  return 7;
                })
                .lazy(),
          ),
        ],
      );
      rightOf(await scope.run());
      final lazy = rightOf(scope.get<Lazy<int>>());
      expect(leftOf(await lazy.force().run()).only, isA<ActivationFailure>());
      expect(seenAtDispose, [true], reason: 'the region token, before dispose');
      expect(ownerTokens.single.isCanceled, isTrue, reason: 'the region token');
      expect(scope.nodes.single.isActive, isTrue, reason: 'owner stays');
      expect(
        rightOf(await lazy.force().run()),
        7,
        reason: 'a failure is not cached',
      );
      expect(ownerTokens.last.isCanceled, isFalse, reason: 'a new region');
      rightOf(await scope.dispose());
    });

    test('disposing the owner stops a Lazy creation in flight', () async {
      // from: cancellation_test.dart: disposing the owner stops a Lazy
      // creation in flight
      final gate = Completer<void>();
      final log = <String>[];
      final scope = Scope(
        components: [
          Component<Lazy<String>>(
            key: const DiKey<Lazy<String>>(),
            dependency: Dependency.cancellation()
                .mapTask<String>(
                  (token) => Task(() async {
                    log.add('create');
                    await Future.any([gate.future, token.whenCanceled.run()]);
                    log.add(token.isCanceled ? 'stopped' : 'finished');
                    return 'value';
                  }),
                )
                .lazy(),
          ),
        ],
      );
      rightOf(await scope.run());
      final forced = rightOf(scope.get<Lazy<String>>()).force().run();
      await pause(1);
      rightOf(await scope.dispose());
      expect(leftOf(await forced).only, isA<DisposedLazyFailure>());
      expect(log, ['create', 'stopped']);
      gate.complete();
    });

    test(
      'a failed Lazy creation keeps its cause and its rollback failure',
      () async {
        // from: review_regression_test.dart: 2a. a failed Lazy creation keeps
        // its cause and its rollback failure
        final scope = Scope(
          components: [
            Component<Lazy<int>>(
              key: const DiKey<Lazy<int>>(),
              dependency: Dependency<int>(
                create: () => 1,
                dispose: (_) => throw StateError('release failed'),
              ).map<int>((_) => throw StateError('create failed')).lazy(),
            ),
          ],
        );
        rightOf(await scope.run());
        final cause = leftOf(
          await rightOf(scope.get<Lazy<int>>()).force().run(),
        );
        expect(
          (cause.failures.single as ActivationFailure).error,
          isStateError,
        );
        expect(cause.defects, hasLength(1));
        expect((cause.defects.single as DisposeFailure).error, isStateError);
        // The failure comes first, then the rollback.
        expect(cause, isA<Then<DiFailure>>());
        rightOf(await scope.dispose());
      },
    );

    test(
      'a Lazy rollback that fails during owner shutdown reaches dispose',
      () async {
        // from: review_regression_test.dart: 2b. a Lazy rollback that fails
        // during owner shutdown reaches dispose()
        final gate = Completer<void>();
        final scope = Scope(
          components: [
            Component<Lazy<int>>(
              key: const DiKey<Lazy<int>>(),
              dependency:
                  Dependency<int>(
                        create: () => 1,
                        dispose: (_) => throw StateError('release failed'),
                      )
                      .mapTask<int>(
                        (_) => Task(() async {
                          await gate.future;
                          throw StateError('create failed');
                        }),
                      )
                      .lazy(),
            ),
          ],
        );
        rightOf(await scope.run());
        final forced = rightOf(scope.get<Lazy<int>>()).force().run();
        await pause(1);
        final disposal = scope.dispose();
        gate.complete();
        // The caller of force learns of the disposal.
        expect(leftOf(await forced).only, isA<DisposedLazyFailure>());
        // The late rollback failure goes to the release.
        final failure = leftOf(await disposal);
        expect(failure.defects, hasLength(1));
        expect((failure.defects.single as DisposeFailure).error, isStateError);
      },
    );
  });
}
