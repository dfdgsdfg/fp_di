// Shared source and environment provenance for verification runs.
import 'dart:io';

/// Captures source snapshots, dependency versions, and execution identity.
Future<Map<String, Object?>> captureRunProvenance({
  required Directory workspaceRoot,
  required Directory evidenceDirectory,
  required List<String> arguments,
  required List<String> packageNames,
  List<String> sourcePaths = const [],
  Map<String, String> environment = const {},
}) async {
  final root = workspaceRoot.absolute;
  final problems = <String>[];
  final gitHead = await _git(root, ['rev-parse', 'HEAD']);
  final gitStatus = await _git(root, [
    'status',
    '--porcelain=v1',
    '--untracked-files=all',
  ]);
  final objectFormat = await _git(root, ['rev-parse', '--show-object-format']);
  if (gitHead.exitCode != 0) {
    problems.add(
      'git rev-parse HEAD failed: ${(gitHead.stderr as String).trim()}',
    );
  }
  if (gitStatus.exitCode != 0) {
    problems.add('git status failed: ${(gitStatus.stderr as String).trim()}');
  }
  if (objectFormat.exitCode != 0) {
    final error = (objectFormat.stderr as String).trim();
    problems.add('git object format lookup failed: $error');
  }
  final files = await _relevantFiles(root, packageNames, sourcePaths);
  final hashes = <String, String>{};
  final snapshotPaths = <String, String>{};
  final sources = Directory('${evidenceDirectory.path}/sources');
  await sources.create(recursive: true);
  final relatives = files.map((file) => _relative(root, file.path)).toList();
  final blobResult = await _git(root, ['hash-object', '--', ...relatives]);
  if (blobResult.exitCode == 0) {
    final blobHashes = (blobResult.stdout as String).trimRight().split('\n');
    if (blobHashes.length != relatives.length) {
      problems.add(
        'git hash-object returned an unexpected number of source hashes',
      );
    }
    for (var index = 0; index < relatives.length; index++) {
      final relative = relatives[index];
      if (index < blobHashes.length) {
        hashes[relative] = blobHashes[index];
      }
      final file = files[index];
      final snapshotPath = '$relative.source';
      snapshotPaths[relative] = snapshotPath;
      final snapshot = File('${sources.path}/$snapshotPath');
      await snapshot.parent.create(recursive: true);
      await file.copy(snapshot.path);
    }
  } else {
    problems.add(
      'git hash-object failed: ${(blobResult.stderr as String).trim()}',
    );
  }
  final lock = File('${root.path}/pubspec.lock');
  if (await lock.exists()) {
    await lock.copy('${evidenceDirectory.path}/pubspec.lock');
  } else {
    problems.add('missing pubspec.lock');
  }
  final patch = await _git(root, ['diff', '--binary', 'HEAD']);
  if (patch.exitCode == 0) {
    await File(
      '${evidenceDirectory.path}/source.patch',
    ).writeAsString(patch.stdout as String);
  } else {
    problems.add(
      'git diff --binary HEAD failed: ${(patch.stderr as String).trim()}',
    );
  }
  return {
    'sdk': Platform.version,
    'os': Platform.operatingSystem,
    'osVersion': Platform.operatingSystemVersion,
    'resolvedExecutable': Platform.resolvedExecutable,
    'executableArguments': Platform.executableArguments,
    'testArgs': arguments,
    'machine': await _machine(),
    'hashAlgorithm': objectFormat.exitCode == 0
        ? 'git ${(objectFormat.stdout as String).trim()} object hash'
        : null,
    'environment': environment,
    'gitHead': gitHead.exitCode == 0 ? (gitHead.stdout as String).trim() : null,
    'gitStatus': gitStatus.exitCode == 0 ? gitStatus.stdout as String : null,
    'sourceHashes': hashes,
    'sourceSnapshots': snapshotPaths,
    'provenanceProblems': problems,
  };
}

