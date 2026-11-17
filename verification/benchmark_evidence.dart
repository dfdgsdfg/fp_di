// Persistent evidence and strict parsing for lifecycle cost measurements.
import 'dart:convert';
import 'dart:io';

import 'run_provenance.dart';

/// Fixed suite arguments used by the reproducible performance runner.
const benchmarkSuiteArgs = [
  'packages/fp_di/test/module_test.dart',
  'packages/fp_di/test/runtime_state_test.dart',
  '--name',
  '^(initialize cost|cost) ',
  '--concurrency=1',
  '--reporter=expanded',
];

/// Stable metric identifiers expected from the cost fixtures.
const benchmarkMetricIds = [
  'module.random_2000.initialize',
  'module.random_2000.dispose',
  'module.chain_4000.initialize',
  'module.two_predecessors_4000.initialize',
  'module.star_4000.initialize',
  'module.chain_32000.initialize',
  'module.chain_32000.dispose',
  'runtime_state.transition_reads_4000.initialize',
  'runtime_state.set_contributors_1000.declaration.initialize',
  'runtime_state.set_contributors_1000.reverse.initialize',
];

/// Captures one sequential benchmark campaign and its sample artifacts.
class BenchmarkEvidence {
  BenchmarkEvidence._({required this.directory, required this.workspaceRoot});

  /// The unique directory that contains the campaign evidence.
  final Directory directory;

  /// The workspace root used to collect and recheck source provenance.
  final Directory workspaceRoot;

  Map<String, Object?>? _provenance;
  Map<String, Object?>? _manifest;

  /// Creates a run directory and writes the running manifest before capture.
  static Future<BenchmarkEvidence> start({
    required int samples,
    required List<String> arguments,
    Directory? workspaceRoot,
  }) async {
    if (samples < 1) throw ArgumentError.value(samples, 'samples');
    final root = (workspaceRoot ?? Directory.current).absolute;
    final output = Directory('${root.path}/output/benchmarks');
    await output.create(recursive: true);
    final prefix = DateTime.now().toUtc().toIso8601String().replaceAll(
      RegExp(r'[^0-9TZ]'),
      '-',
    );
    final directory = await output.createTemp('$prefix-');
    final evidence = BenchmarkEvidence._(
      directory: directory,
      workspaceRoot: root,
    );
    evidence._manifest = {
      'schemaVersion': 1,
      'status': 'running',
      'startedAt': DateTime.now().toUtc().toIso8601String(),
      'plannedSamples': samples,
      'completedSamples': <Map<String, Object?>>[],
      'arguments': arguments,
      'command': [
        Platform.resolvedExecutable,
        'run',
        'agents/scripts/benchmark.dart',
        ...arguments,
      ],
      'suiteArguments': benchmarkSuiteArgs,
      'metricIds': benchmarkMetricIds,
      'policy': {
        'sequential': true,
        'freshVmPerSample': true,
        'warmupSamples': 0,
        'stopOnFailure': true,
        'summaryRequiresAllSamples': true,
        'executionMode': 'Dart VM JIT',
        'assertions': true,
        'concurrency': 1,
        'unit': 'ms',
        'timingBoundary': 'fixture Stopwatch around awaited runtime operations',
      },
      'samples': <Map<String, Object?>>[],
    };
    await evidence._writeManifest();
    evidence._provenance = await captureRunProvenance(
      workspaceRoot: root,
      evidenceDirectory: directory,
      arguments: arguments,
      packageNames: const ['fp_di'],
      sourcePaths: const [
        'agents/scripts/benchmark.dart',
        'agents/scripts/test_core.dart',
        'verification/fuzz_evidence.dart',
        'verification/benchmark_evidence.dart',
        'verification/test/benchmark_evidence_test.dart',
        'packages/fp_di/test/module_test.dart',
        'packages/fp_di/test/runtime_state_test.dart',
      ],
    );
    await evidence._writeJson('provenance.json', evidence._provenance);
    evidence._manifest!['provenanceProblems'] =
        evidence._provenance!['provenanceProblems'];
    await evidence._writeManifest();
    return evidence;
  }

