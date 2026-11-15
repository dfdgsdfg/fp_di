// Holds of a disposal (R-UC-RT-LC-034, V-T-RT-LC-041).
//
// A hold keeps a requested disposal in the phase `disposeRequested`: the
// lookups answer, no activation starts, and the disposal mutation enters the
// queue only after the last hold of the subtree closes, or after a call with
// `ignoreHolds`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:fp_di/fp_di.dart';
import 'package:test/test.dart';

const _k = DiKey<String>(name: 'k');
const _a = DiKey<String>(name: 'a');
const _b = DiKey<String>(name: 'b');
const _c = DiKey<String>(name: 'c');
const _w = DiKey<String>(name: 'w');
const _lazy = DiKey<Lazy<String>>(name: 'lazy');

Module _appModule() => Module(
  components: [Component<String>.value(value: 'k', key: _k)],
);

/// `b` reads `a`, so `b` releases before `a`. `w` waits for `k` of an app
/// scope that initializes later. The lazy value logs only if it was created.
Module _parentModule(List<String> log) => Module(
  components: [
    Component<String>(
      dependency: Dependency<String>(
        create: () => 'a',
        dispose: (_) => log.add('a'),
      ),
      key: _a,
    ),
    Component<String>(
      dependency: Dependency1<String, String>(
        key1: _a,
        create: (a) => '$a.b',
        dispose: (_) => log.add('b'),
      ),
      key: _b,
    ),
    Component<String>(
      dependency: Dependency1<String, String>(
        key1: _k,
        create: (k) => 'w',
        dispose: (_) => log.add('w'),
      ),
      key: _w,
    ),
    Component<Lazy<String>>(
      dependency: Dependency<String>(
        create: () => 'lazy',
        dispose: (_) => log.add('lazy'),
      ).lazy(),
      key: _lazy,
    ),
  ],
);

/// `c` reads `b` of the parent, so `c` releases before `b`.
Module _childModule(List<String> log) => Module(
  components: [
    Component<String>(
      dependency: Dependency1<String, String>(
        key1: _b,
        create: (b) => '$b.c',
        dispose: (_) => log.add('c'),
      ),
      key: _c,
    ),
  ],
);

Module _single(List<String> log, String name, DiKey<String> key) => Module(
  components: [
    Component<String>(
      dependency: Dependency<String>(
        create: () => name,
        dispose: (_) => log.add(name),
      ),
      key: key,
    ),
  ],
);

