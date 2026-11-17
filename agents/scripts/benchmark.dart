// Runs the fixed fp_di lifecycle cost fixtures in fresh, sequential VMs.
import 'dart:io';

import '../../verification/benchmark_evidence.dart';

const _usage =
    '''Usage: dart run agents/scripts/benchmark.dart [--samples N] [--help]

Run the fixed lifecycle cost fixtures in sequential fresh Dart VMs.
''';

Future<void> main(List<String> args) async {
  final samples = _parseArguments(args);
  if (samples == null) return;
  final evidence = await BenchmarkEvidence.start(
    samples: samples,
    arguments: args,
  );
  stderr.writeln('Benchmark evidence: ${evidence.directory.path}');
  var allPassed = true;
  for (var sample = 1; sample <= samples; sample++) {
    final eventsPath = evidence.eventsPath(sample);
    await evidence.prepareSample(sample);
    var childExitCode = -1;
    var childStdout = '';
    var childStderr = '';
    try {
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'agents/scripts/test_core.dart',
        ...benchmarkSuiteArgs,
        '--file-reporter=json:$eventsPath',
      ], workingDirectory: evidence.workspaceRoot.path);
      childExitCode = result.exitCode;
      childStdout = result.stdout as String;
      childStderr = result.stderr as String;
    } on ProcessException catch (error) {
      childStderr = error.toString();
    }
    final sampleResult = await evidence.recordSample(
      sampleNumber: sample,
      exitCode: childExitCode,
      stdout: childStdout,
      stderr: childStderr,
    );
    stderr.writeln(
      'Sample $sample/$samples: ${sampleResult.status} '
      '(exit ${sampleResult.exitCode})',
    );
    if (sampleResult.status != 'passed') {
      allPassed = false;
      break;
    }
  }
  final passed = await evidence.finish();
  stderr.writeln(
    'Benchmark manifest: ${evidence.directory.path}/manifest.json',
  );
  if (!allPassed || !passed) exitCode = 1;
}

int? _parseArguments(List<String> args) {
  if (args.contains('--help') || args.contains('-h')) {
    if (args.length != 1) {
      stderr.writeln('Do not combine --help with other arguments.');
      stderr.write(_usage);
      exitCode = 2;
      return null;
    }
    stdout.write(_usage);
    return null;
  }
  var samples = 5;
  var sawSamples = false;
  for (var index = 0; index < args.length; index++) {
    if (args[index] != '--samples') {
      stderr.writeln('Unknown argument: ${args[index]}');
      stderr.write(_usage);
      exitCode = 2;
      return null;
    }
    if (sawSamples || index + 1 >= args.length) {
      stderr.writeln(
        '--samples requires one positive integer and may appear once.',
      );
      stderr.write(_usage);
      exitCode = 2;
      return null;
    }
    final value = args[++index];
    final parsed = int.tryParse(value);
    if (parsed == null || parsed < 1 || value != '$parsed') {
      stderr.writeln('--samples must be a positive integer.');
      stderr.write(_usage);
      exitCode = 2;
      return null;
    }
    samples = parsed;
    sawSamples = true;
  }
  return samples;
}
