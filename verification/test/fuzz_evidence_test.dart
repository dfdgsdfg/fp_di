import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../fuzz_evidence.dart';

void main() {
  group('FuzzEvidence', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('fuzz-evidence-test-');
      await _initializeGitWorkspace(root);
    });

    tearDown(() async {
      await root.delete(recursive: true);
    });

    test('records complete passing fuzz evidence', () async {
      final evidence = await _start(root);
      await File(
        evidence.eventsPath,
      ).writeAsString(_events(loadingPrint: true));

      expect(await evidence.finish(0), isTrue);
      final manifest = _readJson('${evidence.directory.path}/manifest.json');
      expect(manifest['status'], 'passed');
      expect(manifest['completedFuzzTests'], hasLength(1));
      expect(manifest['reporterVersions'], {
        'protocolVersion': '0.1.1',
        'runnerVersion': 'test-runner',
      });
      expect(
        File('${evidence.directory.path}/source.patch').existsSync(),
        isTrue,
      );
      expect(
        File(
          '${evidence.directory.path}/sources/packages/fp_di/test/fuzz_test.dart.source',
        ).existsSync(),
        isTrue,
      );
      final provenance = _readJson(
        '${evidence.directory.path}/provenance.json',
      );
      expect(provenance['hashAlgorithm'], 'git sha1 object hash');
      expect(provenance['osVersion'], isA<String>());
      expect(provenance['executableArguments'], isA<List<Object?>>());
      expect(
        await File('${evidence.directory.path}/pubspec.lock').exists(),
        isTrue,
      );
      final coverage = _readJson('${evidence.directory.path}/coverage.json');
      expect(coverage['coverage'], hasLength(1));
      expect(coverage['configuration'], hasLength(1));
      final configuration =
          (coverage['configuration'] as List<Object?>).single as Map;
      final values = (configuration['values'] as Map).cast<String, Object?>();
      expect(values['seed'], 20260601);
    });

    test('marks failed child exit as failed', () async {
      final evidence = await _start(root);
      await File(evidence.eventsPath).writeAsString(_events());

      expect(await evidence.finish(1), isFalse);
      expect(
        _readJson('${evidence.directory.path}/manifest.json')['status'],
        'failed',
      );
    });

    test('marks test errors as failed', () async {
      final evidence = await _start(root);
      await File(
        evidence.eventsPath,
      ).writeAsString(_events(result: 'failure', doneSuccess: false));

      expect(await evidence.finish(1), isFalse);
      expect(
        _readJson('${evidence.directory.path}/manifest.json')['status'],
        'failed',
      );
      expect(_readList('${evidence.directory.path}/failures.json'), isNotEmpty);
    });

    test('marks truncated and malformed logs incomplete', () async {
      final evidence = await _start(root);
      await File(evidence.eventsPath).writeAsString(
        '${_events().split('\n').take(3).join('\n')}\n{"type":"done"',
      );

      expect(await evidence.finish(0), isFalse);
      final manifest = _readJson('${evidence.directory.path}/manifest.json');
      expect(manifest['status'], 'incomplete');
      expect(manifest['problems'], contains('missing done event'));
    });

    test('marks successful logs with no planned tests incomplete', () async {
      final evidence = await _start(root);
      await File(
        evidence.eventsPath,
      ).writeAsString(_events(testPath: 'other_test.dart'));

      expect(await evidence.finish(0), isFalse);
      expect(
        _readJson('${evidence.directory.path}/manifest.json')['status'],
        'incomplete',
      );
    });

    test('does not count skipped fuzz tests', () async {
      final evidence = await _start(root);
      await File(
        evidence.eventsPath,
      ).writeAsString(_events(skipped: true, result: 'success'));

      expect(await evidence.finish(0), isFalse);
      expect(
        _readJson('${evidence.directory.path}/manifest.json')['status'],
        'incomplete',
      );
    });

    test('creates unique directories for repeated runs', () async {
      final first = await _start(root);
      final second = await _start(root);

      expect(first.directory.path, isNot(second.directory.path));
      expect(
        _readJson('${first.directory.path}/manifest.json')['status'],
        'running',
      );
      expect(
        _readJson('${second.directory.path}/manifest.json')['status'],
        'running',
      );
    });

    test('detects source content changes during the run', () async {
      final evidence = await _start(root);
      await File(
        '${root.path}/packages/fp_di/test/fuzz_test.dart',
      ).writeAsString('changed after start\n');
      await File(evidence.eventsPath).writeAsString(_events());

      expect(await evidence.finish(0), isFalse);
      final manifest = _readJson('${evidence.directory.path}/manifest.json');
      expect(manifest['status'], 'incomplete');
      expect(
        (manifest['problems'] as List).join('\n'),
        contains(
          'source changed during run: packages/fp_di/test/fuzz_test.dart',
        ),
      );
    });

    test('captures and rechecks fpdart provenance', () async {
      const suite = 'packages/fp_di_fpdart/test/lifecycle_fuzz_test.dart';
      final evidence = await _start(root, suite: suite);
      final provenance = _readJson(
        '${evidence.directory.path}/provenance.json',
      );
      final hashes = (provenance['sourceHashes'] as Map)
          .cast<String, Object?>();
      expect(
        hashes.containsKey('packages/fp_di_fpdart/lib/fpdart.dart'),
        isTrue,
      );
      expect(
        File(
          '${evidence.directory.path}/sources/packages/fp_di_fpdart/lib/fpdart.dart.source',
        ).existsSync(),
        isTrue,
      );
      await File(
        '${root.path}/packages/fp_di_fpdart/lib/fpdart.dart',
      ).writeAsString('changed fpdart source\n');
      await File(evidence.eventsPath).writeAsString(_events(testPath: suite));

      expect(await evidence.finish(0), isFalse);
      final manifest = _readJson('${evidence.directory.path}/manifest.json');
      expect(
        (manifest['problems'] as List).join('\n'),
        contains(
          'source changed during run: packages/fp_di_fpdart/lib/fpdart.dart',
        ),
      );
    });
  });

  test('captures fuzz configuration prints emitted by hidden loader tests', () {
    final summary = parseEvents(_events(loadingPrint: true), [
      'packages/fp_di/test/lifecycle_fuzz_test.dart',
    ]);

    expect(summary.complete, isTrue);
    expect(summary.coverage, hasLength(2));
    expect(summary.completedFuzzTests, hasLength(1));
  });
}

