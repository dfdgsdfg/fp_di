// Random lifecycle histories (V-T-VR-TEST-005).
//
// One `runBehavior` of kiri_check runs for each seeded graph descriptor. A
// command sequence drives a tree of up to four scopes: the root, its first
// child, and as drawn a second child of the root and a child of the first
// child.
// Each `create` and `dispose` callback has a mode that the graph fixes: it
// waits on a gate that the harness owns, it settles at once, or it settles in
// a microtask. A sequence explores the order of the gate completions.
// The graph also fixes call sites: the start of a `create` or of a `dispose`
// callback, the listener of a scope, and the `errors` subscriber read their
// scope and request a disposal (`NestedCall`). One listener throws at a fixed
// call (`ListenerFailure`).
// After each command, `get` of each key without a value names the failed nodes
// behind the key (`UnavailableCause`). At the start of each case,
// `Module.requiring` and `Module.withoutRequiring` of each module match a fixed
// point of the harness (`RequiringPartition`).
//
// Environment variables:
//   FP_DI_FUZZ_SEED    run seed (default 20260601)
//   FP_DI_FUZZ_CYCLES  cycles (command sequences) for each graph (default 40)
//   FP_DI_FUZZ_GRAPHS  number of graph descriptors (default 8)
//   FP_DI_FUZZ_STEPS   maximum commands in a sequence (default 40)
import 'dart:io';

import 'package:kiri_check/kiri_check.dart' show property;
import 'package:kiri_check/stateful_test.dart';
import 'package:test/test.dart';

import 'support/lifecycle_fuzz_harness.dart';

/// Parses a set environment variable strictly. A value that is not an
/// integer, or that is below [min], ends the run before any case runs.
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

// ---------------------------------------------------------------------------

void main() {
  final seed = _env('FP_DI_FUZZ_SEED', 20260601);
  final cycles = _env('FP_DI_FUZZ_CYCLES', 40, min: 1);
  final graphs = _env('FP_DI_FUZZ_GRAPHS', 8, min: 1);
  final steps = _env('FP_DI_FUZZ_STEPS', 40, min: 1);
  // ignore: avoid_print
  print(
    'lifecycle fuzz: seed=$seed cycles=$cycles graphs=$graphs steps=$steps '
    '(FP_DI_FUZZ_SEED, FP_DI_FUZZ_CYCLES, FP_DI_FUZZ_GRAPHS, '
    'FP_DI_FUZZ_STEPS)',
  );

  tearDownAll(() {
    // ignore: avoid_print
    print('lifecycle fuzz coverage: ${FuzzStats.summary()}');
    // A run without these events checks no invariant.
    final missing = [
      if (FuzzStats.initialized == 0) 'successful root initialize',
      if (FuzzStats.acquisitions == 0) 'completed create',
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

  for (var g = 0; g < graphs; g++) {
    final graph = buildGraph(seed, g);
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
            ..writeln(shapeReport(graph))
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