Future<List<File>> _relevantFiles(
  Directory root,
  List<String> packageNames,
  List<String> sourcePaths,
) async {
  final files = <String, File>{};
  Future<void> addTree(String relative) async {
    final dir = Directory('${root.path}/$relative');
    if (!await dir.exists()) return;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) files[_relative(root, entity.path)] = entity;
    }
  }

  for (final package in packageNames) {
    await addTree('packages/$package/lib');
    await addTree('packages/$package/test');
    final packagePubspec = 'packages/$package/pubspec.yaml';
    final file = File('${root.path}/$packagePubspec');
    if (await file.exists()) files[packagePubspec] = file;
  }
  files.removeWhere((relative, _) => !relative.endsWith('.dart'));
  final metadataPaths = <String>{
    'pubspec.yaml',
    'pubspec.lock',
    for (final package in packageNames) 'packages/$package/pubspec.yaml',
    'verification/run_provenance.dart',
    ...sourcePaths,
  };
  for (final relative in metadataPaths) {
    final file = File('${root.path}/$relative');
    if (await file.exists()) files[relative] = file;
  }
  return files.values.toList()..sort((a, b) => a.path.compareTo(b.path));
}

String _relative(Directory root, String path) =>
    path.startsWith('${root.path}/')
    ? path.substring(root.path.length + 1)
    : path;

/// Reports capture failures and source changes detected after execution.
Future<List<String>> checkRunProvenance({
  required Directory workspaceRoot,
  required Map<String, Object?> provenance,
  required List<String> packageNames,
  List<String> sourcePaths = const [],
}) async {
  final root = workspaceRoot.absolute;
  final problems = <String>[
    for (final problem
        in (provenance['provenanceProblems']! as List).cast<String>())
      'provenance: $problem',
  ];
  final originalHashes = (provenance['sourceHashes']! as Map)
      .cast<String, Object?>();
  final currentFiles = await _relevantFiles(root, packageNames, sourcePaths);
  final currentPaths = currentFiles.map((f) => _relative(root, f.path)).toSet();
  final originalPaths = originalHashes.keys.toSet();
  for (final path in originalPaths.difference(currentPaths)) {
    problems.add('source removed during run: $path');
  }
  for (final path in currentPaths.difference(originalPaths)) {
    problems.add('source added during run: $path');
  }
  final relatives = originalPaths.intersection(currentPaths).toList()..sort();
  if (relatives.isEmpty) {
    problems.add('no source hashes available for verification');
    return problems;
  }
  final result = await _git(root, ['hash-object', '--', ...relatives]);
  if (result.exitCode != 0) {
    problems.add('could not recheck source hashes: ${result.stderr}');
  } else {
    final hashes = (result.stdout as String).trimRight().split('\n');
    for (var index = 0; index < relatives.length; index++) {
      final relative = relatives[index];
      if (index >= hashes.length || hashes[index] != originalHashes[relative]) {
        problems.add('source changed during run: $relative');
      }
    }
  }
  return problems;
}

Future<Map<String, Object?>> _machine() async {
  final machine = <String, Object?>{
    'logicalProcessors': Platform.numberOfProcessors,
  };
  if (Platform.isMacOS) {
    for (final (key, name) in [
      ('cpuModel', 'machdep.cpu.brand_string'),
      ('memoryBytes', 'hw.memsize'),
      ('architecture', 'hw.machine'),
    ]) {
      final result = await Process.run('sysctl', ['-n', name]);
      if (result.exitCode == 0) {
        final value = (result.stdout as String).trim();
        machine[key] = key == 'memoryBytes' ? int.tryParse(value) : value;
      }
    }
  } else if (Platform.isLinux) {
    final cpu = File('/proc/cpuinfo');
    if (await cpu.exists()) {
      final text = await cpu.readAsString();
      machine['cpuModel'] = RegExp(
        r'^(?:model name|Hardware)\s*:\s*(.+)$',
        multiLine: true,
      ).firstMatch(text)?.group(1);
    }
    final memory = File('/proc/meminfo');
    if (await memory.exists()) {
      final match = RegExp(
        r'MemTotal:\s*(\d+)',
      ).firstMatch(await memory.readAsString());
      if (match != null) {
        machine['memoryBytes'] = int.parse(match.group(1)!) * 1024;
      }
    }
    final result = await Process.run('uname', ['-m']);
    if (result.exitCode == 0) {
      machine['architecture'] = (result.stdout as String).trim();
    }
  }
  return machine;
}

Future<ProcessResult> _git(Directory root, List<String> args) =>
    Process.run('git', args, workingDirectory: root.path);
