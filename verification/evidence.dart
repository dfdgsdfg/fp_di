// Pure evidence rules of the formal verification runner.
//
// `check.dart` runs TLC and writes `report.json`; this library decides what a
// TLC log means and whether a report is complete evidence. It has no I/O, so
// `verification/test/evidence_test.dart` checks it with synthetic logs and
// reports (V-T-VR-FORM-004). See specs/verification/formal/spec.md.

/// The outcome of one TLC run: `'pass'`, `{'invariant': name}`,
/// `{'temporal': name}`, or `'incomplete'`.
///
/// Only a run that TLC finished normally counts:
///
/// - A tool failure anywhere in the log, such as a Java exception, an
///   out-of-memory error, or an evaluation error, makes the run incomplete,
///   whatever else it printed.
/// - The exit code must match the outcome: 0 for a pass, 12 for an invariant
///   violation, 13 for a temporal violation. A run without an exit code timed
///   out; any other code, such as 137 for a killed process, is incomplete.
/// - A violation counts only with its whole counterexample: every state of
///   the trace has a body, a temporal trace closes its lasso with
///   `Stuttering` or `Back to state`, and the run then printed its
///   `Finished in` line. A trace cut while TLC printed it is incomplete.
///
/// A temporal violation is attributed only when the configuration checks
/// exactly one property, because TLC does not name the violated one.
Object classify(String log, int? exitCode, List<String> properties) {
  if (exitCode == null || _toolFailure.hasMatch(log)) return 'incomplete';
  final invariant = RegExp(r'Invariant (\w+) is violated').firstMatch(log);
  if (invariant != null) {
    if (exitCode != 12 ||
        !_completeTrace(log, 'The behavior up to this point is:')) {
      return 'incomplete';
    }
    return {'invariant': invariant.group(1)};
  }
  if (log.contains('Temporal properties were violated')) {
    if (properties.length != 1 ||
        exitCode != 13 ||
        !_completeTrace(
          log,
          'The following behavior constitutes a counter-example:',
          lasso: true,
        )) {
      return 'incomplete';
    }
    return {'temporal': properties.single};
  }
  if (log.contains('Model checking completed. No error has been found.') &&
      exitCode == 0) {
    return 'pass';
  }
  return 'incomplete';
}

/// Markers of a failure of TLC or of the JVM, not of the model.
final RegExp _toolFailure = RegExp(
  r'java\.lang\.|Exception in thread|OutOfMemoryError|StackOverflowError|'
  r'TLC threw an unexpected exception|Error: Attempted|'
  r'The error occurred when TLC was evaluating',
);

/// Whether the counterexample after [header] was printed whole: at least one
/// state, a body for every state, the end of the lasso when [lasso], and
/// TLC's `Finished in` line after it.
bool _completeTrace(String log, String header, {bool lasso = false}) {
  final start = log.indexOf(header);
  if (start < 0) return false;
  final end = log.indexOf('Finished in', start);
  if (end < 0) return false;
  final lines = log
      .substring(start + header.length, end)
      .split('\n')
      .map((line) => line.trimRight())
      .toList();
  final stateLine = RegExp(r'^State \d+:');
  var states = 0;
  var closed = false;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.contains('Stuttering') || line.contains('Back to state')) {
      closed = true;
      continue;
    }
    if (!stateLine.hasMatch(line)) continue;
    states++;
    // The next non-empty line is the state's body, not the next header.
    final body = lines
        .skip(i + 1)
        .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    if (body.isEmpty || stateLine.hasMatch(body)) return false;
  }
  return states > 0 && (!lasso || closed);
}

/// The indented entries that follow [header] in a TLC configuration.
List<String> section(String cfg, String header) {
  final lines = cfg.split('\n');
  final start = lines.indexWhere((l) => l.trim() == header);
  if (start < 0) return const [];
  return lines
      .skip(start + 1)
      .takeWhile((l) => l.startsWith(' '))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
}

/// `'incomplete'`, `'ok'` when [observed] equals [expected], or
/// `'unexpected'`.
String scenarioStatus(Object observed, Object expected) {
  if (observed == 'incomplete') return 'incomplete';
  return _same(observed, expected) ? 'ok' : 'unexpected';
}

/// The fields that every report, model entry, and scenario entry must have.
const reportFields = ['runId', 'status', 'tool', 'assumptions', 'models'];
const toolFields = ['tlc', 'tlcSha256', 'java', 'lockSha256'];
const modelFields = ['model', 'modelSha256', 'sources', 'scenarios'];
const scenarioFields = [
  'name',
  'config',
  'configSha256',
  'constants',
  'invariants',
  'properties',
  'expected',
  'observed',
  'status',
  'exitCode',
  'durationMs',
  'log',
];

/// Every reason that [report] is not complete, passing evidence. Empty means
/// the report is complete, every scenario has its expected outcome, and its
/// status says `passed`.
///
/// A scenario counts only when its observed outcome equals its expected one
/// and its run completed with state counts. A report that claims `passed`
/// while a scenario does not count is inconsistent.
List<String> reportProblems(Map<String, Object?> report) {
  final problems = <String>[];
  void missing(String where, Map<String, Object?> map, List<String> fields) {
    for (final field in fields) {
      if (map[field] == null) problems.add('$where: missing $field');
    }
  }

  missing('report', report, reportFields);
  final tool = report['tool'];
  if (tool is Map<String, Object?>) missing('tool', tool, toolFields);
  final models = report['models'];
  if (models is! List || models.isEmpty) {
    problems.add('report: no model');
    return problems;
  }
  var scenarioCount = 0;
  for (final model in models.cast<Map<String, Object?>>()) {
    final name = '${model['model']}';
    missing(name, model, modelFields);
    final scenarios = model['scenarios'];
    if (scenarios is! List) continue;
    for (final scenario in scenarios.cast<Map<String, Object?>>()) {
      scenarioCount++;
      final where = '$name/${scenario['name']}';
      missing(where, scenario, scenarioFields);
      final observed = scenario['observed'];
      final expected = scenario['expected'];
      if (observed == null || expected == null) continue;
      final status = scenarioStatus(observed, expected);
      if (scenario['status'] != status) {
        problems.add('$where: status ${scenario['status']} should be $status');
      }
      if (status != 'ok') {
        problems.add(
          '$where: $status (expected $expected, observed $observed)',
        );
      } else if (scenario['distinctStates'] == null) {
        problems.add('$where: no state counts');
      }
    }
  }
  if (scenarioCount == 0) problems.add('report: no scenario');
  if (report['status'] != 'passed') {
    problems.add('report: status ${report['status']}');
  }
  return problems;
}

bool _same(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((k) => b.containsKey(k) && _same(a[k], b[k]));
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_same(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// The requested scenario names that no manifest declares, in request
/// order. A run that misses one is incomplete, so a renamed or misspelled
/// scenario cannot pass by running the others.
List<String> missingScenarios(
  Iterable<String> requested,
  Iterable<String> run,
) {
  final ran = run.toSet();
  return [
    for (final name in requested)
      if (!ran.contains(name)) name,
  ];
}
