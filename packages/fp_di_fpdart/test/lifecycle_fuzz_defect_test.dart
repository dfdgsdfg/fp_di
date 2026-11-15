// Detection evidence of the random lifecycle histories.
//
// Each control turns on one deliberate runtime defect, runs a short fuzz with a
// fixed seed, and passes only if the expected fuzz invariant reports a
// violation. A control that finds no violation fails with the switch, the
// expected prefix, the seed, and the prefixes it saw.
//
// kiri_check registers a property when `runBehavior` runs, and runs it in the
// same test after the body returns. The `onFalsify` callback records the
// reports, and a tear-down of that test resets the switches and asserts the
// detection. Setup, run, verdict, and reset stay in one test, so test order
// and name filters cannot separate them.
import 'package:fp_di_fpdart/src/faults.dart';
import 'package:kiri_check/kiri_check.dart' show property;
import 'package:kiri_check/stateful_test.dart';
import 'package:test/test.dart';

import 'support/lifecycle_fuzz_harness.dart';

/// One control: the defect it turns on, and the invariant that must fire.
final class _Control {
  const _Control(
    this.defect,
    this.prefix, {
    this.graphs = 12,
    this.fixed = false,
  });

  final Defect defect;

  /// The prefix of a violation line, such as `StepSerial:`.
  final String prefix;

  /// The number of graph descriptors that the control tries.
  final int graphs;

  /// Whether the control runs the fixed history of each graph, where a random
  /// history reaches the condition rarely.
  final bool fixed;

  String get name => 'Defect.${defect.name}';

  /// The cycles and the maximum commands of each graph run. A sequence of 80
  /// commands reaches the late calls that `LateCallNoop` needs.
  int get cycles => 40;
  int get steps => 80;
}

const _seed = 20260601;

final _controls = <_Control>[
  const _Control(Defect.parallelSteps, 'StepSerial:'),
  const _Control(Defect.acqOrder, 'StepOrder:'),
  const _Control(Defect.dropLease, 'LeaseAccounted:'),
  const _Control(Defect.secondCallerOk, 'CallersAgree:', graphs: 48),
  const _Control(Defect.replayAfterEnd, 'LateCallNoop:', graphs: 48),
  const _Control(Defect.silentReleaseStart, 'RuntimeState:'),
  const _Control(Defect.lateReentrancyCheck, 'NestedCall:', graphs: 48),
  const _Control(Defect.dropFailedNodes, 'UnavailableCause:', fixed: true),
  const _Control(Defect.farthestBinding, 'ReadsCurrent:', fixed: true),
  const _Control(Defect.queueWithHolds, 'NoDisposalWhileHeld:'),
  const _Control(Defect.dropIgnoredReport, 'IgnoredHoldsReported:'),
  const _Control(Defect.loseHeldCaller, 'HeldCallersComplete:', graphs: 48),
  const _Control(Defect.skipCheckpoint, 'NoSetupAfterRequest:', graphs: 48),
];

/// The violation prefixes in [report], such as `StepSerial:`.
Set<String> _prefixesIn(String report) => {
  for (final line in report.split('\n'))
    if (RegExp(r'^[A-Z][A-Za-z]+:').firstMatch(line) case final match?)
      match.group(0)!,
};

/// Runs the fixed history of [graph], and returns the report of the violation
/// that ended it, or `null`.
Future<String?> _fixedHistory(GraphDesc graph) async {
  final harness = Harness(graph)..createRoot();
  try {
    await harness.fixedHistory();
    return null;
  } on HistoryViolation catch (violation) {
    return violation.report;
  } finally {
    await harness.close();
  }
}

String _seenReport(Map<int, Set<String>> seen) => seen.isEmpty
    ? 'no graph run reported any violation'
    : seen.entries
          .map((e) => 'graph ${e.key}: ${e.value.toList()..sort()}')
          .join('; ');

void main() {
  tearDown(RuntimeFaults.reset);

  test('every defect has a control', () {
    expect({
      for (final control in _controls) control.defect,
    }, Defect.values.toSet()..remove(Defect.none));
  });

  for (final control in _controls.where((c) => !c.fixed)) {
    // from: lifecycle_fuzz_defect_test.dart: control ${control.name}
    // detects ${control.prefix}
    property('control ${control.name} detects ${control.prefix}', () {
      // The prefixes that each graph run reported, by graph index.
      final seen = <int, Set<String>>{};
      // The graph runs that reported a violation with the expected prefix.
      final detected = <int>{};
      RuntimeFaults.defect = control.defect;
      RuntimeFaults.selfChecksMuted = true;
      addTearDown(() {
        RuntimeFaults.reset();
        if (detected.isNotEmpty) return;
        fail(
          'Control ${control.name} was not detected. Expected a '
          '${control.prefix} violation with seed=$_seed over '
          '${control.graphs} graphs. Saw: ${_seenReport(seen)}',
        );
      });
      for (var g = 0; g < control.graphs; g++) {
        final graph = buildGraph(_seed, g);
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

  // A random history reaches these conditions rarely. The fixed history of a
  // graph reaches them, so the control runs it.
  for (final control in _controls.where((c) => c.fixed)) {
    group('control ${control.name} on fixed histories', () {
      test('the histories pass without the defect', () async {
        RuntimeFaults.selfChecksMuted = true;
        for (var g = 0; g < control.graphs; g++) {
          expect(await _fixedHistory(buildGraph(_seed, g)), isNull);
        }
      });

      test('detects ${control.prefix}', () async {
        RuntimeFaults.defect = control.defect;
        RuntimeFaults.selfChecksMuted = true;
        final seen = <int, Set<String>>{};
        var detected = false;
        for (var g = 0; g < control.graphs; g++) {
          final report = await _fixedHistory(buildGraph(_seed, g));
          if (report == null) continue;
          final prefixes = _prefixesIn(report);
          seen[g] = prefixes;
          detected |= prefixes.contains(control.prefix);
        }
        expect(
          detected,
          isTrue,
          reason:
              'Expected a ${control.prefix} violation over '
              '${control.graphs} graphs. Saw: ${_seenReport(seen)}',
        );
      });
    });
  }
}
