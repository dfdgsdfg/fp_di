// Detection evidence of the random lifecycle histories (V-T-VR-TEST-006).
//
// Each control turns on one deliberate runtime defect or self-check fault,
// runs a short fuzz with a fixed seed, and passes only if the expected fuzz
// invariant reports a violation. A control that finds no violation fails
// with the switch, the expected prefix, the seed, and the prefixes it saw.
//
// kiri_check registers a property when `runBehavior` runs, and runs it in
// the same test after the body returns. The `onFalsify` callback records the
// reports, and a tear-down of that test resets the switches and asserts the
// detection. Setup, run, verdict, and reset stay in one test, so test order
// and name filters cannot separate them.
import 'package:fp_di/src/runtime/runtime_faults.dart';
import 'package:kiri_check/kiri_check.dart' show property;
import 'package:kiri_check/stateful_test.dart';
import 'package:test/test.dart';

import 'support/lifecycle_fuzz_harness.dart';

/// The switches of one control.
typedef _Switches = ({
  RuntimeDefect defect,
  RuntimeSelfCheckFault fault,
  bool muted,
});

/// One control: the switches it turns on, and the invariant that must fire.
final class _Control {
  const _Control(
    this.name,
    this.switches,
    this.prefix, {
    required this.seed,
    required this.graphs,
  });

  final String name;
  final _Switches switches;

  /// The prefix of a violation line, such as `StepSerial:`.
  final String prefix;
  final int seed;

  /// The number of graph descriptors that the control tries.
  final int graphs;

  /// The cycles and the maximum commands of each graph run. A sequence of
  /// 80 commands reaches the late calls that `LateCallNoop` needs.
  int get cycles => 40;
  int get steps => 80;
}

_Switches _defect(RuntimeDefect value) =>
    (defect: value, fault: RuntimeSelfCheckFault.none, muted: false);

_Switches _fault(RuntimeSelfCheckFault value, {required bool muted}) =>
    (defect: RuntimeDefect.none, fault: value, muted: muted);

const _seed = 20260601;

// The harness reaches no defect of `AtomicPublication`: a failed create
// stages nothing, so the fault has no staged value to publish.