  /// Returns the event-log path for a one-based sample number.
  String eventsPath(int sampleNumber) =>
      '${_sampleDirectory(sampleNumber).path}/events.jsonl';

  /// Creates the sample directory before a child process writes its event log.
  Future<void> prepareSample(int sampleNumber) async {
    await _sampleDirectory(sampleNumber).create(recursive: true);
  }

  /// Returns the captured stdout path for a one-based sample number.
  String stdoutPath(int sampleNumber) =>
      '${_sampleDirectory(sampleNumber).path}/stdout.log';

  /// Returns the captured stderr path for a one-based sample number.
  String stderrPath(int sampleNumber) =>
      '${_sampleDirectory(sampleNumber).path}/stderr.log';

  /// Parses and persists one completed child process result.
  Future<BenchmarkSampleResult> recordSample({
    required int sampleNumber,
    required int exitCode,
    required String stdout,
    required String stderr,
  }) async {
    final planned = _manifest!['plannedSamples']! as int;
    if (sampleNumber < 1 || sampleNumber > planned) {
      throw ArgumentError.value(sampleNumber, 'sampleNumber');
    }
    final samples = (_manifest!['samples']! as List)
        .cast<Map<String, Object?>>();
    if (samples.any((sample) => sample['sampleNumber'] == sampleNumber)) {
      throw StateError('sample $sampleNumber was already recorded');
    }
    final sampleDirectory = _sampleDirectory(sampleNumber);
    await sampleDirectory.create(recursive: true);
    await File(stdoutPath(sampleNumber)).writeAsString(stdout);
    await File(stderrPath(sampleNumber)).writeAsString(stderr);
    final eventsFile = File(eventsPath(sampleNumber));
    final parsed = parseBenchmarkEvents(
      await eventsFile.exists() ? await eventsFile.readAsString() : null,
    );
    final childFailed = exitCode != 0 || parsed.hasFailure;
    final status = childFailed
        ? 'failed'
        : parsed.problems.isEmpty && parsed.complete
        ? 'passed'
        : 'incomplete';
    final result = BenchmarkSampleResult(
      sampleNumber: sampleNumber,
      exitCode: exitCode,
      status: status,
      metrics: parsed.metrics,
      problems: parsed.problems,
      suiteTests: parsed.suiteTests,
      reporterVersions: parsed.reporterVersions,
    );
    final manifest = _manifest!;
    samples.add(result.toJson());
    samples.sort(
      (a, b) =>
          (a['sampleNumber']! as int).compareTo(b['sampleNumber']! as int),
    );
    manifest['completedSamples'] = samples
        .map((sample) => sample['sampleNumber'])
        .toList();
    await _writeManifest();
    return result;
  }

  /// Rechecks source provenance and writes a summary when all samples qualify.
  Future<bool> finish() async {
    final manifest = _manifest!;
    final samples = (manifest['samples']! as List).cast<Map<String, Object?>>();
    final problems = <String>[];
    problems.addAll(
      await checkRunProvenance(
        workspaceRoot: workspaceRoot,
        provenance: _provenance!,
        packageNames: const ['fp_di'],
        sourcePaths: const [
          'agents/scripts/benchmark.dart',
          'agents/scripts/test_core.dart',
          'verification/fuzz_evidence.dart',
          'verification/benchmark_evidence.dart',
          'verification/test/benchmark_evidence_test.dart',
          'packages/fp_di/test/module_test.dart',
          'packages/fp_di/test/runtime_state_test.dart',
        ],
      ),
    );
    final expectedSamples = manifest['plannedSamples']! as int;
    final allSamples =
        samples.length == expectedSamples &&
        samples.every((sample) => sample['status'] == 'passed');
    final aggregates = aggregateBenchmarkSamples(samples);
    final complete =
        allSamples &&
        problems.isEmpty &&
        aggregates.length == benchmarkMetricIds.length;
    final anyFailed = samples.any((sample) => sample['status'] == 'failed');
    final status = anyFailed
        ? 'failed'
        : complete
        ? 'passed'
        : 'incomplete';
    if (samples.length != expectedSamples) {
      problems.add('completed ${samples.length} of $expectedSamples samples');
    }
    manifest
      ..['status'] = status
      ..['completedAt'] = DateTime.now().toUtc().toIso8601String()
      ..['problems'] = problems
      ..['summary'] = complete ? aggregates : null;
    await _writeManifest();
    if (complete) await _writeJson('summary.json', aggregates);
    return status == 'passed';
  }

