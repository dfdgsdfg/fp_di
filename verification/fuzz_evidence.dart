// Persistent evidence for seeded lifecycle fuzz runs.
//
// This module records the run inputs, source state, package:test JSON events,
// and a conservative completion status. It uses only Dart's standard library.
import 'dart:convert';
import 'dart:io';

import 'run_provenance.dart';

const _sourcePaths = [
  'agents/scripts/test_core.dart',
  'verification/fuzz_evidence.dart',
  'verification/test/fuzz_evidence_test.dart',
];

/// Captures durable evidence for one child test-runner invocation.
class FuzzEvidence {
  FuzzEvidence._({required this.directory, required this.workspaceRoot});

  /// The unique directory that contains this run's evidence.
  final Directory directory;

  /// The workspace root used to collect source provenance.
  final Directory workspaceRoot;

  /// The package:test JSON event log path passed to `--file-reporter`.
  String get eventsPath => '${directory.path}/events.jsonl';

  bool _finished = false;

  /// Creates a run directory and records its initial manifest and provenance.
  static Future<FuzzEvidence> start({
    required List<String> testArgs,
    required List<String> plannedSuites,
    Directory? workspaceRoot,
  }) async {
    final root = (workspaceRoot ?? Directory.current).absolute;
    final output = Directory('${root.path}/output/fuzz');
    await output.create(recursive: true);
    final utc = DateTime.now().toUtc().toIso8601String().replaceAll(
      RegExp(r'[^0-9TZ]'),
      '-',
    );
    final directory = await output.createTemp('$utc-');
    final evidence = FuzzEvidence._(directory: directory, workspaceRoot: root);
    final startedAt = DateTime.now().toUtc().toIso8601String();
    final manifest = <String, Object?>{
      'schemaVersion': 1,
      'status': 'running',
      'startedAt': startedAt,
      'testArgs': testArgs,
      'plannedSuites': plannedSuites,
      'events': 'events.jsonl',
    };
    await evidence._writeManifest(manifest);
    final provenance = await captureRunProvenance(
      workspaceRoot: root,
      evidenceDirectory: directory,
      arguments: testArgs,
      packageNames: _packageNames(plannedSuites),
      sourcePaths: _sourcePaths,
      environment: {
        for (final key in const [
          'FP_DI_FUZZ_SEED',
          'FP_DI_FUZZ_CYCLES',
          'FP_DI_FUZZ_GRAPHS',
          'FP_DI_FUZZ_STEPS',
        ])
          if (Platform.environment.containsKey(key))
            key: Platform.environment[key]!,
      },
    );
    await File(
      '${directory.path}/provenance.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(provenance));
    manifest['provenanceProblems'] = provenance['provenanceProblems'];
    await evidence._writeManifest(manifest);
    return evidence;
  }

  /// Parses the event log and records its outcome. Returns true only on a pass.
  Future<bool> finish(int exitCode) async {
    if (_finished) return false;
    _finished = true;
    final manifestFile = File('${directory.path}/manifest.json');
    final manifest = (jsonDecode(await manifestFile.readAsString()) as Map)
        .cast<String, Object?>();
    final provenance =
        (jsonDecode(
                  await File(
                    '${directory.path}/provenance.json',
                  ).readAsString(),
                )
                as Map)
            .cast<String, Object?>();
    final parsed = parseEvents(
      await File(eventsPath).exists()
          ? await File(eventsPath).readAsString()
          : null,
      (manifest['plannedSuites']! as List).cast<String>(),
    );
    await _writeJson('coverage.json', {
      'configuration': [
        for (final event in parsed.coverage)
          if (_isConfigurationMessage('${event['message']}'))
            {...event, 'values': _integerValues('${event['message']}')},
      ],
      'coverage': [
        for (final event in parsed.coverage)
          if (_isCoverageMessage('${event['message']}'))
            {...event, 'values': _integerValues('${event['message']}')},
      ],
    });
    await _writeJson('failures.json', parsed.failures);
    final problems = <String>[
      ...parsed.problems,
      ...await checkRunProvenance(
        workspaceRoot: workspaceRoot,
        provenance: provenance,
        packageNames: _packageNames(
          (manifest['plannedSuites']! as List).cast<String>(),
        ),
        sourcePaths: _sourcePaths,
      ),
    ];
    final childFailed = exitCode != 0 || parsed.hasFailure;
    final status = childFailed
        ? 'failed'
        : problems.isEmpty && parsed.complete
        ? 'passed'
        : 'incomplete';
    manifest
      ..['status'] = status
      ..['completedAt'] = DateTime.now().toUtc().toIso8601String()
      ..['childExitCode'] = exitCode
      ..['doneSuccess'] = parsed.doneSuccess
      ..['completedFuzzTests'] = parsed.completedFuzzTests
      ..['reporterVersions'] = parsed.reporterVersions
      ..['problems'] = problems;
    await _writeManifest(manifest);
    return status == 'passed';
  }

  Future<void> _writeManifest(Map<String, Object?> manifest) async {
    await _writeJson('manifest.json', manifest);
  }

  Future<void> _writeJson(String name, Object? value) async {
    await File(
      '${directory.path}/$name',
    ).writeAsString('${const JsonEncoder.withIndent('  ').convert(value)}\n');
  }
}

/// Parses package:test's JSON reporter protocol without filesystem access.
FuzzEventSummary parseEvents(String? log, List<String> plannedSuites) {
  final problems = <String>[];
  final coverage = <Map<String, Object?>>[];
  final failures = <Map<String, Object?>>[];
  if (log == null || log.trim().isEmpty) {
    return FuzzEventSummary.incomplete('missing or empty event log');
  }
  final suites = <Object?, String>{};
  final tests = <Object?, _TestRecord>{};
  var sawStart = false;
  var sawDone = false;
  bool? doneSuccess;
  final reporterVersions = <String, Object?>{};
  var malformed = false;
  final lines = log.split('\n');
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    if (line.isEmpty && index == lines.length - 1) continue;
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
    final type = event['type'];
    if (type == 'start') {
      if (sawStart) problems.add('duplicate start event');
      sawStart = true;
      reporterVersions.addAll({
        if (event['protocolVersion'] != null)
          'protocolVersion': event['protocolVersion'],
        if (event['runnerVersion'] != null)
          'runnerVersion': event['runnerVersion'],
      });
    } else if (type == 'suite') {
      final suite = event['suite'];
      if (suite is Map) {
        final mapped = suite.cast<String, Object?>();
        final id = mapped['id'];
        final path = mapped['path'];
        if (id != null && path is String) suites[id] = path;
      }
    } else if (type == 'testStart') {
      final test = event['test'];
      if (test is Map) {
        final mapped = test.cast<String, Object?>();
        final id = mapped['id'];
        final suiteId = mapped['suiteID'];
        if (id != null) {
          tests[id] = _TestRecord(
            id: id,
            name: '${mapped['name'] ?? ''}',
            suiteId: suiteId,
            suitePath: suites[suiteId] ?? '',
            hidden: false,
            skipped: false,
            result: null,
            messages: [],
          );
        }
      }
    } else if (type == 'print') {
      final test = tests[event['testID']];
      if (test != null) {
        final message = '${event['message'] ?? ''}';
        final record = <String, Object?>{
          'suite': test.suitePath,
          'test': test.name,
          'messageType': event['messageType'],
          'message': message,
        };
        test.messages.add(record);
        if (_isCoverageMessage(message) || _isConfigurationMessage(message)) {
          coverage.add(record);
        }
        if (_isFailureMessage(message)) failures.add(record);
      }
    } else if (type == 'error') {
      failures.add(event);
    } else if (type == 'testDone') {
      final test = tests[event['testID']];
      if (test == null) {
        problems.add('testDone without matching testStart');
      } else {
        test
          ..result = '${event['result'] ?? ''}'
          ..skipped = event['skipped'] == true
          ..hidden = event['hidden'] == true;
        if (test.result != 'success' && !test.skipped) {
          failures.add({
            'test': test.name,
            'suite': test.suitePath,
            'result': test.result,
          });
        }
      }
    } else if (type == 'done') {
      if (sawDone) problems.add('duplicate done event');
      sawDone = true;
      doneSuccess = event['success'] == true
          ? true
          : event['success'] == false
          ? false
          : null;
    } else if (type is! String || type.isEmpty) {
      malformed = true;
      problems.add('event without a valid type at line ${index + 1}');
    }
  }
  if (!sawStart) problems.add('missing start event');
  if (!sawDone) problems.add('missing done event');
  if (doneSuccess != true) problems.add('done.success is not true');
  final openTests = tests.values.where((test) => test.result == null).toList();
  if (openTests.isNotEmpty) problems.add('one or more tests did not complete');
  final completed = <Map<String, Object?>>[];
  for (final test in tests.values) {
    final suite = test.suitePath;
    if (test.result == null || test.hidden || test.skipped) continue;
    if (_isPlannedSuite(suite, plannedSuites)) {
      completed.add({
        'suite': suite,
        'name': test.name,
        'result': test.result,
        'messages': test.messages,
      });
    }
  }
  if (completed.isEmpty) {
    problems.add('no completed fuzz test in a planned suite');
  }
  final hasFailure =
      doneSuccess == false ||
      failures.isNotEmpty ||
      tests.values.any(
        (test) =>
            test.result != null && test.result != 'success' && !test.skipped,
      );
  if (malformed) problems.add('event log contains malformed data');
  return FuzzEventSummary(
    complete: problems.isEmpty && !malformed,
    hasFailure: hasFailure,
    doneSuccess: doneSuccess,
    completedFuzzTests: completed,
    coverage: coverage,
    failures: failures,
    problems: problems.toSet().toList(),
    reporterVersions: reporterVersions,
  );
}