final _controls = <_Control>[
  _Control(
    'RuntimeDefect.parallelSteps',
    _defect(RuntimeDefect.parallelSteps),
    'StepSerial:',
    seed: _seed,
    graphs: 2,
  ),
  _Control(
    'RuntimeDefect.acqOrder',
    _defect(RuntimeDefect.acqOrder),
    'StepOrder:',
    seed: _seed,
    graphs: 2,
  ),
  _Control(
    'RuntimeDefect.dropLease',
    _defect(RuntimeDefect.dropLease),
    'LeaseAccounted:',
    seed: _seed,
    graphs: 2,
  ),
  _Control(
    'RuntimeDefect.dropLater',
    _defect(RuntimeDefect.dropLater),
    'NoLostDisposeFailure:',
    seed: _seed,
    graphs: 2,
  ),
  _Control(
    'RuntimeDefect.secondCallerOk',
    _defect(RuntimeDefect.secondCallerOk),
    'CallersAgree:',
    seed: _seed,
    graphs: 8,
  ),
  _Control(
    'RuntimeDefect.replayAfterEnd',
    _defect(RuntimeDefect.replayAfterEnd),
    'LateCallNoop:',
    seed: _seed,
    graphs: 8,
  ),
  _Control(
    'RuntimeDefect.sequentialTeardown',
    _defect(RuntimeDefect.sequentialTeardown),
    'ReleaseOverlap:',
    seed: _seed,
    graphs: 2,
  ),
  _Control(
    'RuntimeDefect.silentReleaseStart',
    _defect(RuntimeDefect.silentReleaseStart),
    'RuntimeState:',
    seed: _seed,
    graphs: 2,
  ),
  _Control(
    'RuntimeDefect.lateReentrancyCheck',
    _defect(RuntimeDefect.lateReentrancyCheck),
    'NestedCall:',
    seed: _seed,
    graphs: 2,
  ),
  _Control(
    'RuntimeDefect.dropFailedNodes',
    _defect(RuntimeDefect.dropFailedNodes),
    'UnavailableCause:',
    seed: _seed,
    graphs: 2,
  ),
  _Control(
    'RuntimeDefect.farthestBinding',
    _defect(RuntimeDefect.farthestBinding),
    'ReadsCurrent:',
    seed: _seed,
    graphs: 2,
  ),
  _Control(
    'RuntimeDefect.keepThrowingListener',
    _defect(RuntimeDefect.keepThrowingListener),
    'ListenerFailure:',
    seed: _seed,
    graphs: 2,
  ),
  _Control(
    'RuntimeDefect.queueWithHolds',
    _defect(RuntimeDefect.queueWithHolds),
    'NoDisposalWhileHeld:',
    seed: _seed,
    graphs: 2,
  ),
  _Control(
    'RuntimeDefect.setupWhileHeld',
    _defect(RuntimeDefect.setupWhileHeld),
    'NoSetupAfterRequest:',
    seed: _seed,
    graphs: 4,
  ),
  _Control(
    'RuntimeDefect.dropIgnoredReport',
    _defect(RuntimeDefect.dropIgnoredReport),
    'IgnoredHoldsReported:',
    seed: _seed,
    graphs: 2,
  ),
  _Control(
    'RuntimeDefect.skipCheckpoint',
    _defect(RuntimeDefect.skipCheckpoint),
    'NoSetupAfterRequest:',
    seed: _seed,
    graphs: 2,
  ),
  _Control(
    'RuntimeDefect.loseHeldCaller',
    _defect(RuntimeDefect.loseHeldCaller),
    'HeldFuturesComplete:',
    seed: _seed,
    graphs: 8,
  ),
  _Control(
    'RuntimeSelfCheckFault.stateCurrent + muted',
    _fault(RuntimeSelfCheckFault.stateCurrent, muted: true),
    'RuntimeState:',
    seed: _seed,
    graphs: 2,
  ),
  _Control(
    'RuntimeSelfCheckFault.releaseAtMostOnce + muted',
    _fault(RuntimeSelfCheckFault.releaseAtMostOnce, muted: true),
    'ReleaseAtMostOnce:',
    seed: _seed,
    graphs: 2,
  ),
  _Control(
    'RuntimeSelfCheckFault.dependentFirst + muted',
    _fault(RuntimeSelfCheckFault.dependentFirst, muted: true),
    'DependentFirst:',
    seed: _seed,
    graphs: 2,
  ),
  _Control(
    'RuntimeSelfCheckFault.dependentFirst (not muted)',
    _fault(RuntimeSelfCheckFault.dependentFirst, muted: false),
    'ExplainedOutcome:',
    seed: _seed,
    graphs: 2,
  ),
];

/// The invariant prefixes of the violation lines in [report].
Set<String> _prefixesIn(String report) => {
  for (final line in report.split('\n'))
    if (RegExp(r'^\s+-\s+([A-Za-z]+):').firstMatch(line) case final m?)
      '${m.group(1)!}:',
};

void _apply(_Switches switches) {
  RuntimeFaults.defect = switches.defect;
  RuntimeFaults.selfCheck = switches.fault;
  RuntimeFaults.selfChecksMuted = switches.muted;
}

/// Runs the fixed history of the `DropLate` counterexample on graph 0 of
/// [_seed]: `InitializeScope(root)`, `StartDispose(root)`,
/// `Resolve(create, complete)`, `Resolve(dispose, fail)`, `Terminal`. The
/// `initialize` completes its create after the disposal of its scope was
/// requested, and its rollback release fails. The history names gates by
/// position, so every callback of the graph is a gate.
Future<void> _lateDisposeFailureHistory() async {
  final harness = Harness(buildGraph(_seed, 0, gatesOnly: true));
  try {
    await harness.initializeScope(0);
    await harness.startDispose(0);
    await harness.resolve('create', 'complete', 0);
    await harness.resolve('dispose', 'fail', 0);
    await harness.terminal();
  } finally {
    await harness.close();
  }
}

