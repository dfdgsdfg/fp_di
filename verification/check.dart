// Formal verification runner: pinned TLC, named scenarios, evidence report.
//
// Usage: dart run verification/check.dart [--fetch] [--scenario NAME]...
//
// Exits non-zero unless every selected scenario completes with its expected
// outcome. A tool error, parse error, timeout, or missing toolchain is
// incomplete evidence, never a pass. See specs/verification/formal/spec.md.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'evidence.dart';

const _lockPath = 'verification/toolchain.lock.json';
const _modelsRoot = 'verification/tla';
const _timeout = Duration(minutes: 5);

Future<void> main(List<String> args) async {
  final fetch = args.contains('--fetch');
  final selected = <String>{
    for (var i = 0; i < args.length - 1; i++)
      if (args[i] == '--scenario') args[i + 1],
  };

  final lock =
      jsonDecode(File(_lockPath).readAsStringSync()) as Map<String, Object?>;
  final tlc = lock['tlc']! as Map<String, Object?>;
  final java = lock['java']! as Map<String, Object?>;
  final jar = File(tlc['path']! as String);

  final javaVersion = await _javaVersion(java['minimumMajor']! as int);
  if (!jar.existsSync()) {
    if (!fetch) {
      _fail(
        'TLC ${tlc['version']} is missing at ${jar.path}. '
        'Run with --fetch to download the pinned artifact.',
      );
    }
    jar.parent.createSync(recursive: true);
    final download = await Process.run('curl', [
      '-sSfL',
      '-o',
      jar.path,
      tlc['url']! as String,
    ]);
    if (download.exitCode != 0) _fail('Download failed: ${download.stderr}');
  }
  final jarHash = await _sha256(jar.path);
  if (jarHash != tlc['sha256']) {
    _fail('Checksum mismatch for ${jar.path}: $jarHash != ${tlc['sha256']}');
  }

  final runId = DateTime.now().toUtc().toIso8601String().replaceAll(':', '');
  final outDir = Directory('output/verification/$runId')
    ..createSync(recursive: true);
  final models =
      Directory(_modelsRoot)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.uri.pathSegments.last == 'scenarios.json')
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  final reports = <Map<String, Object?>>[];
  var allOk = true;
  for (final manifest in models) {
    final dir = manifest.parent;
    final spec =
        jsonDecode(manifest.readAsStringSync()) as Map<String, Object?>;
    final module = '${dir.path}/${spec['module']}';
    final sources = {
      for (final s in (spec['source']! as List).cast<String>())
        s: await _sha256(s),
    };
    final scenarios = <Map<String, Object?>>[];
    for (final raw
        in (spec['scenarios']! as List).cast<Map<String, Object?>>()) {
      final name = raw['name']! as String;
      if (selected.isNotEmpty && !selected.contains(name)) continue;
      final result = await _runScenario(
        jar: jar.path,
        dir: dir.path,
        module: spec['module']! as String,
        name: name,
        expected: raw['expect']!,
        outDir: '${outDir.path}/$name',
      );
      if (result['status'] != 'ok') allOk = false;
      stdout.writeln(
        '${result['status'].toString().padRight(10)} $name '
        '(expected ${jsonEncode(raw['expect'])}, '
        'observed ${jsonEncode(result['observed'])})',
      );
      scenarios.add(result);
    }
    reports.add({
      'model': module,
      'modelSha256': await _sha256(module),
      'sources': sources,
      'scenarios': scenarios,
    });
  }
  final missing = missingScenarios(selected, [
    for (final report in reports)
      for (final scenario in report['scenarios']! as List)
        (scenario as Map<String, Object?>)['name']! as String,
  ]);
  if (missing.isNotEmpty) {
    _fail('No scenario named ${missing.join(', ')}; check the name.');
  }

  final report = {
    'runId': runId,
    'status': allOk ? 'passed' : 'failed',
    'tool': {
      'tlc': tlc['version'],
      'tlcSha256': jarHash,
      'java': javaVersion,
      'lockSha256': await _sha256(_lockPath),
    },
    'assumptions':
        'Bounded exhaustive search of each configuration; '
        'liveness under the weak-fairness assumptions in FairSpec. '
        'Not a refinement proof of the Dart implementation.',
    'models': reports,
  };
  // A passing run must also be complete evidence: every field present and
  // every scenario with its expected outcome and state counts.
  if (allOk) {
    final problems = reportProblems(report);
    if (problems.isNotEmpty) {
      allOk = false;
      report['status'] = 'failed';
      report['problems'] = problems;
      for (final problem in problems) {
        stdout.writeln('incomplete $problem');
      }
    }
  }
  File(
    '${outDir.path}/report.json',
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  stdout.writeln('${allOk ? 'PASSED' : 'FAILED'}: ${outDir.path}/report.json');
  exit(allOk ? 0 : 1);
}

