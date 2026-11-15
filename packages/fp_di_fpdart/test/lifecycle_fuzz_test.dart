// Random lifecycle histories.
//
// One `runBehavior` of kiri_check runs for each seeded graph descriptor. A
// command sequence drives a tree of two or three scopes: it creates the
// scopes, runs them, also before their parents, disposes them, also with the
// holds of a disposal open, disposes one node, and completes or fails one gate
// of a callback. See the harness for the invariants and their prefixes.
//
// Environment variables:
//   FP_DI_FUZZ_SEED    run seed (default 20260601)
//   FP_DI_FUZZ_CYCLES  cycles (command sequences) for each graph (default 30)
//   FP_DI_FUZZ_GRAPHS  number of graph descriptors (default 8)
//   FP_DI_FUZZ_STEPS   maximum commands in a sequence (default 40)
import 'dart:io';

import 'package:fp_di_fpdart/src/faults.dart';
import 'package:kiri_check/kiri_check.dart' show property;
import 'package:kiri_check/stateful_test.dart';
import 'package:test/test.dart';

import 'support/lifecycle_fuzz_harness.dart';

/// Parses a set environment variable strictly. A value that is not an integer,
/// or that is below [min], ends the run before any case runs.
int _env(String name, int fallback, {int? min}) {
  final text = Platform.environment[name];
  if (text == null) return fallback;
  final value = int.tryParse(text.trim());
  if (value == null) {
    throw ArgumentError.value(text, name, 'is not an integer');
  }
  if (min != null && value < min) {
    throw ArgumentError.value(text, name, 'must be at least $min');
  }
  return value;
}

void main() {
  final seed = _env('FP_DI_FUZZ_SEED', 20260601);
  final cycles = _env('FP_DI_FUZZ_CYCLES', 30, min: 1);
  final graphs = _env('FP_DI_FUZZ_GRAPHS', 8, min: 1);
  final steps = _env('FP_DI_FUZZ_STEPS', 40, min: 1);
  // ignore: avoid_print
  print(
    'lifecycle fuzz: seed=$seed cycles=$cycles graphs=$graphs steps=$steps '
    '(FP_DI_FUZZ_SEED, FP_DI_FUZZ_CYCLES, FP_DI_FUZZ_GRAPHS, '
    'FP_DI_FUZZ_STEPS)',
  );

  // The snapshots of the runtime are compared with a state that the runtime
  // builds from its records at every read.
  setUpAll(() => RuntimeFaults.verifySnapshots = true);
  tearDownAll(() {
    RuntimeFaults.reset();
    // ignore: avoid_print
    print('lifecycle fuzz coverage: ${FuzzStats.summary()}');
    // A run without these events checks no invariant.
    final missing = [
      if (FuzzStats.initialized == 0) 'successful root run',
      if (FuzzStats.creates == 0) 'completed create',
      if (FuzzStats.teardowns == 0) 'checked teardown',
      if (FuzzStats.transitions == 0) 'listener call of a transition',
      ...FuzzStats.missingFloors(),
    ];
    if (missing.isNotEmpty) {
      throw StateError(
        'The run had no ${missing.join(', no ')}; it does not reach every '
        'coverage floor. ${FuzzStats.summary()}',
      );
    }
  });

  // A random history reaches a key behind a failed node and a nested dispose
  // call rarely. A fixed history of a graph that holds them reaches both.
  test('a fixed history reaches a key behind a failed node and a nested '
      'call', () async {
    for (var g = 0; g < 400; g++) {
      if (FuzzStats.nestedCalls > 0 && FuzzStats.failedBehind > 0) break;
      final graph = buildGraph(seed, g);
      final hasNested = graph.scopes.any(
        (scope) => scope.nodes.any((node) => node.nested),
      );
      if (!hasNested && g.isOdd) continue;
      final harness = Harness(graph)..createRoot();
      try {
        await harness.fixedHistory();
      } finally {
        await harness.close();
      }
    }
    expect(FuzzStats.nestedCalls, greaterThan(0));
    expect(FuzzStats.failedBehind, greaterThan(0));
  });

  for (var g = 0; g < graphs; g++) {
    final graph = buildGraph(seed, g);
    // from: lifecycle_fuzz_test.dart: seed=$seed graph=$g
    property('seed=$seed graph=$g', () {
      runBehavior<FuzzModel, Harness>(
        FuzzBehavior(graph),
        seed: graph.propertySeed,
        maxCycles: cycles,
        maxSteps: steps,
        maxCommandTries: steps * 12,
        onFalsify: (example) {
          final out = StringBuffer()
            ..writeln('=== lifecycle fuzz failure ===')
            ..writeln('run seed: $seed (FP_DI_FUZZ_SEED=$seed)')
            ..writeln('graph index: $g')
            ..writeln(graph.describe())
            ..writeln('Reduced command sequence:');
          for (final step in example.falsifyingSteps) {
            final value = step.value;
            out.writeln(
              '  ${step.number + 1}. ${step.command.description}'
              '${value == null ? '' : ' $value'}',
            );
          }
          // ignore: avoid_print
          print(out);
        },
      );
    }, timeout: const Timeout(Duration(minutes: 10)));
  }
}
