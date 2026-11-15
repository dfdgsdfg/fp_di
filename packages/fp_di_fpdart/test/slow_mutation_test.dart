// Slow mutation reports. The operation of a run is `run` here, as the name of
// `Scope.run`.
import 'dart:async';

import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

const _threshold = Duration(milliseconds: 40);

void main() {
  test('a slow run is reported with what runs and what waits', () async {
    // from: slow_mutation_test.dart: a slow initialize is reported with what
    // runs and what waits
    final reports = <SlowMutation>[];
    final gate = Completer<void>();
    final root = Scope(
      onSlowMutation: reports.add,
      slowMutationThreshold: _threshold,
      components: [
        Component<int>.effect(
          debugLabel: 'slow',
          dependency: Dependency<int>(
            create: () async {
              await gate.future;
              return 1;
            },
          ),
        ),
        Component<int>.effect(
          debugLabel: 'fast',
          dependency: Dependency<int>(create: () => 2),
        ),
      ],
    );
    final setup = root.run();
    final behind = root.kid().run(); // queued behind the setup
    await Future<void>.delayed(_threshold * 3.5);
    expect(reports.length, greaterThanOrEqualTo(2), reason: 'each threshold');
    final report = reports.first;
    expect(report.operation, 'run');
    expect(report.elapsed, greaterThanOrEqualTo(_threshold));
    expect(report.running, ['slow']);
    expect(report.ignoringCancellation, isEmpty);
    expect(report.disposing, isEmpty);
    expect(report.queued, 1);

    gate.complete();
    rightOf(await setup);
    rightOf(await behind);
    final count = reports.length;
    await Future<void>.delayed(_threshold * 2);
    expect(reports.length, count, reason: 'the timer stops with the mutation');
    rightOf(await root.dispose());
  });

  test('a create that ignores its canceled token is named', () async {
    // from: slow_mutation_test.dart: a create that ignores its canceled token
    // is named
    final reports = <SlowMutation>[];
    final gate = Completer<void>();
    final root = Scope(
      components: [],
      onSlowMutation: reports.add,
      slowMutationThreshold: _threshold,
    );
    final session = root.kid(
      components: [
        Component<int>.effect(
          debugLabel: 'login',
          dependency: Dependency<int>(
            create: () async {
              await gate.future; // never reads the token
              return 1;
            },
          ),
        ),
      ],
    );
    final setup = session.run();
    await Future<void>.delayed(Duration.zero);
    final logout = session.dispose();
    await Future<void>.delayed(_threshold * 1.5);
    expect(reports.last.running, ['login']);
    expect(reports.last.ignoringCancellation, ['login']);
    expect(reports.last.queued, 1, reason: 'the logout waits');
    gate.complete();
    expect(leftOf(await setup).isInterrupted, isTrue);
    rightOf(await logout);
    rightOf(await root.dispose());
  });

  test('a release that does not return is named', () async {
    // from: slow_mutation_test.dart: a release that does not return is named
    final reports = <SlowMutation>[];
    final gate = Completer<void>();
    final root = Scope(
      onSlowMutation: reports.add,
      slowMutationThreshold: _threshold,
      components: [
        Component<int>(
          key: const DiKey<int>(name: 'count'),
          debugLabel: 'socket',
          dependency: Dependency<int>(
            create: () => 1,
            dispose: (_) => gate.future,
          ),
        ),
        Component<String>(
          key: const DiKey<String>(name: 'text'),
          debugLabel: 'cache',
          dependency: Dependency<String>(create: () => 'c', dispose: (_) {}),
        ),
      ],
    );
    rightOf(await root.run());
    final teardown = root.dispose();
    final behind = Scope(components: []); // another root: its own queue
    rightOf(await behind.run());
    rightOf(await behind.dispose());
    await Future<void>.delayed(_threshold * 2.5);
    final report = reports.last;
    expect(report.operation, 'Scope.dispose');
    expect(report.running, isEmpty, reason: 'no activation is in flight');
    expect(report.disposing, ['socket']);
    expect('$report', contains('running: none, disposing: socket'));

    gate.complete();
    rightOf(await teardown);
    final count = reports.length;
    await Future<void>.delayed(_threshold * 2);
    expect(reports.length, count, reason: 'the timer stops with the mutation');
  });

  test('a rollback release that does not return is named', () async {
    // from: slow_mutation_test.dart: a rollback release that does not return
    // is named
    final reports = <SlowMutation>[];
    final gate = Completer<void>();
    final root = Scope(
      onSlowMutation: reports.add,
      slowMutationThreshold: _threshold,
      components: [
        Component<int>(
          key: const DiKey<int>(name: 'count'),
          debugLabel: 'session',
          dependency: Dependency<int>(
            create: () => 1,
            dispose: (_) => gate.future,
          ).map<int>((_) => throw StateError('step failed')),
        ),
      ],
    );
    final setup = root.run();
    await Future<void>.delayed(_threshold * 2.5);
    final report = reports.last;
    expect(report.operation, 'run');
    expect(report.running, ['session']);
    expect(report.disposing, ['session activation rollback']);

    gate.complete();
    expect(leftOf(await setup).only, isA<ActivationFailure>());
    rightOf(await root.dispose());
  });

  test('a slow-mutation report names every release that runs', () async {
    // from: concurrent_teardown_test.dart: a slow-mutation report names every
    // release that runs
    final reports = <SlowMutation>[];
    final gate = Completer<void>();
    Component<int> member(String name) => Component<int>(
      key: DiKey<int>(name: name),
      debugLabel: name,
      dependency: Dependency<int>(create: () => 0, dispose: (_) => gate.future),
    );
    final di = Scope(
      onSlowMutation: reports.add,
      slowMutationThreshold: const Duration(milliseconds: 30),
      components: [member('a'), member('b')],
    );
    rightOf(await di.run());
    final teardown = di.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(reports.last.disposing, unorderedEquals(['a', 'b']));
    gate.complete();
    rightOf(await teardown);
  });

  test('no listener, no reports and no timer', () async {
    // from: slow_mutation_test.dart: no listener, no reports and no timer
    final gate = Completer<void>();
    final root = Scope(
      slowMutationThreshold: _threshold,
      components: [
        Component<int>.effect(
          dependency: Dependency<int>(
            create: () async {
              await gate.future;
              return 1;
            },
          ),
        ),
      ],
    );
    final setup = root.run();
    await Future<void>.delayed(_threshold * 2);
    gate.complete();
    rightOf(await setup);
    rightOf(await root.dispose());
  });

  test('a listener may request a mutation, which queues', () async {
    // from: slow_mutation_test.dart: a listener may request a mutation, which
    // queues
    final gate = Completer<void>();
    late final Scope root;
    final requested = <Future<Exit<DiFailure, Scope>>>[];
    root = Scope(
      slowMutationThreshold: _threshold,
      onSlowMutation: (_) {
        if (requested.isEmpty) requested.add(root.kid().run());
      },
      components: [
        Component<int>.effect(
          dependency: Dependency<int>(
            create: () async {
              await gate.future;
              return 1;
            },
          ),
        ),
      ],
    );
    final setup = root.run();
    await Future<void>.delayed(_threshold * 1.5);
    expect(requested, hasLength(1));
    gate.complete();
    rightOf(await setup);
    rightOf(await requested.single); // not rejected as reentrant
    rightOf(await root.dispose());
  });

  test('a listener that throws leaves a ListenerFailure in errors', () async {
    final gate = Completer<void>();
    final errors = <Cause<DiFailure>>[];
    final root = Scope(
      slowMutationThreshold: _threshold,
      onSlowMutation: (_) => throw StateError('listener'),
      components: [
        Component<int>.effect(
          dependency: Dependency<int>(
            create: () async {
              await gate.future;
              return 1;
            },
          ),
        ),
      ],
    );
    final subscription = root.errors.listen(errors.add);
    final setup = root.run();
    await Future<void>.delayed(_threshold * 1.5);
    gate.complete();
    rightOf(await setup);
    expect(errors, isNotEmpty);
    expect(errors.first.failures.first, isA<ListenerFailure>());
    await subscription.cancel();
    rightOf(await root.dispose());
  });

  test('a report copies its lists and names ignoring and holds', () {
    final running = ['a'];
    final report = SlowMutation(
      operation: 'run',
      elapsed: const Duration(milliseconds: 5),
      running: running,
      ignoringCancellation: const ['a'],
      queued: 2,
      holds: const [
        HoldState(
          debugLabel: 'page',
          scopePath: 'scope',
          elapsed: Duration(milliseconds: 1),
        ),
      ],
    );
    running.add('b');
    expect(report.running, ['a']);
    expect(() => report.running.add('c'), throwsUnsupportedError);
    expect(
      '$report',
      'SlowMutation(run, 5 ms, running: a, ignoring cancellation: a, '
          'holds: page, queued: 2)',
    );
  });
}