  Directory _sampleDirectory(int sampleNumber) {
    if (sampleNumber < 1) {
      throw ArgumentError.value(sampleNumber, 'sampleNumber');
    }
    return Directory(
      '${directory.path}/sample-${sampleNumber.toString().padLeft(3, '0')}',
    );
  }

  Future<void> _writeManifest() => _writeJson('manifest.json', _manifest);

  Future<void> _writeJson(String name, Object? value) async {
    await File(
      '${directory.path}/$name',
    ).writeAsString('${const JsonEncoder.withIndent('  ').convert(value)}\n');
  }
}

/// One successfully parsed benchmark sample.
class BenchmarkSampleResult {
  /// Creates a benchmark sample result.
  BenchmarkSampleResult({
    required this.sampleNumber,
    required this.exitCode,
    required this.status,
    required this.metrics,
    required this.problems,
    required this.suiteTests,
    required this.reporterVersions,
  });

  /// The one-based sample number.
  final int sampleNumber;

  /// The child process exit code.
  final int exitCode;

  /// The evidence status: `passed`, `failed`, or `incomplete`.
  final String status;

  /// Metrics emitted by the cost fixtures.
  final List<Map<String, Object?>> metrics;

  /// Reasons that this sample is incomplete or failed.
  final List<String> problems;

  /// Per-suite observed test names and completion states.
  final List<Map<String, Object?>> suiteTests;

  /// Reporter protocol and runner versions.
  final Map<String, Object?> reporterVersions;

  /// Encodes the result for a manifest.
  Map<String, Object?> toJson() => {
    'sampleNumber': sampleNumber,
    'exitCode': exitCode,
    'status': status,
    'metrics': metrics,
    'problems': problems,
    'suiteTests': suiteTests,
    'reporterVersions': reporterVersions,
  };
}

