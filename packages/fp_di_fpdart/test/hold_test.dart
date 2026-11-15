// Holds of a disposal. A hold keeps a requested disposal in the phase
// `disposeRequested`: the lookups answer, no activation starts, and the
// disposal mutation enters the queue only after the last hold of the subtree
// closes, or after a call with `ignoreHolds`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

const _k = DiKey<String>(name: 'k');
const _a = DiKey<String>(name: 'a');
const _b = DiKey<String>(name: 'b');
const _c = DiKey<String>(name: 'c');
const _w = DiKey<String>(name: 'w');
const _lazy = DiKey<Lazy<String>>(name: 'lazy');

List<Component<Object?>> _app() => [
  Component<String>.value(value: 'k', key: _k),
];

/// `b` reads `a`, so `b` releases before `a`. `w` waits for `k` of an app
/// scope that runs later. The lazy value logs only if it was created.
List<Component<Object?>> _parent(List<String> log) => [
  Component<String>(
    key: _a,
    dependency: Dependency<String>(
      create: () => 'a',
      dispose: (_) => log.add('a'),
    ),
  ),
  Component<String>(
    key: _b,
    dependency: Dependency.require<String>(
      key: _a,
    ).map<String>((a) => '$a.b', dispose: (_) => log.add('b')),
  ),
  Component<String>(
    key: _w,
    dependency: Dependency.require<String>(
      key: _k,
    ).map<String>((k) => 'w', dispose: (_) => log.add('w')),
  ),
  Component<Lazy<String>>(
    key: _lazy,
    dependency: Dependency<String>(
      create: () => 'lazy',
      dispose: (_) => log.add('lazy'),
    ).lazy(),
  ),
];

/// `c` reads `b` of the parent, so `c` releases before `b`.
List<Component<Object?>> _childOf(List<String> log) => [
  Component<String>(
    key: _c,
    dependency: Dependency.require<String>(
      key: _b,
    ).map<String>((b) => '$b.c', dispose: (_) => log.add('c')),
  ),
];

List<Component<Object?>> _single(
  List<String> log,
  String name,
  DiKey<String> key,
) => [
  Component<String>(
    key: key,
    dependency: Dependency<String>(
      create: () => name,
      dispose: (_) => log.add(name),
    ),
  ),
];

DisposeHold _hold(Scope scope, [String? label]) =>
    rightOf(scope.disposeHold(debugLabel: label));

bool _isIgnoredHolds(Cause<DiFailure> cause) =>
    cause.failures.any((failure) => failure is IgnoredHoldsFailure);

Future<Scope> _running(Scope scope) async {
  rightOf(await scope.run());
  return scope;
}

