import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../benchmark_evidence.dart';

void main() {
  group('benchmark event evidence', () {
    test('parses all eight fixtures and ten measured metrics', () {
      final summary = parseBenchmarkEvents(_events());

      expect(summary.complete, isTrue, reason: summary.problems.join('\n'));
      expect(summary.metrics, hasLength(10));
      expect(summary.metrics.map((metric) => metric['id']), benchmarkMetricIds);
      expect(summary.suiteTests, hasLength(8));
      final state = summary.metrics.singleWhere(
        (metric) =>
            metric['id'] == 'runtime_state.transition_reads_4000.initialize',
      );
      expect((state['metadata'] as Map)['stateReads'], 8002);
      expect(summary.reporterVersions['runnerVersion'], '1.31.1');
      expect(
        summary.metrics.first['suite'],
        'packages/fp_di/test/module_test.dart',
      );
      expect(summary.metrics.first['fixture'], 'module.random_2000');
      expect(summary.metrics.first['test'], contains('random-order'));
    });

    test(
      'records an explicitly emitted zero without inventing missing values',
      () {
        final summary = parseBenchmarkEvents(_events(zeroFirstMetric: true));

        expect(summary.complete, isTrue);
        expect(summary.metrics.first['valueMs'], 0);
        final incomplete = summary.metrics.take(9).toList();
        expect(
          aggregateBenchmarkSamples([
            {'status': 'passed', 'metrics': incomplete},
          ]),
          isEmpty,
        );
      },
    );

    test('rejects truncated logs, skipped fixtures, and duplicate metrics', () {
      expect(
        parseBenchmarkEvents(_events().split('\n').take(3).join('\n')).complete,
        isFalse,
      );
      expect(parseBenchmarkEvents(_events(skipFirst: true)).complete, isFalse);
      expect(parseBenchmarkEvents(_events(failFirst: true)).hasFailure, isTrue);
      expect(parseBenchmarkEvents(_events(malformed: true)).complete, isFalse);
      expect(
        parseBenchmarkEvents(_events(duplicateFirstMetric: true)).problems,
        contains('duplicate metric: module.random_2000.initialize'),
      );
      expect(
        parseBenchmarkEvents(_events(missingFirstMetric: true)).problems,
        contains('missing metric: module.random_2000.initialize'),
      );
    });

    test('computes statistics while preserving the original sample order', () {
      List<Map<String, Object?>> samples(List<int> values) => [
        for (final value in values)
          {
            'status': 'passed',
            'metrics': [
              for (final id in benchmarkMetricIds)
                {'id': id, 'valueMs': value, 'unit': 'ms'},
            ],
          },
      ];
      final odd = aggregateBenchmarkSamples(samples([90, 10, 30]));
      expect(odd, hasLength(10));
      expect(odd.first['samples'], [90, 10, 30]);
      expect(odd.first['median'], 30);
      expect(odd.first['min'], 10);
      expect(odd.first['max'], 90);
      final even = aggregateBenchmarkSamples(samples([90, 10, 31, 20]));
      expect(even.first['samples'], [90, 10, 31, 20]);
      expect(even.first['median'], 25.5);
      expect(even.first['min'], 10);
      expect(even.first['max'], 90);
    });

    test('retains timings from a failing fixture without passing evidence', () {
      final failed = parseBenchmarkEvents(_events(failFirst: true));
      expect(failed.hasFailure, isTrue);
      expect(failed.complete, isFalse);
      expect(failed.metrics.first['valueMs'], 87);
      final malformed = parseBenchmarkEvents('${_events()}not-json\n');
      expect(malformed.complete, isFalse);
      expect(
        malformed.problems,
        contains(startsWith('invalid JSON event at line ')),
      );
    });
  });

  group('benchmark evidence storage', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('benchmark-evidence-test-');
      await _initializeGitWorkspace(root);
    });

    tearDown(() async {
      await root.delete(recursive: true);
    });

    test(
      'retains each sample and aggregates complete consistent samples',
      () async {
        final evidence = await BenchmarkEvidence.start(
          samples: 2,
          arguments: const ['--samples', '2'],
          workspaceRoot: root,
        );
        expect(_readManifest(evidence)['status'], 'running');
        for (var sample = 1; sample <= 2; sample++) {
          await evidence.prepareSample(sample);
          await File(evidence.eventsPath(sample)).writeAsString(_events());
          final result = await evidence.recordSample(
            sampleNumber: sample,
            exitCode: 0,
            stdout: 'stdout $sample',
            stderr: 'stderr $sample',
          );
          expect(result.status, 'passed');
          expect(File(evidence.stdoutPath(sample)).existsSync(), isTrue);
          expect(File(evidence.stderrPath(sample)).existsSync(), isTrue);
        }

        expect(await evidence.finish(), isTrue);
        final manifest = _readManifest(evidence);
        expect(manifest['status'], 'passed');
        expect(manifest['completedSamples'], [1, 2]);
        expect(manifest['summary'], hasLength(10));
        expect(
          File('${evidence.directory.path}/summary.json').existsSync(),
          isTrue,
        );
      },
    );

    test('does not aggregate an incomplete campaign', () async {
      final evidence = await BenchmarkEvidence.start(
        samples: 2,
        arguments: const ['--samples', '2'],
        workspaceRoot: root,
      );
      await evidence.prepareSample(1);
      await File(evidence.eventsPath(1)).writeAsString(_events());
      await evidence.recordSample(
        sampleNumber: 1,
        exitCode: 0,
        stdout: '',
        stderr: '',
      );

      expect(await evidence.finish(), isFalse);
      final manifest = _readManifest(evidence);
      expect(manifest['status'], 'incomplete');
      expect(manifest['summary'], isNull);
      expect(
        File('${evidence.directory.path}/summary.json').existsSync(),
        isFalse,
      );
    });

    test('retains failed sample logs and excludes aggregate results', () async {
      final evidence = await BenchmarkEvidence.start(
        samples: 1,
        arguments: const ['--samples', '1'],
        workspaceRoot: root,
      );
      await evidence.prepareSample(1);
      await File(
        evidence.eventsPath(1),
      ).writeAsString(_events(failFirst: true));
      final result = await evidence.recordSample(
        sampleNumber: 1,
        exitCode: 1,
        stdout: 'partial timing output',
        stderr: 'fixture failed',
      );
      expect(result.status, 'failed');
      expect(result.metrics.first['valueMs'], 87);
      expect(await evidence.finish(), isFalse);
      expect(_readManifest(evidence)['status'], 'failed');
      expect(_readManifest(evidence)['summary'], isNull);
      expect(
        File(evidence.stdoutPath(1)).readAsStringSync(),
        'partial timing output',
      );
      expect(
        File('${evidence.directory.path}/summary.json').existsSync(),
        false,
      );
    });

    test('marks changed fixture source as incomplete', () async {
      final evidence = await BenchmarkEvidence.start(
        samples: 1,
        arguments: const [],
        workspaceRoot: root,
      );
      await evidence.prepareSample(1);
      await File(
        '${root.path}/packages/fp_di/test/module_test.dart',
      ).writeAsString('changed during run\n');
      await File(evidence.eventsPath(1)).writeAsString(_events());
      await evidence.recordSample(
        sampleNumber: 1,
        exitCode: 0,
        stdout: '',
        stderr: '',
      );

      expect(await evidence.finish(), isFalse);
      expect(_readManifest(evidence)['status'], 'incomplete');
    });
  });
}