Future<FuzzEvidence> _start(
  Directory root, {
  String suite = 'packages/fp_di/test/lifecycle_fuzz_test.dart',
}) => FuzzEvidence.start(
  testArgs: [suite],
  plannedSuites: [suite],
  workspaceRoot: root,
);

String _events({
  String testPath = 'packages/fp_di/test/lifecycle_fuzz_test.dart',
  String result = 'success',
  bool doneSuccess = true,
  bool skipped = false,
  bool loadingPrint = false,
}) {
  final events = <Map<String, Object?>>[
    {
      'type': 'start',
      'protocolVersion': '0.1.1',
      'runnerVersion': 'test-runner',
    },
    {
      'type': 'suite',
      'suite': {'id': 1, 'path': testPath},
    },
  ];
  if (loadingPrint) {
    events
      ..add({
        'type': 'testStart',
        'test': {'id': 2, 'name': 'loading fuzz suite', 'suiteID': 1},
      })
      ..add({
        'type': 'print',
        'testID': 2,
        'message': 'lifecycle fuzz: seed=20260601 cycles=40 graphs=8',
      })
      ..add({
        'type': 'print',
        'testID': 2,
        'message': 'lifecycle fuzz coverage: activate=1 release=1',
      })
      ..add({
        'type': 'testDone',
        'testID': 2,
        'result': 'success',
        'hidden': true,
        'skipped': false,
      });
  }
  events
    ..add({
      'type': 'testStart',
      'test': {'id': 3, 'name': 'seed=20260601 graph=0', 'suiteID': 1},
    })
    ..add({
      'type': 'testDone',
      'testID': 3,
      'result': result,
      'hidden': false,
      'skipped': skipped,
    })
    ..add({'type': 'done', 'success': doneSuccess});
  return '${events.map(jsonEncode).join('\n')}\n';
}

Map<String, Object?> _readJson(String path) =>
    (jsonDecode(File(path).readAsStringSync()) as Map).cast<String, Object?>();

List<Object?> _readList(String path) =>
    (jsonDecode(File(path).readAsStringSync()) as List).cast<Object?>();

Future<void> _initializeGitWorkspace(Directory root) async {
  await Directory('${root.path}/packages/fp_di/lib').create(recursive: true);
  await Directory('${root.path}/packages/fp_di/test').create(recursive: true);
  await Directory(
    '${root.path}/packages/fp_di_fpdart/lib',
  ).create(recursive: true);
  await Directory(
    '${root.path}/packages/fp_di_fpdart/test',
  ).create(recursive: true);
  await File('${root.path}/pubspec.yaml').writeAsString('name: fixture\n');
  await File('${root.path}/pubspec.lock').writeAsString('# fixture lock\n');
  await File(
    '${root.path}/packages/fp_di/pubspec.yaml',
  ).writeAsString('name: fp_di\n');
  await File(
    '${root.path}/packages/fp_di/lib/lib.dart',
  ).writeAsString('library fixture;\n');
  await File(
    '${root.path}/packages/fp_di/test/fuzz_test.dart',
  ).writeAsString('void fuzz() {}\n');
  await File(
    '${root.path}/packages/fp_di_fpdart/pubspec.yaml',
  ).writeAsString('name: fp_di_fpdart\n');
  await File(
    '${root.path}/packages/fp_di_fpdart/lib/fpdart.dart',
  ).writeAsString('library fpdartFixture;\n');
  await File(
    '${root.path}/packages/fp_di_fpdart/test/fuzz_test.dart',
  ).writeAsString('void fuzz() {}\n');
  await _git(root, ['init', '-q']);
  await _git(root, ['config', 'user.email', 'fuzz-evidence@example.invalid']);
  await _git(root, ['config', 'user.name', 'Fuzz Evidence Test']);
  await _git(root, ['add', '.']);
  await _git(root, ['commit', '-qm', 'fixture']);
}

Future<ProcessResult> _git(Directory root, List<String> args) =>
    Process.run('git', args, workingDirectory: root.path);