void main() {
  test('holds delay the release, and the scope stays readable', () async {
    // from: dispose_hold_test.dart: holds delay the release, and the scope
    // stays readable
    final log = <String>[];
    final app = Scope(components: _app());
    final parent = await _running(app.kid(components: _parent(log)));
    final child = await _running(parent.kid(components: _childOf(log)));
    final lazy = rightOf(parent.get<Lazy<String>>(key: _lazy));
    final page = _hold(parent, 'page');
    final unlabeled = _hold(parent);
    final sheet = _hold(child, 'sheet');

    var finished = 0;
    final disposal = parent.dispose();
    unawaited(disposal.then((_) => finished++));
    expect(parent.isDisposed, isTrue);
    expect(child.isDisposed, isTrue);
    expect(parent.state.phase, ScopePhase.disposeRequested);
    expect(rightOf(parent.get<String>(key: _b)), 'a.b');
    expect(rightOf(child.get<String>(key: _c)), 'a.b.c');

    // The waiting disposal is visible.
    expect(
      rightOf(parent.describe()),
      contains('(disposal waits for 3 holds: page, hold, sheet)'),
    );
    final states = parent.openHolds;
    expect([for (final s in states) s.debugLabel], ['page', null, 'sheet']);
    expect(
      [for (final s in states) s.scopePath],
      ['child scope 1', 'child scope 1', 'child scope 1.1'],
    );
    expect(states.first.debugStackTrace.toString(), contains('hold_test.dart'));
    final before = states.first.elapsed;
    await pause();
    expect(parent.openHolds.first.elapsed, greaterThan(before));

    // The request closes the lazy holder to a new creation, and rejects a
    // run.
    final forced = leftOf(await lazy.force().run());
    expect(forced.only, isA<DisposedLazyFailure>());
    expect(leftOf(await parent.run()).only, isA<DisposedScopeFailure>());

    // A run of another scope of the root happens during the wait, and the
    // waiting node does not activate when its key arrives.
    rightOf(await app.run());
    expect(
      parent.findNode<String>(key: _w).toNullable()!.state.phase,
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
    rightOf(await disposal);
    rightOf(await joining);
    expect(log, ['c', 'b', 'a']);
    expect(finished, 2);
    expect(parent.state.phase, ScopePhase.disposed);
    rightOf(await app.dispose());
  });

  test('describe names one hold in the singular, and the heading goes with '
      'the wait', () async {
    final parent = await _running(Scope(components: _app()));
    final child = await _running(
      parent.kid(components: _single(<String>[], 'child', _a)),
    );
    final hold = _hold(child, 'sheet');
    final disposal = child.dispose();
    expect(
      rightOf(parent.describe()),
      allOf(
        contains('child scope 1 (disposal waits for 1 hold: sheet)'),
        isNot(contains('\nscope (disposal')),
      ),
    );
    hold.close();
    rightOf(await disposal);
    expect(rightOf(parent.describe()), isNot(contains('waits for')));
    rightOf(await parent.dispose());
  });

  test('a hold does not stop the deactivation by a withdrawn publisher of '
      'an ancestor', () async {
    // from: dispose_hold_test.dart: a hold does not stop the deactivation by a
    // withdrawn publisher of an ancestor
    final log = <String>[];
    final app = await _running(
      Scope(
        components: [
          Component<String>(
            key: _k,
            dependency: Dependency<String>(
              create: () => 'k',
              dispose: (_) => log.add('k'),
            ),
          ),
        ],
      ),
    );
    final held = await _running(
      app.kid(
        components: [
          Component<String>(
            key: _a,
            dependency: Dependency.require<String>(key: _k).map<String>(
              (k) => 'reader of $k',
              dispose: (_) => log.add('reader'),
            ),
          ),
          Component<String>(
            key: _b,
            dependency: Dependency<String>(
              create: () => 'other',
              dispose: (_) => log.add('other'),
            ),
          ),
        ],
      ),
    );
    final hold = _hold(held);
    final disposal = held.dispose();

    rightOf(await rightOf(app.node<String>(key: _k)).dispose());
    expect(log, ['reader', 'k']);
    expect(held.getOption<String>(key: _a), isA<None>());
    expect(rightOf(held.get<String>(key: _b)), 'other');

    hold.close();
    rightOf(await disposal);
    expect(log, ['reader', 'k', 'other']);
    rightOf(await app.dispose());
  });

  test('a long wait is reported as slow work with its holds', () async {
    // from: dispose_hold_test.dart: a long wait is reported as slow work with
    // its holds
    final reports = <SlowMutation>[];
    final app = await _running(
      Scope(
        components: _app(),
        onSlowMutation: reports.add,
        slowMutationThreshold: const Duration(milliseconds: 20),
      ),
    );
    final held = await _running(
      app.kid(components: _single(<String>[], 'held', _a)),
    );
    final hold = _hold(held, 'page');
    final disposal = held.dispose();

    await pause(70);
    final waits = [
      for (final report in reports)
        if (report.operation == 'Scope.dispose (waiting for holds)') report,
    ];
    expect(waits.length, greaterThanOrEqualTo(2));
    expect(waits.first.queued, 0);
    expect([for (final h in waits.first.holds) h.debugLabel], ['page']);
    expect(waits.first.holds.single.scopePath, 'child scope 1');

    hold.close();
    rightOf(await disposal);
    final count = reports.length;
    await pause(50);
    expect(reports.length, count, reason: 'the report stops with the wait');
    rightOf(await app.dispose());
  });

  test('a call that ignores open holds reports IgnoredHoldsFailure', () async {
    // from: dispose_hold_test.dart: a call that ignores open holds reports
    // IgnoredHoldsException
    final errors = <Cause<DiFailure>>[];
    final app = await _running(Scope(components: _app()));
    final subscription = app.errors.listen(errors.add);
    final held = await _running(
      app.kid(components: _single(<String>[], 'held', _a)),
    );
    _hold(held, 'page');
    _hold(held);
    rightOf(await held.dispose(ignoreHolds: true));
    await pumpEventQueue();
    final ignored = [
      for (final cause in errors)
        ...cause.failures.whereType<IgnoredHoldsFailure>(),
    ];
    expect(ignored, hasLength(1));
    expect(
      [for (final h in ignored.single.holds) h.debugLabel],
      ['page', null],
    );
    expect(
      ignored.single.message,
      'a disposal ignored 2 open holds: page, hold',
    );

    final free = await _running(
      app.kid(components: _single(<String>[], 'free', _b)),
    );
    rightOf(await free.dispose(ignoreHolds: true));
    await pumpEventQueue();
    expect(errors.where(_isIgnoredHolds), hasLength(1));
    await subscription.cancel();
    rightOf(await app.dispose());
  });

  test('a call that joins a waiting disposal with ignoreHolds reports the '
      'holds after the transition that starts the disposal', () async {
    // from: dispose_hold_test.dart: a call that joins a waiting disposal with
    // ignoreHolds reports the holds after the transition that starts the
    // disposal
    final events = <String>[];
    final app = await _running(Scope(components: _app()));
    final held = await _running(
      app.kid(components: _single(<String>[], 'held', _a)),
    );
    final subscription = app.errors.listen((cause) {
      for (final failure in cause.failures.whereType<IgnoredHoldsFailure>()) {
        events.add('ignored ${failure.holds.single.debugLabel}');
      }
    });
    rightOf(
      app.addListener(() {
        if (held.state.phase == ScopePhase.disposing &&
            !events.contains('disposing')) {
          events.add('disposing');
        }
      }),
    );
    _hold(held, 'page');
    final waiting = held.dispose();
    await pumpEventQueue();
    expect(events, isEmpty);

    rightOf(await held.dispose(ignoreHolds: true));
    rightOf(await waiting);
    await pumpEventQueue();
    expect(events, ['disposing', 'ignored page']);
    await subscription.cancel();
    rightOf(await app.dispose());
  });

  test('the slow report of a waiting child stops when an ancestor ends its '
      'wait', () async {
    // from: dispose_hold_test.dart: the slow report of a waiting child stops
    // when an ancestor ends its wait
    final reports = <SlowMutation>[];
    final app = await _running(
      Scope(
        components: _app(),
        onSlowMutation: reports.add,
        slowMutationThreshold: const Duration(milliseconds: 20),
      ),
    );
    final parent = await _running(
      app.kid(components: _single(<String>[], 'parent', _a)),
    );
    final child = await _running(
      parent.kid(components: _single(<String>[], 'child', _b)),
    );
    _hold(child, 'sheet'); // never closes
    final childDisposal = child.dispose();
    await pause(50);
    expect(
      reports.where((r) => r.operation == 'Scope.dispose (waiting for holds)'),
      isNotEmpty,
    );

    rightOf(await parent.dispose(ignoreHolds: true));
    rightOf(await childDisposal);
    final count = reports.length;
    await pause(60);
    expect(reports.length, count);
    rightOf(await app.dispose());
  });

  test('a hold that a listener closes inside a mutation queues the disposal '
      'after that mutation', () async {
    // from: dispose_hold_test.dart: a hold that a listener closes inside a
    // mutation queues the disposal after that mutation
    final log = <String>[];
    final app = await _running(Scope(components: _app()));
    final held = await _running(app.kid(components: _single(log, 'held', _a)));
    final hold = _hold(held);
    final disposal = held.dispose();
    var closed = false;
    void closeOnce() {
      if (closed) return;
      closed = true;
      hold.close();
    }

    // The creation of a child is a transition outside a mutation, so the child
    // exists before the listener is added.
    final other = app.kid(components: _single(log, 'other', _b));
    rightOf(app.addListener(closeOnce));
    // This run is a mutation, and its transitions call the listener inside
    // it.
    rightOf(await other.run());
    expect(closed, isTrue);
    rightOf(await disposal);
    expect(log, ['held']);
    rightOf(await app.dispose());
  });

  test(
    'an ancestor that ignores the holds ends the wait of a descendant',
    () async {
      // from: dispose_hold_test.dart: an ancestor that ignores the holds ends
      // the wait of a descendant
      final log = <String>[];
      final parent = await _running(Scope(components: _single(log, 'p', _a)));
      final child = await _running(
        parent.kid(components: _single(log, 'c', _b)),
      );
      final hold = _hold(child);

      var childDone = false;
      final childDisposal = child.dispose();
      unawaited(childDisposal.then((_) => childDone = true));
      await pumpEventQueue();
      expect(childDone, isFalse);
      expect(log, isEmpty);

      rightOf(await parent.dispose(ignoreHolds: true));
      rightOf(await childDisposal);
      expect(childDone, isTrue);
      expect(log, ['c', 'p']);
      hold.close(); // after the disposal: changes nothing
    },
  );

  test(
    'ignoreHolds releases with a hold open, and a waiting call completes',
    () async {
      // from: dispose_hold_test.dart: ignoreHolds releases with a hold open,
      // and a waiting call completes
      final log = <String>[];
      final scope = await _running(Scope(components: _single(log, 's', _a)));
      _hold(scope); // never closes

      var waitingDone = false;
      final waiting = scope.dispose();
      unawaited(waiting.then((_) => waitingDone = true));
      await pumpEventQueue();
      expect(waitingDone, isFalse);

      rightOf(await scope.dispose(ignoreHolds: true));
      rightOf(await waiting);
      expect(waitingDone, isTrue);
      expect(log, ['s']);
    },
  );

  test('a disposal without holds starts at once, as before', () async {
    // from: dispose_hold_test.dart: a disposal without holds starts at once,
    // as before
    final log = <String>[];
    final scope = await _running(Scope(components: _single(log, 's', _a)));
    final hold = _hold(scope)..close();
    rightOf(await scope.dispose());
    expect(log, ['s']);
    hold.close();
  });

  test(
    'disposeHold after the request is a Left, and close is idempotent',
    () async {
      // from: dispose_hold_test.dart: disposeHold after the request throws, and
      // close is idempotent
      final log = <String>[];
      final scope = await _running(Scope(components: _single(log, 's', _a)));
      final child = await _running(scope.kid());
      final hold = _hold(scope);
      final disposal = scope.dispose();
      expect(leftOf(scope.disposeHold()), isA<DisposedScopeFailure>());
      expect(
        leftOf(child.disposeHold()),
        isA<DisposedScopeFailure>(),
        reason: 'the disposal of an ancestor counts',
      );

      hold.close();
      hold.close(); // a second close does nothing
      rightOf(await disposal);
      expect(log, ['s']);
      hold.close(); // a late close changes nothing
    },
  );

  test('a lazy creation in flight at the request continues, and the release '
      'awaits it', () async {
    // from: dispose_hold_test.dart: a lazy creation in flight at the request
    // continues, and the release awaits it
    final gate = Completer<String>();
    final released = <String>[];
    final scope = await _running(
      Scope(
        components: [
          Component<Lazy<String>>(
            key: _lazy,
            dependency: Dependency<String>(
              create: () => gate.future,
              dispose: released.add,
            ).lazy(),
          ),
        ],
      ),
    );
    final lazy = rightOf(scope.get<Lazy<String>>(key: _lazy));
    final hold = _hold(scope);
    final creation = lazy.force().run();
    final disposal = scope.dispose();

    gate.complete('late');
    expect(rightOf(await creation), 'late');
    expect(released, isEmpty);
    hold.close();
    rightOf(await disposal);
    // The release owns the value that the creation made.
    expect(released, ['late']);
  });

  test('the stack trace of a hold is recorded only with assertions', () async {
    // from: dispose_hold_test.dart: the stack trace of a hold is recorded only
    // with assertions
    final withAsserts = await _probe(enableAsserts: true);
    final without = await _probe(enableAsserts: false);
    expect(withAsserts['asserts'], isTrue);
    expect(withAsserts['trace'], contains('hold_probe.dart'));
    expect(without['asserts'], isFalse);
    expect(without['trace'], isNull);
  });

  test(
    'openHolds answers in every phase and lists nothing after the closes',
    () async {
      final scope = Scope(components: _app());
      expect(scope.openHolds, isEmpty);
      rightOf(await scope.run());
      final hold = _hold(scope, 'x');
      expect(
        scope.openHolds.single.toString(),
        startsWith('HoldState(x, scope'),
      );
      hold.close();
      expect(scope.openHolds, isEmpty);
      rightOf(await scope.dispose());
      expect(scope.openHolds, isEmpty);
    },
  );

  test('a hold of a declared scope delays the disposal, too', () async {
    final scope = Scope(components: _app());
    final hold = _hold(scope);
    final disposal = scope.dispose();
    await pumpEventQueue();
    expect(scope.phase, ScopePhase.disposeRequested);
    hold.close();
    rightOf(await disposal);
    expect(scope.phase, ScopePhase.disposed);
  });

  test('a disposal that waits does not block the queue of the root', () async {
    final app = await _running(Scope(components: _app()));
    final held = await _running(
      app.kid(components: _single(<String>[], 'held', _a)),
    );
    final hold = _hold(held);
    final disposal = held.dispose();
    final other = app.kid(components: _single(<String>[], 'other', _b));
    rightOf(await other.run().timeout(const Duration(seconds: 2)));
    expect(other.phase, ScopePhase.initialized);
    hold.close();
    rightOf(await disposal);
    rightOf(await app.dispose());
  });

  test('a hold opens inside a lifecycle operation', () async {
    final holds = <DisposeHold>[];
    final scope = Scope(
      components: [
        Component<String>.effect(
          dependency: Dependency<String>(create: () => 'effect'),
        ),
      ],
    );
    final app = Scope(components: _app());
    rightOf(
      app.addListener(() {
        // The listener runs inside the run of `app`.
        if (holds.isEmpty) holds.add(_hold(scope));
      }),
    );
    rightOf(await app.run());
    expect(holds, hasLength(1));
    holds.single.close();
    rightOf(await scope.dispose());
    rightOf(await app.dispose());
  });
}

/// Runs `hold_probe.dart` in a new process, with or without assertions, and
/// returns the JSON line that it prints.
Future<Map<String, Object?>> _probe({required bool enableAsserts}) async {
  final config = await Isolate.packageConfig;
  final library = await Isolate.resolvePackageUri(
    Uri.parse('package:fp_di_fpdart/fp_di_fpdart.dart'),
  );
  if (config == null || library == null) {
    fail('The package configuration of the test run is not available.');
  }
  final script = library.resolve('../test/support/hold_probe.dart');
  final result = await Process.run(Platform.resolvedExecutable, [
    '--packages=${config.toFilePath()}',
    if (enableAsserts) '--enable-asserts',
    script.toFilePath(),
  ]);
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  final line = (result.stdout as String).trim().split('\n').last;
  return (jsonDecode(line) as Map).cast<String, Object?>();
}