Future<Map<String, Object?>> _runScenario({
  required String jar,
  required String dir,
  required String module,
  required String name,
  required Object expected,
  required String outDir,
}) async {
  Directory(outDir).createSync(recursive: true);
  final cfgPath = '$dir/$name.cfg';
  final cfg = File(cfgPath).readAsStringSync();
  final watch = Stopwatch()..start();
  final process = await Process.start('java', [
    '-XX:+UseParallelGC',
    '-cp',
    File(jar).absolute.path,
    'tlc2.TLC',
    '-workers',
    'auto',
    '-metadir',
    Directory('$outDir/states').absolute.path,
    '-config',
    '$name.cfg',
    module,
  ], workingDirectory: dir);
  final output = StringBuffer();
  final done = Future.wait([
    process.stdout.transform(utf8.decoder).forEach(output.write),
    process.stderr.transform(utf8.decoder).forEach(output.write),
  ]);
  int? exitCode;
  try {
    exitCode = await process.exitCode.timeout(_timeout);
    await done;
  } on TimeoutException {
    process.kill();
  }
  watch.stop();
  final log = output.toString();
  File('$outDir/tlc.log').writeAsStringSync(log);

  final properties = section(cfg, 'PROPERTIES');
  final observed = classify(log, exitCode, properties);
  final stats = RegExp(
    r'([\d,]+) states generated, ([\d,]+) distinct states',
  ).allMatches(log).lastOrNull;
  final depth = RegExp(
    r'depth of the complete state graph search is (\d+)',
  ).firstMatch(log);
  return {
    'name': name,
    'config': cfgPath,
    'configSha256': await _sha256(cfgPath),
    'constants': section(cfg, 'CONSTANTS'),
    'invariants': section(cfg, 'INVARIANTS'),
    'properties': properties,
    'expected': expected,
    'observed': observed,
    'status': scenarioStatus(observed, expected),
    'statesGenerated': stats?.group(1)?.replaceAll(',', ''),
    'distinctStates': stats?.group(2)?.replaceAll(',', ''),
    'depth': depth?.group(1),
    'exitCode': exitCode,
    'durationMs': watch.elapsedMilliseconds,
    'log': '$outDir/tlc.log',
  };
}

Future<String> _sha256(String path) async {
  for (final cmd in [
    ['shasum', '-a', '256', path],
    ['sha256sum', path],
  ]) {
    try {
      final r = await Process.run(cmd.first, cmd.sublist(1));
      if (r.exitCode == 0) return (r.stdout as String).split(' ').first;
    } on ProcessException {
      continue;
    }
  }
  _fail('Neither shasum nor sha256sum is available.');
}

Future<String> _javaVersion(int minimumMajor) async {
  final ProcessResult r;
  try {
    r = await Process.run('java', ['-version']);
  } on ProcessException {
    _fail('java is not on PATH; TLC requires Java $minimumMajor or newer.');
  }
  final text = '${r.stderr}${r.stdout}';
  final match = RegExp(r'version "(\d+)').firstMatch(text);
  final major = int.tryParse(match?.group(1) ?? '');
  if (major == null || major < minimumMajor) {
    _fail('Java $minimumMajor+ is required; found: ${text.split('\n').first}');
  }
  return text.split('\n').first.trim();
}

Never _fail(String message) {
  stderr.writeln('INCOMPLETE: $message');
  exit(2);
}