Map<String, Object?> _readManifest(BenchmarkEvidence evidence) =>
    (jsonDecode(
              File(
                '${evidence.directory.path}/manifest.json',
              ).readAsStringSync(),
            )
            as Map)
        .cast<String, Object?>();

String _events({
  bool zeroFirstMetric = false,
  bool skipFirst = false,
  bool duplicateFirstMetric = false,
  bool missingFirstMetric = false,
  bool failFirst = false,
  bool malformed = false,
}) {
  final events = <Map<String, Object?>>[
    {'type': 'start', 'protocolVersion': '0.1.1', 'runnerVersion': '1.31.1'},
    {
      'type': 'suite',
      'suite': {'id': 1, 'path': 'packages/fp_di/test/module_test.dart'},
    },
    {
      'type': 'suite',
      'suite': {'id': 2, 'path': 'packages/fp_di/test/runtime_state_test.dart'},
    },
  ];
  final fixtures = <({String suite, String name, List<String> prints})>[
    (
      suite: 'module_test.dart',
      name:
          'initialize cost creates 2000 components with random-order '
          'dependencies',
      prints: [
        'initialize(2000, random order): ${zeroFirstMetric ? 0 : 87} ms',
        'dispose(2000): 53 ms',
      ],
    ),
    (
      suite: 'module_test.dart',
      name: 'initialize cost initializes 4000 members, chain, within 1 s',
      prints: ['initialize(4000, chain): 47 ms'],
    ),
    (
      suite: 'module_test.dart',
      name:
          'initialize cost initializes 4000 members, two predecessors, '
          'within 1 s',
      prints: ['initialize(4000, two predecessors): 39 ms'],
    ),
    (
      suite: 'module_test.dart',
      name: 'initialize cost initializes 4000 members, star, within 1 s',
      prints: ['initialize(4000, star): 26 ms'],
    ),
    (
      suite: 'module_test.dart',
      name:
          'initialize cost initializes and disposes a chain of 32000 '
          'members within 1 s each',
      prints: ['initialize(32000, chain): 201 ms, dispose: 140 ms'],
    ),
    (
      suite: 'runtime_state_test.dart',
      name:
          'cost initializes a chain of 4000 members with a read at each '
          'transition',
      prints: ['initialize(4000) with 8002 reads of the state: 334 ms'],
    ),
    (
      suite: 'runtime_state_test.dart',
      name:
          'cost initializes 1000 set contributors and 20 strict readers, '
          'declaration order',
      prints: [
        'initialize(1000 contributors, 20 readers, declaration order): 61 ms',
      ],
    ),
    (
      suite: 'runtime_state_test.dart',
      name:
          'cost initializes 1000 set contributors and 20 strict readers, '
          'reverse order',
      prints: [
        'initialize(1000 contributors, 20 readers, reverse order): 50 ms',
      ],
    ),
  ];
  var nextId = 10;
  var firstMetricPrint = true;
  for (final fixture in fixtures) {
    final suiteId = fixture.suite == 'module_test.dart' ? 1 : 2;
    final id = nextId++;
    events.add({
      'type': 'testStart',
      'test': {'id': id, 'name': fixture.name, 'suiteID': suiteId},
    });
    for (final print in fixture.prints) {
      if (firstMetricPrint && missingFirstMetric) {
        firstMetricPrint = false;
        continue;
      }
      if (firstMetricPrint && malformed) {
        events.add({'invalid': 'event'});
      }
      events.add({'type': 'print', 'testID': id, 'message': print});
      if (firstMetricPrint && duplicateFirstMetric) {
        events.add({'type': 'print', 'testID': id, 'message': print});
      }
      firstMetricPrint = false;
    }
    events.add({
      'type': 'testDone',
      'testID': id,
      'result': failFirst && id == 10 ? 'failure' : 'success',
      'hidden': false,
      'skipped': skipFirst && id == 10,
    });
  }
  events.add({'type': 'done', 'success': true});
  return '${events.map(jsonEncode).join('\n')}\n';
}

Future<void> _initializeGitWorkspace(Directory root) async {
  await Directory('${root.path}/packages/fp_di/lib').create(recursive: true);
  await Directory('${root.path}/packages/fp_di/test').create(recursive: true);
  await File('${root.path}/pubspec.yaml').writeAsString('name: fixture\n');
  await File('${root.path}/pubspec.lock').writeAsString('# fixture lock\n');
  await File(
    '${root.path}/packages/fp_di/pubspec.yaml',
  ).writeAsString('name: fp_di\n');
  await File(
    '${root.path}/packages/fp_di/lib/runtime.dart',
  ).writeAsString('library runtime;\n');
  for (final name in ['module_test.dart', 'runtime_state_test.dart']) {
    await File(
      '${root.path}/packages/fp_di/test/$name',
    ).writeAsString('void main() {}\n');
  }
  await _git(root, ['init', '-q']);
  await _git(root, ['config', 'user.email', 'benchmark@example.invalid']);
  await _git(root, ['config', 'user.name', 'Benchmark Evidence Test']);
  await _git(root, ['add', '.']);
  await _git(root, ['commit', '-qm', 'fixture']);
}

Future<ProcessResult> _git(Directory root, List<String> args) =>
    Process.run('git', args, workingDirectory: root.path);