/// The parsed status and useful messages from one JSON event log.
class FuzzEventSummary {
  /// Creates a parsed summary.
  FuzzEventSummary({
    required this.complete,
    required this.hasFailure,
    required this.doneSuccess,
    required this.completedFuzzTests,
    required this.coverage,
    required this.failures,
    required this.problems,
    this.reporterVersions = const {},
  });

  /// Creates an incomplete summary with one reason.
  factory FuzzEventSummary.incomplete(String problem) => FuzzEventSummary(
    complete: false,
    hasFailure: false,
    doneSuccess: null,
    completedFuzzTests: const [],
    coverage: const [],
    failures: const [],
    problems: [problem],
  );

  /// Whether the log has a complete successful run and a planned fuzz test.
  final bool complete;

  /// Whether the child reported a test failure or error event.
  final bool hasFailure;

  /// The value of the `done.success` field, if present.
  final bool? doneSuccess;

  /// Completed, non-hidden, non-skipped tests from planned fuzz suites.
  final List<Map<String, Object?>> completedFuzzTests;

  /// Captured fuzz coverage and configuration messages.
  final List<Map<String, Object?>> coverage;

  /// Captured failed-test prints and reporter error events.
  final List<Map<String, Object?>> failures;

  /// Reasons that the event log cannot count as complete evidence.
  final List<String> problems;

