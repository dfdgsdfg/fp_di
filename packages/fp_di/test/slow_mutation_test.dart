// Slow mutation reports (R-UC-RT-LC-016).
import 'dart:async';

import 'package:fp_di/fp_di.dart';
import 'package:test/test.dart';

const _threshold = Duration(milliseconds: 40);

void main() {
  test('a slow initialize is reported with what runs and what waits', () async {
    final reports = <SlowMutation>[];
    final gate = Completer<void>();
    final root = Scope(
      onSlowMutation: reports.add,
      slowMutationThreshold: _threshold,
      module: Module(
        components: [
          Component<int>.effect(
            debugLabel: 'slow',
            dependency: Dependency(
              create: () async {
                await gate.future;
                return 1;
              },
            ),
          ),
          Component<int>.effect(
            debugLabel: 'fast',
            dependency: Dependency(create: () => 2),
          ),
        ],
      ),
    );
    final setup = root.initialize();
    final behind = root.child().initialize(); // queued behind the setup
    await Future<void>.delayed(_threshold * 3.5);
    expect(reports.length, greaterThanOrEqualTo(2), reason: 'each threshold');
    final report = reports.first;
    expect(report.operation, 'initialize');
    expect(report.elapsed, greaterThanOrEqualTo(_threshold));
    expect(report.running, ['slow']);
    expect(report.ignoringCancellation, isEmpty);
    expect(report.disposing, isEmpty);
    expect(report.queued, 1);

    gate.complete();
    await setup;
    await behind;
    final count = reports.length;
    await Future<void>.delayed(_threshold * 2);
    expect(reports.length, count, reason: 'the timer stops with the mutation');
    await root.dispose();
  });

  test('a create that ignores its canceled token is named', () async {
    final reports = <SlowMutation>[];
    final gate = Completer<void>();
    final root = Scope(
      onSlowMutation: reports.add,
      slowMutationThreshold: _threshold,
    );
    final session = root.child(
      module: Module(
        components: [
          Component<int>.effect(
            debugLabel: 'login',
            dependency: Dependency(
              create: () async {
                await gate.future; // never reads the token
                return 1;
              },
            ),
          ),
        ],
      ),
    );
    final setup = session.initialize().then<Object?>(
      (_) => null,
      onError: (Object e) => e,
    );
    await Future<void>.delayed(Duration.zero);
    final logout = session.dispose();
    await Future<void>.delayed(_threshold * 1.5);
    expect(reports.last.running, ['login']);
    expect(reports.last.ignoringCancellation, ['login']);
    expect(reports.last.queued, 1, reason: 'the logout waits');
    gate.complete();
    expect(await setup, isA<ActivationCanceledException>());
    await logout;
    await root.dispose();
  });

  test('a release that does not return is named', () async {
    final reports = <SlowMutation>[];
    final gate = Completer<void>();
    final root = Scope(
      onSlowMutation: reports.add,
      slowMutationThreshold: _threshold,
      module: Module(
        components: [
          Component<int>(
            key: DiKey<int>(name: 'count'),
            debugLabel: 'socket',
            dependency: Dependency(
              create: () => 1,
              dispose: (_) => gate.future,
            ),
          ),
          Component<String>(
            key: DiKey<String>(name: 'text'),
            debugLabel: 'cache',
            dependency: Dependency(create: () => 'c', dispose: (_) {}),
          ),
        ],
      ),
    );
    await root.initialize();
    final teardown = root.dispose();
    final behind = Scope().initialize(); // another root: its own queue
    await behind.then((scope) => scope.dispose());
    await Future<void>.delayed(_threshold * 2.5);
    final report = reports.last;
    expect(report.operation, 'Scope.dispose');
    expect(report.running, isEmpty, reason: 'no activation is in flight');
    expect(report.disposing, ['socket']);
    expect('$report', contains('running: none, disposing: socket'));

    gate.complete();
    await teardown;
    final count = reports.length;
    await Future<void>.delayed(_threshold * 2);
    expect(reports.length, count, reason: 'the timer stops with the mutation');
  });

  test('a rollback release that does not return is named', () async {
    final reports = <SlowMutation>[];
    final gate = Completer<void>();
    final root = Scope(
      onSlowMutation: reports.add,
      slowMutationThreshold: _threshold,
      module: Module(
        components: [
          Component<int>(
            key: DiKey<int>(name: 'count'),
            debugLabel: 'session',
            dependency: Dependency<int>(
              create: () => 1,
              dispose: (_) => gate.future,
            ).map<int>((_) => throw StateError('step failed')),
          ),
        ],
      ),
    );
    final setup = root.initialize();
    await Future<void>.delayed(_threshold * 2.5);
    final report = reports.last;
    expect(report.operation, 'initialize');
    expect(report.running, ['session']);
    expect(report.disposing, ['session activation rollback']);

    gate.complete();
    await expectLater(setup, throwsA(isA<ActivationException>()));
    await root.dispose();
  });

  test('no listener, no reports and no timer', () async {
    final gate = Completer<void>();
    final root = Scope(
      slowMutationThreshold: _threshold,
      module: Module(
        components: [
          Component<int>.effect(
            dependency: Dependency(
              create: () async {
                await gate.future;
                return 1;
              },
            ),
          ),
        ],
      ),
    );
    final setup = root.initialize();
    await Future<void>.delayed(_threshold * 2);
    gate.complete();
    await setup;
    await root.dispose();
  });

  test('a listener may request a mutation, which queues', () async {
    final gate = Completer<void>();
    late final Scope root;
    final requested = <Future<void>>[];
    root = Scope(
      slowMutationThreshold: _threshold,
      onSlowMutation: (_) {
        if (requested.isEmpty) requested.add(root.child().initialize());
      },
      module: Module(
        components: [
          Component<int>.effect(
            dependency: Dependency(
              create: () async {
                await gate.future;
                return 1;
              },
            ),
          ),
        ],
      ),
    );
    final setup = root.initialize();
    await Future<void>.delayed(_threshold * 1.5);
    expect(requested, hasLength(1));
    gate.complete();
    await setup;
    await requested.single; // not rejected as reentrant
    await root.dispose();
  });
}
