// V-T-RT-LC-026: each runtime self-check fails with an AssertionError that
// names it, when a test-only fault breaks its invariant.
import 'dart:async';

import 'package:fp_di/fp_di.dart';
import 'package:fp_di/src/runtime/runtime_faults.dart';
import 'package:test/test.dart';

/// Pumps the event loop so that every ready continuation runs.
Future<void> _pump() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// The `AssertionError` in [error], or in the cause chain of a lifecycle
/// exception that wraps it, or null.
AssertionError? _assertionIn(Object? error) => switch (error) {
  AssertionError() => error,
  ActivationException(:final cause) => _assertionIn(cause),
  ActivationCanceledException(:final cause) => _assertionIn(cause),
  _ => null,
};

/// Runs [scenario] and returns the self-check failure it ended with.
Future<AssertionError?> _failureOf(Future<void> Function() scenario) async {
  try {
    await scenario();
  } on Object catch (error) {
    return _assertionIn(error);
  }
  return null;
}

final _a = DiKey<int>(name: 'a');
final _b = DiKey<int>(name: 'b');

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

/// A scenario for each fault. Without the fault, it ends without an
/// AssertionError.
final Map<RuntimeSelfCheckFault, Future<void> Function()> _scenarios = {
  RuntimeSelfCheckFault.releaseAtMostOnce: () async {
    final di = Scope(
      module: Module(components: [_valued(_a, dispose: (_) {})]),
    );
    await di.initialize();
    await di.dispose();
  },
  RuntimeSelfCheckFault.dependentFirst: () async {
    final di = Scope(
      module: Module(components: [_valued(_a), _reader(_b, _a)]),
    );
    await di.initialize();
    try {
      // The publisher releases while its dependent is active.
      await di.node<int>(key: _a).dispose();
    } finally {
      await _quietly(di.dispose());
    }
  },
  RuntimeSelfCheckFault.closedActivation: () async {
    final di = Scope(
      module: Module(components: [_valued(_a, dispose: (_) {})]),
    );
    try {
      await di.initialize();
    } finally {
      await _quietly(di.dispose());
    }
  },
  RuntimeSelfCheckFault.atomicPublication: () async {
    final started = Completer<void>();
    final gate = Completer<void>();
    final di = Scope(
      module: Module(
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
      ),
    );
    final initialized = di.initialize();
    await started.future;
    // The disposal request cancels the activation. Its step ends later, and
    // the activation fails after it staged its publisher.
    final disposed = di.dispose();
    gate.complete();
    try {
      await initialized;
    } finally {
      await _quietly(disposed);
    }
  },
  RuntimeSelfCheckFault.readsWithinShape: () async {
    final di = Scope(
      module: Module(components: [_valued(_a), _reader(_b, _a)]),
    );
    try {
      await di.initialize();
    } finally {
      await _quietly(di.dispose());
    }
  },
  RuntimeSelfCheckFault.stateCurrent: () async {
    final di = Scope(module: Module(components: [_valued(_a)]));
    // The reader waits for the key of the parent. The commit of the parent
    // changes its missing keys, and the fault does not refresh them.
    final child = di.child(module: Module(components: [_reader(_b, _a)]));
    await child.initialize();
    try {
      await di.initialize();
    } finally {
      await _quietly(di.dispose());
    }
  },
  RuntimeSelfCheckFault.serialMutations: () async {
    final started = Completer<void>();
    final gate = Completer<void>();
    final di = Scope(
      module: Module(
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
      ),
    );
    final first = di.initialize();
    await started.future;
    // The second mutation queues behind the first. The fault removes the wait.
    final second = di
        .child(module: Module(components: [_valued(_b)]))
        .initialize();
    // The fault fails the second mutation before the first one ends.
    second.ignore();
    await _pump();
    gate.complete();
    try {
      await second;
    } finally {
      await _quietly(first);
      await _quietly(di.dispose());
    }
  },
};

Future<void> _quietly(Future<void> future) async {
  try {
    await future;
  } on Object {
    // The scenario already has its result.
  }
}

void main() {
  tearDown(RuntimeFaults.reset);

  test('the test run has assertions enabled', () {
    var enabled = false;
    assert(enabled = true);
    expect(enabled, isTrue);
  });

  test('every fault has a scenario', () {
    expect(
      _scenarios.keys.toSet(),
      RuntimeSelfCheckFault.values.toSet()..remove(RuntimeSelfCheckFault.none),
    );
  });

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
}