/// Parses one package:test JSON log and validates the fixed cost fixtures.
BenchmarkEventSummary parseBenchmarkEvents(String? log) {
  final problems = <String>[];
  if (log == null || log.trim().isEmpty) {
    return BenchmarkEventSummary.incomplete('missing or empty event log');
  }
  final suites = <Object?, String>{};
  final tests = <Object?, _BenchmarkTest>{};
  var sawStart = false;
  var sawDone = false;
  bool? doneSuccess;
  var malformed = false;
  var reporterError = false;
  final reporter = <String, Object?>{};
  final lines = log.split('\n');
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    if (line.trim().isEmpty) continue;
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      malformed = true;
      problems.add('invalid JSON event at line ${index + 1}');
      continue;
    }
    if (decoded is! Map) {
      malformed = true;
      problems.add('non-object event at line ${index + 1}');
      continue;
    }
    final event = decoded.cast<String, Object?>();
    switch (event['type']) {
      case 'start':
        if (sawStart) problems.add('duplicate start event');
        sawStart = true;
        reporter.addAll({
          if (event['protocolVersion'] != null)
            'protocolVersion': event['protocolVersion'],
          if (event['runnerVersion'] != null)
            'runnerVersion': event['runnerVersion'],
        });
      case 'suite':
        final suite = event['suite'];
        if (suite is Map) {
          final value = suite.cast<String, Object?>();
          if (value['id'] != null && value['path'] is String) {
            suites[value['id']] = value['path']! as String;
          }
        }
      case 'testStart':
        final test = event['test'];
        if (test is Map) {
          final value = test.cast<String, Object?>();
          final id = value['id'];
          if (id != null) {
            tests[id] = _BenchmarkTest(
              id: id,
              suiteId: value['suiteID'],
              suitePath: suites[value['suiteID']] ?? '',
              name: '${value['name'] ?? ''}',
              prints: [],
            );
          }
        }
      case 'print':
        final test = tests[event['testID']];
        if (test != null) test.prints.add('${event['message'] ?? ''}');
      case 'testDone':
        final test = tests[event['testID']];
        if (test == null) {
          problems.add('testDone without matching testStart');
        } else {
          test
            ..result = '${event['result'] ?? ''}'
            ..hidden = event['hidden'] == true
            ..skipped = event['skipped'] == true;
        }
      case 'error':
        reporterError = true;
        problems.add('reporter error event: ${event['error']}');
      case 'done':
        if (sawDone) problems.add('duplicate done event');
        sawDone = true;
        doneSuccess = event['success'] == true
            ? true
            : event['success'] == false
            ? false
            : null;
      case 'group' || 'allSuites' || 'debug':
        break;
      case _:
        malformed = true;
        problems.add('unsupported or missing event type at line ${index + 1}');
    }
  }
  if (!sawStart) problems.add('missing start event');
  if (!sawDone) problems.add('missing done event');
  if (doneSuccess != true) problems.add('done.success is not true');
  if (tests.values.any((test) => test.result == null)) {
    problems.add('one or more tests did not complete');
  }
  if (tests.values.any(
    (test) => test.result != null && test.result != 'success' && !test.skipped,
  )) {
    problems.add('one or more tests failed');
  }
  final fixtureTests = <String, List<_BenchmarkTest>>{
    for (final fixture in _fixtures) fixture.id: <_BenchmarkTest>[],
  };
  for (final test in tests.values) {
    final fixture = _fixtureFor(test);
    if (fixture != null && _isBenchmarkSuite(test.suitePath)) {
      fixtureTests[fixture.id]!.add(test);
    }
  }
  final metrics = <Map<String, Object?>>[];
  final metricCounts = <String, int>{};
  final suiteTests = <Map<String, Object?>>[];
  for (final fixture in _fixtures) {
    final matching = fixtureTests[fixture.id]!;
    final valid = matching
        .where(
          (test) => test.result == 'success' && !test.hidden && !test.skipped,
        )
        .toList();
    if (valid.length != 1 || matching.length != 1) {
      problems.add(
        '${fixture.id}: expected one completed test, found ${valid.length}',
      );
    }
    for (final test in matching) {
      suiteTests.add({
        'suite': test.suitePath,
        'test': test.name,
        'fixture': fixture.id,
        'result': test.result,
        'skipped': test.skipped,
        'hidden': test.hidden,
      });
      for (final message in test.prints) {
        for (final metric in fixture.parse(message)) {
          final id = metric['id']! as String;
          metricCounts.update(id, (count) => count + 1, ifAbsent: () => 1);
          metrics.add({
            ...metric,
            'fixture': fixture.id,
            'suite': test.suitePath,
            'test': test.name,
            'operation': id.split('.').last,
          });
        }
      }
    }
  }
  for (final id in benchmarkMetricIds) {
    final count = metricCounts[id] ?? 0;
    if (count == 0) problems.add('missing metric: $id');
    if (count > 1) problems.add('duplicate metric: $id');
  }
  if (metricCounts.keys.any((id) => !benchmarkMetricIds.contains(id))) {
    problems.add('unexpected metric id');
  }
  metrics.sort(
    (a, b) => benchmarkMetricIds
        .indexOf(a['id']! as String)
        .compareTo(benchmarkMetricIds.indexOf(b['id']! as String)),
  );
  return BenchmarkEventSummary(
    complete: !malformed && problems.isEmpty,
    hasFailure:
        reporterError ||
        doneSuccess == false ||
        tests.values.any(
          (test) =>
              test.result != null && test.result != 'success' && !test.skipped,
        ),
    doneSuccess: doneSuccess,
    metrics: metrics,
    suiteTests: suiteTests,
    problems: problems.toSet().toList(),
    reporterVersions: reporter,
  );
}