/// The graph of the `NoStepAfterCancel` counterexample: the root scope has one
/// component of two steps, and every callback is a gate.
GraphDesc _twoStepGraph() => GraphDesc(_seed, 0, const [
  ScopeDesc(-1, [
    NodeDesc(
      's0n0',
      0,
      PubDesc.key('a'),
      [],
      2,
      creates: [
        CallbackDesc(CallbackMode.gate),
        CallbackDesc(CallbackMode.gate),
      ],
      disposes: [
        CallbackDesc(CallbackMode.gate),
        CallbackDesc(CallbackMode.gate),
      ],
    ),
  ]),
]);

/// Runs the fixed history of the `NoStepAfterCancel` counterexample:
/// `InitializeScope(root)`, `StartDispose(root)`, `Resolve(create, complete)`,
/// `Terminal`. The disposal of the scope is requested while the first create
/// of the two-step component waits on its gate. The gate completes after the
/// request, so the checkpoint between the steps MUST stop the second create.
Future<void> _stepAfterCancelHistory() async {
  final harness = Harness(_twoStepGraph());
  try {
    await harness.initializeScope(0);
    await harness.startDispose(0);
    await harness.resolve('create', 'complete', 0);
    await harness.terminal();
  } finally {
    await harness.close();
  }
}

void main() {
  tearDown(RuntimeFaults.reset);

  for (final control in _controls) {
    property('control ${control.name} detects ${control.prefix}', () {
      // The prefixes that each graph run reported, by graph index.
      final seen = <int, Set<String>>{};
      // The graph runs that reported a violation with the expected prefix.
      final detected = <int>{};
      _apply(control.switches);
      addTearDown(() {
        RuntimeFaults.reset();
        if (detected.isNotEmpty) return;
        final report = seen.isEmpty
            ? 'no graph run reported any violation'
            : seen.entries
                  .map((e) => 'graph ${e.key}: ${e.value.toList()..sort()}')
                  .join('; ');
        fail(
          'Control ${control.name} was not detected. '
          'Expected a ${control.prefix} violation with seed=${control.seed} '
          'over ${control.graphs} graphs. Saw: $report',
        );
      });
      for (var g = 0; g < control.graphs; g++) {
        final graph = buildGraph(control.seed, g);
        runBehavior<FuzzModel, Harness>(
          FuzzBehavior(graph),
          seed: graph.propertySeed,
          maxCycles: control.cycles,
          maxSteps: control.steps,
          maxCommandTries: control.steps * 12,
          maxShrinkingCycles: 0,
          ignoreFalsify: true,
          onFalsify: (example) {
            final error = example.exception;
            final report = error is HistoryViolation
                ? error.report
                : 'non-violation: $error';
            final prefixes = _prefixesIn(report);
            seen[g] = prefixes;
            if (prefixes.contains(control.prefix)) detected.add(g);
          },
        );
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  }

  group('control RuntimeDefect.dropLate on its fixed history', () {
    test('the history passes without the defect', _lateDisposeFailureHistory);

    test('detects NoLostDisposeFailure:', () async {
      RuntimeFaults.defect = RuntimeDefect.dropLate;
      await expectLater(
        _lateDisposeFailureHistory(),
        throwsA(
          isA<HistoryViolation>().having(
            (v) => _prefixesIn(v.report),
            'reported checks',
            contains('NoLostDisposeFailure:'),
          ),
        ),
      );
    });
  });

  group('control RuntimeDefect.skipCheckpoint on its fixed history', () {
    test('the history passes without the defect', _stepAfterCancelHistory);

    test('detects NoSetupAfterRequest:', () async {
      RuntimeFaults.defect = RuntimeDefect.skipCheckpoint;
      await expectLater(
        _stepAfterCancelHistory(),
        throwsA(
          isA<HistoryViolation>().having(
            (v) => _prefixesIn(v.report),
            'reported checks',
            contains('NoSetupAfterRequest:'),
          ),
        ),
      );
    });
  });
}
