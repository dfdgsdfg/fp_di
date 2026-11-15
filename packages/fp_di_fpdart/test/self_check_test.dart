// Each runtime self-check fails with an AssertionError that names it, when a
// test-only fault breaks its invariant.
import 'dart:async';

import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fp_di_fpdart/src/faults.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Pumps the event loop so that every ready continuation runs.
Future<void> _pump() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// The `AssertionError` in [result]: the error itself, an error that a step
/// threw and that an activation failure holds, or a defect of a cause.
AssertionError? _assertionIn(Object? result) => switch (result) {
  AssertionError() => result,
  Left(value: final Cause<DiFailure> cause) => _assertionInCause(cause),
  _ => null,
};

AssertionError? _assertionInCause(Cause<DiFailure> cause) {
  for (final failure in cause.failures) {
    if (failure is ActivationFailure && failure.error is AssertionError) {
      return failure.error as AssertionError;
    }
  }
  for (final defect in cause.defects) {
    if (defect is AssertionError) return defect;
  }
  return null;
}

/// Runs [scenario] and returns the self-check failure it ended with: the error
/// that it threw, or the failure that its result holds.
Future<AssertionError?> _failureOf(Future<Object?> Function() scenario) async {
  try {
    return _assertionIn(await scenario());
  } on Object catch (error) {
    return _assertionIn(error);
  }
}

const _a = DiKey<int>(name: 'a');
const _b = DiKey<int>(name: 'b');

Component<int> _valued(DiKey<int> key, {void Function(int)? dispose}) =>
    Component<int>(
      dependency: Dependency<int>(create: () => 1, dispose: dispose),
      key: key,
    );

/// A component that reads [from] and publishes [key].
Component<int> _reader(DiKey<int> key, DiKey<int> from) => Component<int>(
  dependency: Dependency.require<int>(key: from).map((v) => v + 1),
  key: key,
);

Future<void> _quietly(Future<Object?> future) async {
  try {
    await future;
  } on Object {
    // The scenario already has its result.
  }
}

/// A scenario for each fault. Without the fault, it ends without an
/// AssertionError.
final Map<SelfCheckFault, Future<Object?> Function()> _scenarios = {
  SelfCheckFault.releaseAtMostOnce: () async {
    final di = Scope(components: [_valued(_a, dispose: (_) {})]);
    rightOf(await di.run());
    return di.dispose();
  },
  SelfCheckFault.dependentFirst: () async {
    final di = Scope(components: [_valued(_a), _reader(_b, _a)]);
    rightOf(await di.run());
    try {
      // The publisher releases while its dependent is active.
      return await rightOf(di.node<int>(key: _a)).dispose();
    } finally {
      await _quietly(di.dispose());
    }
  },
  SelfCheckFault.noCommitAfterCancel: () async {
    final started = Completer<void>();
    final gate = Completer<void>();
    final di = Scope(
      components: [
        Component<int>(
          dependency: Dependency<int>(
            create: () async {
              started.complete();
              await gate.future;
              return 1;
            },
          ),
          key: _a,
        ),
      ],
    );
    final run = di.run();
    await started.future;
    // The disposal request cancels the activation. Its step ends later, and
    // the activation commits when the fault removes the guard.
    final disposed = di.dispose();
    gate.complete();
    try {
      return await run;
    } finally {
      await _quietly(disposed);
    }
  },
  SelfCheckFault.readsWithinShape: () async {
    final di = Scope(components: [_valued(_a), _reader(_b, _a)]);
    try {
      return await di.run();
    } finally {
      await _quietly(di.dispose());
    }
  },
  SelfCheckFault.snapshotsCurrent: () async {
    RuntimeFaults.verifySnapshots = true;
    final di = Scope(components: [_valued(_a)]);
    // The reader waits for the key of the parent. The commit of the parent
    // changes its missing keys, and the fault does not find the change.
    final child = rightOf(di.child(components: [_reader(_b, _a)]));
    rightOf(await child.run());
    expect(child.state.nodeStates.single.missing, [_a]);
    try {
      rightOf(await di.run());
      return child.state;
    } finally {
      await _quietly(di.dispose());
    }
  },
  SelfCheckFault.serialMutations: () async {
    final started = Completer<void>();
    final gate = Completer<void>();
    final di = Scope(
      components: [
        Component<int>(
          dependency: Dependency<int>(
            create: () async {
              started.complete();
              await gate.future;
              return 1;
            },
          ),
          key: _a,
        ),
      ],
    );
    final first = di.run();
    await started.future;
    // The second operation queues behind the first. The fault removes the
    // wait.
    final second = rightOf(di.child(components: [_valued(_b)])).run();
    // The fault fails the second operation before the first one ends.
    unawaited(second.then<void>((_) {}, onError: (Object _) {}));
    await _pump();
    gate.complete();
    try {
      return await second;
    } finally {
      await _quietly(first);
      await _quietly(di.dispose());
    }
  },
};

void main() {
  tearDown(RuntimeFaults.reset);

  test('the test run has assertions enabled', () {
    // from: self_check_test.dart: the test run has assertions enabled
    var enabled = false;
    assert(enabled = true);
    expect(enabled, isTrue);
  });

  test('every fault has a scenario', () {
    // from: self_check_test.dart: every fault has a scenario
    expect(
      _scenarios.keys.toSet(),
      SelfCheckFault.values.toSet()..remove(SelfCheckFault.none),
    );
  });

  // from: self_check_test.dart: $name passes without its fault
  // from: self_check_test.dart: $name fails with its fault
  for (final MapEntry(key: fault, value: scenario) in _scenarios.entries) {
    final name = fault.name[0].toUpperCase() + fault.name.substring(1);

    test('$name passes without its fault', () async {
      expect(await _failureOf(scenario), isNull);
    });

    test('$name fails with its fault', () async {
      RuntimeFaults.selfCheck = fault;
      final failure = await _failureOf(scenario);
      expect(failure, isNotNull, reason: 'the fault must trip the self-check');
      expect(failure!.message.toString(), contains('SelfCheck $name'));
    });
  }

  test('a muted self-check does not fail', () async {
    RuntimeFaults.selfChecksMuted = true;
    RuntimeFaults.selfCheck = SelfCheckFault.readsWithinShape;
    // The check passes without evaluation, so the reads of the fixture work.
    expect(
      await _failureOf(_scenarios[SelfCheckFault.readsWithinShape]!),
      isNull,
    );
  });
}