/// Aggregates raw sample values only when every expected metric is present.
List<Map<String, Object?>> aggregateBenchmarkSamples(
  List<Map<String, Object?>> samples,
) {
  if (samples.isEmpty ||
      samples.any((sample) => sample['status'] != 'passed')) {
    return const [];
  }
  final byMetric = <String, List<int>>{
    for (final id in benchmarkMetricIds) id: <int>[],
  };
  final metadataByMetric = <String, List<Object?>>{
    for (final id in benchmarkMetricIds) id: <Object?>[],
  };
  for (final sample in samples) {
    final rawMetrics = sample['metrics'];
    if (rawMetrics is! List) return const [];
    final seen = <String>{};
    for (final raw in rawMetrics) {
      if (raw is! Map) return const [];
      final metric = raw.cast<String, Object?>();
      final id = metric['id'];
      final value = metric['valueMs'];
      if (id is! String ||
          value is! int ||
          metric['unit'] != 'ms' ||
          !byMetric.containsKey(id)) {
        return const [];
      }
      if (!seen.add(id)) return const [];
      byMetric[id]!.add(value);
      metadataByMetric[id]!.add(metric['metadata'] ?? const {});
    }
    if (seen.length != benchmarkMetricIds.length) return const [];
  }
  return [
    for (final id in benchmarkMetricIds)
      if (byMetric[id]!.length == samples.length)
        _aggregate(id, byMetric[id]!, metadataByMetric[id]!),
  ];
}

/// The result of parsing one benchmark reporter log.
class BenchmarkEventSummary {
  /// Creates a benchmark event summary.
  BenchmarkEventSummary({
    required this.complete,
    required this.hasFailure,
    required this.doneSuccess,
    required this.metrics,
    required this.suiteTests,
    required this.problems,
    required this.reporterVersions,
  });

  /// Creates an incomplete result with one parsing problem.
  factory BenchmarkEventSummary.incomplete(String problem) =>
      BenchmarkEventSummary(
        complete: false,
        hasFailure: false,
        doneSuccess: null,
        metrics: const [],
        suiteTests: const [],
        problems: [problem],
        reporterVersions: const {},
      );

  /// Whether the log completed and contains every fixture and metric.
  final bool complete;

  /// Whether a test reporter failure occurred.
  final bool hasFailure;

  /// The `done.success` value when present.
  final bool? doneSuccess;

  /// Parsed metric values and per-metric metadata.
  final List<Map<String, Object?>> metrics;

  /// Observed suite and fixture test names.
  final List<Map<String, Object?>> suiteTests;

  /// Reasons that the log is failed or incomplete.
  final List<String> problems;

  /// Reporter protocol and runner versions.
  final Map<String, Object?> reporterVersions;
}

class _BenchmarkTest {
  _BenchmarkTest({
    required this.id,
    required this.suiteId,
    required this.suitePath,
    required this.name,
    required this.prints,
  });

  final Object id;
  final Object? suiteId;
  final String suitePath;
  final String name;
  final List<String> prints;
  String? result;
  bool hidden = false;
  bool skipped = false;
}

typedef _MetricParser = List<Map<String, Object?>> Function(String message);

class _Fixture {
  const _Fixture(this.id, this.testName, this.parse);
  final String id;
  final String testName;
  final _MetricParser parse;
}