  /// The reporter protocol and package:test runner versions, when present.
  final Map<String, Object?> reporterVersions;
}

class _TestRecord {
  _TestRecord({
    required this.id,
    required this.name,
    required this.suiteId,
    required this.suitePath,
    required this.hidden,
    required this.skipped,
    required this.result,
    required this.messages,
  });

  final Object id;
  final String name;
  final Object? suiteId;
  final String suitePath;
  bool hidden;
  bool skipped;
  String? result;
  final List<Map<String, Object?>> messages;
}

bool _isPlannedSuite(String observed, List<String> planned) {
  final normalizedObserved = _normalizePath(observed);
  return planned.any((path) {
    final normalizedPlanned = _normalizePath(path);
    return normalizedObserved == normalizedPlanned ||
        normalizedObserved.endsWith('/$normalizedPlanned') ||
        normalizedPlanned.endsWith('/$normalizedObserved');
  });
}

String _normalizePath(String path) =>
    path.replaceAll('\\', '/').replaceFirst(RegExp(r'^\./'), '');

bool _isConfigurationMessage(String message) =>
    message.startsWith('lifecycle fuzz:') ||
    RegExp(
      r'\bseed\s*=|FP_DI_FUZZ_(?:SEED|CYCLES|GRAPHS|STEPS)',
    ).hasMatch(message);

bool _isCoverageMessage(String message) =>
    message.startsWith('lifecycle fuzz coverage:');

bool _isFailureMessage(String message) =>
    message.contains('reduced command') ||
    message.contains('reduced history') ||
    message.contains('=== lifecycle fuzz failure ===');

List<String> _packageNames(List<String> plannedSuites) =>
    plannedSuites
        .map((suite) => suite.replaceAll('\\', '/').split('/'))
        .where((parts) => parts.length > 2 && parts.first == 'packages')
        .map((parts) => parts[1])
        .toSet()
        .toList()
      ..sort();

Map<String, int> _integerValues(String message) => {
  for (final match in RegExp(
    r'([A-Za-z_][A-Za-z0-9_-]*)=(-?\d+)',
  ).allMatches(message))
    match.group(1)!: int.parse(match.group(2)!),
};