void main() {
  test('holds delay the release, and the scope stays readable', () async {
    final log = <String>[];
    final app = Scope(module: _appModule());
    final parent = await app.child(module: _parentModule(log)).initialize();
    final child = await parent.child(module: _childModule(log)).initialize();
    final lazy = parent.get<Lazy<String>>(key: _lazy);
    final page = parent.disposeHold(debugLabel: 'page');
    final unlabeled = parent.disposeHold();
    final sheet = child.disposeHold(debugLabel: 'sheet');

    var finished = 0;
    final disposal = parent.dispose();
    unawaited(disposal.then((_) => finished++));
    expect(parent.isDisposed, isTrue);
    expect(child.isDisposed, isTrue);
    expect(parent.state.phase, ScopePhase.disposeRequested);
    expect(parent.get<String>(key: _b), 'a.b');
    expect(child.get<String>(key: _c), 'a.b.c');

    // The waiting disposal is visible.
    expect(
      parent.describe(),
      contains('(disposal waits for 3 holds: page, hold, sheet)'),
    );
    final states = parent.openHolds;
    expect([for (final s in states) s.debugLabel], ['page', null, 'sheet']);
    expect(
      [for (final s in states) s.scopePath],
      ['child scope 1', 'child scope 1', 'child scope 1.1'],
    );
    expect(
      states.first.debugStackTrace.toString(),
      contains('dispose_hold_test.dart'),
    );
    final before = states.first.elapsed;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(parent.openHolds.first.elapsed, greaterThan(before));

    // The request closes the lazy holder to a new creation, and rejects an
    // initialize.
    await expectLater(lazy.force(), throwsA(isA<DisposedLazyException>()));
    expect(parent.initialize, throwsA(isA<DisposedScopeError>()));

    // A mutation of another scope of the root runs during the wait, and the
    // waiting member does not activate when its key arrives.
    await app.initialize();
    expect(
      parent.findNode<String>(key: _w)!.state.phase,
      isNot(anyOf(NodePhase.active, NodePhase.activating)),
    );

    final joining = parent.dispose();
    unawaited(joining.then((_) => finished++));
    page.close();
    unlabeled.close();
    await pumpEventQueue();
    expect(log, isEmpty);
    expect(finished, 0);

    sheet.close();
    await disposal;
    await joining;
    expect(log, ['c', 'b', 'a']);
    expect(finished, 2);
    expect(parent.state.phase, ScopePhase.disposed);
    await app.dispose();
  });

  test('a hold does not stop the deactivation by a withdrawn publisher of '
      'an ancestor', () async {
    final log = <String>[];
    final app = await Scope(
      module: Module(
        components: [
          Component<String>(
            dependency: Dependency<String>(
              create: () => 'k',
              dispose: (_) => log.add('k'),
            ),
            key: _k,
          ),
        ],
      ),
    ).initialize();
    final held = await app
        .child(
          module: Module(
            components: [
              Component<String>(
                dependency: Dependency1<String, String>(
                  key1: _k,
                  create: (k) => 'reader of $k',
                  dispose: (_) => log.add('reader'),
                ),
                key: _a,
              ),
              Component<String>(
                dependency: Dependency<String>(
                  create: () => 'other',
                  dispose: (_) => log.add('other'),
                ),
                key: _b,
              ),
            ],
          ),
        )
        .initialize();
    final hold = held.disposeHold();
    final disposal = held.dispose();

    await app.node<String>(key: _k).dispose();
    expect(log, ['reader', 'k']);
    expect(held.maybeGet<String>(key: _a), isNull);
    expect(held.get<String>(key: _b), 'other');

    hold.close();
    await disposal;
    expect(log, ['reader', 'k', 'other']);
    await app.dispose();
  });

  test('a long wait is reported as slow work with its holds', () async {
    final reports = <SlowMutation>[];
    final app = await Scope(
      module: _appModule(),
      onSlowMutation: reports.add,
      slowMutationThreshold: const Duration(milliseconds: 20),
    ).initialize();
    final held = await app
        .child(module: _single(<String>[], 'held', _a))
        .initialize();
    final hold = held.disposeHold(debugLabel: 'page');
    final disposal = held.dispose();

    await Future<void>.delayed(const Duration(milliseconds: 70));
    final waits = [
      for (final report in reports)
        if (report.operation == 'Scope.dispose (waiting for holds)') report,
    ];
    expect(waits.length, greaterThanOrEqualTo(2));
    expect(waits.first.queued, 0);
    expect([for (final h in waits.first.holds) h.debugLabel], ['page']);
    expect(waits.first.holds.single.scopePath, 'child scope 1');

    hold.close();
    await disposal;
    final count = reports.length;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(reports.length, count, reason: 'the report stops with the wait');
    await app.dispose();
  });

  test(
    'a call that ignores open holds reports IgnoredHoldsException',
    () async {
      final errors = <DiException>[];
      final app = await Scope(module: _appModule()).initialize();
      final subscription = app.errors.listen(errors.add);
      final held = await app
          .child(module: _single(<String>[], 'held', _a))
          .initialize();
      held
        ..disposeHold(debugLabel: 'page')
        ..disposeHold();
      await held.dispose(ignoreHolds: true);
      await pumpEventQueue();
      final ignored = errors.whereType<IgnoredHoldsException>().toList();
      expect(ignored, hasLength(1));
      expect(
        [for (final h in ignored.single.holds) h.debugLabel],
        ['page', null],
      );

      final free = await app
          .child(module: _single(<String>[], 'free', _b))
          .initialize();
      await free.dispose(ignoreHolds: true);
      await pumpEventQueue();
      expect(errors.whereType<IgnoredHoldsException>(), hasLength(1));
      await subscription.cancel();
      await app.dispose();
    },
  );

  test('a call that joins a waiting disposal with ignoreHolds reports the '
      'holds after the transition that starts the disposal', () async {
    final events = <String>[];
    final app = await Scope(module: _appModule()).initialize();
    final held = await app
        .child(module: _single(<String>[], 'held', _a))
        .initialize();
    final subscription = app.errors.listen((error) {
      if (error is IgnoredHoldsException) {
        events.add('ignored ${error.holds.single.debugLabel}');
      }
    });
    app.addListener(() {
      if (held.state.phase == ScopePhase.disposing &&
          !events.contains('disposing')) {
        events.add('disposing');
      }
    });
    held.disposeHold(debugLabel: 'page');
    final waiting = held.dispose();
    await pumpEventQueue();
    expect(events, isEmpty);

    await held.dispose(ignoreHolds: true);
    await waiting;
    await pumpEventQueue();
    expect(events, ['disposing', 'ignored page']);
    await subscription.cancel();
    await app.dispose();
  });

  test('the slow report of a waiting child stops when an ancestor ends its '
      'wait', () async {
    final reports = <SlowMutation>[];
    final app = await Scope(
      module: _appModule(),
      onSlowMutation: reports.add,
      slowMutationThreshold: const Duration(milliseconds: 20),
    ).initialize();
    final parent = await app
        .child(module: _single(<String>[], 'parent', _a))
        .initialize();
    final child = await parent
        .child(module: _single(<String>[], 'child', _b))
        .initialize();
    child.disposeHold(debugLabel: 'sheet'); // never closes
    final childDisposal = child.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      reports.where((r) => r.operation == 'Scope.dispose (waiting for holds)'),
      isNotEmpty,
    );

    await parent.dispose(ignoreHolds: true);
    await childDisposal;
    final count = reports.length;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(reports.length, count);
    await app.dispose();
  });

  test('a hold that a listener closes inside a mutation queues the disposal '
      'after that mutation', () async {
    final log = <String>[];
    final app = await Scope(module: _appModule()).initialize();
    final held = await app.child(module: _single(log, 'held', _a)).initialize();
    final hold = held.disposeHold();
    final disposal = held.dispose();
    var closed = false;
    void closeOnce() {
      if (closed) return;
      closed = true;
      hold.close();
    }

    // The creation of a child is a transition outside a mutation, so the
    // child exists before the listener is added.
    final other = app.child(module: _single(log, 'other', _b));
    app.addListener(closeOnce);
    // This `initialize` runs as a mutation, and its transitions call the
    // listener inside it.
    await other.initialize();
    expect(closed, isTrue);
    await disposal;
    expect(log, ['held']);
    await app.dispose();
  });

  test(
    'an ancestor that ignores the holds ends the wait of a descendant',
    () async {
      final log = <String>[];
      final parent = await Scope(module: _single(log, 'p', _a)).initialize();
      final child = await parent
          .child(module: _single(log, 'c', _b))
          .initialize();
      final hold = child.disposeHold();

      var childDone = false;
      final childDisposal = child.dispose();
      unawaited(childDisposal.then((_) => childDone = true));
      await pumpEventQueue();
      expect(childDone, isFalse);
      expect(log, isEmpty);

      await parent.dispose(ignoreHolds: true);
      await childDisposal;
      expect(childDone, isTrue);
      expect(log, ['c', 'p']);
      hold.close(); // after the disposal: changes nothing
    },
  );

  test(
    'ignoreHolds releases with a hold open, and a waiting call completes',
    () async {
      final log = <String>[];
      final scope = await Scope(module: _single(log, 's', _a)).initialize();
      scope.disposeHold(); // never closes

      var waitingDone = false;
      final waiting = scope.dispose();
      unawaited(waiting.then((_) => waitingDone = true));
      await pumpEventQueue();
      expect(waitingDone, isFalse);

      await scope.dispose(ignoreHolds: true);
      await waiting;
      expect(waitingDone, isTrue);
      expect(log, ['s']);
    },
  );

  test('a disposal without holds starts at once, as before', () async {
    final log = <String>[];
    final scope = await Scope(module: _single(log, 's', _a)).initialize();
    final hold = scope.disposeHold()..close();
    await scope.dispose();
    expect(log, ['s']);
    hold.close();
  });

  test(
    'disposeHold after the request throws, and close is idempotent',
    () async {
      final log = <String>[];
      final scope = await Scope(module: _single(log, 's', _a)).initialize();
      final hold = scope.disposeHold();
      final disposal = scope.dispose();
      expect(scope.disposeHold, throwsA(isA<DisposedScopeError>()));

      hold.close();
      hold.close(); // a second close does nothing
      await disposal;
      expect(log, ['s']);
      hold.close(); // a late close changes nothing
    },
  );

  test('a lazy creation in flight at the request continues, and the release '
      'awaits it', () async {
    final gate = Completer<String>();
    final released = <String>[];
    final scope = await Scope(
      module: Module(
        components: [
          Component<Lazy<String>>(
            dependency: Dependency<String>(
              create: () => gate.future,
              dispose: released.add,
            ).lazy(),
            key: _lazy,
          ),
        ],
      ),
    ).initialize();
    final lazy = scope.get<Lazy<String>>(key: _lazy);
    final hold = scope.disposeHold();
    final creation = lazy.force();
    final disposal = scope.dispose();

    gate.complete('late');
    expect(await creation, 'late');
    expect(released, isEmpty);
    hold.close();
    await disposal;
    // The release owns the value that the creation made.
    expect(released, ['late']);
  });

  test('the stack trace of a hold is recorded only with assertions', () async {
    final withAsserts = await _probe(enableAsserts: true);
    final without = await _probe(enableAsserts: false);
    expect(withAsserts['asserts'], isTrue);
    expect(withAsserts['trace'], contains('dispose_hold_probe.dart'));
    expect(without['asserts'], isFalse);
    expect(without['trace'], isNull);
  });
}

/// Runs `dispose_hold_probe.dart` in a new process, with or without
/// assertions, and returns the JSON line that it prints.
Future<Map<String, Object?>> _probe({required bool enableAsserts}) async {
  final config = await Isolate.packageConfig;
  final library = await Isolate.resolvePackageUri(
    Uri.parse('package:fp_di/fp_di.dart'),
  );
  if (config == null || library == null) {
    fail('The package configuration of the test run is not available.');
  }
  final script = library.resolve('../test/support/dispose_hold_probe.dart');
  final result = await Process.run(Platform.resolvedExecutable, [
    '--packages=${config.toFilePath()}',
    if (enableAsserts) '--enable-asserts',
    script.toFilePath(),
  ]);
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  final line = (result.stdout as String).trim().split('\n').last;
  return (jsonDecode(line) as Map).cast<String, Object?>();
}