final _fixtures = <_Fixture>[
  _Fixture('module.random_2000', 'creates 2000 components with random-order', (
    message,
  ) {
    final init = RegExp(
      r'initialize\(2000, random order\): (\d+) ms',
    ).firstMatch(message);
    final dispose = RegExp(r'dispose\(2000\): (\d+) ms').firstMatch(message);
    return [
      if (init != null)
        _metric('module.random_2000.initialize', init.group(1)!),
      if (dispose != null)
        _metric('module.random_2000.dispose', dispose.group(1)!),
    ];
  }),
  for (final graph in const ['chain', 'two predecessors', 'star'])
    _Fixture(
      'module.${graph.replaceAll(' ', '_')}_4000',
      'initializes 4000 members, $graph',
      (message) {
        final match = RegExp(
          'initialize\\(4000, ${RegExp.escape(graph)}\\): (\\d+) ms',
        ).firstMatch(message);
        return match == null
            ? const []
            : [
                _metric(
                  'module.${graph.replaceAll(' ', '_')}_4000.initialize',
                  match.group(1)!,
                ),
              ];
      },
    ),
  _Fixture('module.chain_32000', 'initializes and disposes a chain of 32000', (
    message,
  ) {
    final init = RegExp(
      r'initialize\(32000, chain\): (\d+) ms',
    ).firstMatch(message);
    final dispose = RegExp(r'dispose: (\d+) ms').firstMatch(message);
    return [
      if (init != null)
        _metric('module.chain_32000.initialize', init.group(1)!),
      if (dispose != null)
        _metric('module.chain_32000.dispose', dispose.group(1)!),
    ];
  }),
  _Fixture(
    'runtime_state.transition_reads_4000',
    'initializes a chain of 4000 members with a read at each transition',
    (message) {
      final match = RegExp(
        r'initialize\(4000\) with (\d+) reads of the state: (\d+) ms',
      ).firstMatch(message);
      return match == null
          ? const []
          : [
              _metric(
                'runtime_state.transition_reads_4000.initialize',
                match.group(2)!,
                metadata: {'stateReads': int.parse(match.group(1)!)},
              ),
            ];
    },
  ),
  for (final order in const ['declaration order', 'reverse order'])
    _Fixture(
      'runtime_state.set_contributors_1000.$order',
      'initializes 1000 set contributors and 20 strict readers, $order',
      (message) {
        final match = RegExp(
          'initialize\\(1000 contributors, 20 readers, ${RegExp.escape(order)}\\): (\\d+) ms',
        ).firstMatch(message);
        return match == null
            ? const []
            : [
                _metric(
                  'runtime_state.set_contributors_1000.'
                  '${order == 'declaration order' ? 'declaration' : 'reverse'}'
                  '.initialize',
                  match.group(1)!,
                ),
              ];
      },
    ),
];

_Fixture? _fixtureFor(_BenchmarkTest test) {
  for (final fixture in _fixtures) {
    if (test.name.contains(fixture.testName)) return fixture;
  }
  return null;
}

bool _isBenchmarkSuite(String path) =>
    path
        .replaceAll('\\', '/')
        .endsWith('/packages/fp_di/test/module_test.dart') ||
    path
        .replaceAll('\\', '/')
        .endsWith('/packages/fp_di/test/runtime_state_test.dart') ||
    path == 'packages/fp_di/test/module_test.dart' ||
    path == 'packages/fp_di/test/runtime_state_test.dart';

Map<String, Object?> _metric(
  String id,
  String value, {
  Map<String, Object?> metadata = const {},
}) => {
  'id': id,
  'unit': 'ms',
  'valueMs': int.parse(value),
  'metadata': metadata,
};

Map<String, Object?> _aggregate(
  String id,
  List<int> values,
  List<Object?> sampleMetadata,
) {
  final ordered = [...values]..sort();
  final middle = ordered.length ~/ 2;
  final median = ordered.length.isOdd
      ? ordered[middle].toDouble()
      : (ordered[middle - 1] + ordered[middle]) / 2;
  return {
    'id': id,
    'unit': 'ms',
    'samples': values,
    'sampleMetadata': sampleMetadata,
    'median': median,
    'min': ordered.first,
    'max': ordered.last,
  };
}
