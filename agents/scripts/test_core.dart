// Runs the core fp_di tests on the Dart VM, without the Flutter test engine.
//
// Usage: dart run agents/scripts/test_core.dart [test args...]
//
// `dart test` cannot resolve this Flutter workspace, and `flutter test` runs
// on the Flutter engine. This script starts package:test with the workspace
// package config instead. Run `flutter pub get` first.
import 'dart:convert';
import 'dart:io';

import '../../verification/fuzz_evidence.dart';

Future<void> main(List<String> args) async {
  final config = File('.dart_tool/package_config.json');
  if (!config.existsSync()) {
    stderr.writeln('Missing ${config.path}. Run `flutter pub get` first.');
    exit(2);
  }
  final packages =
      (jsonDecode(config.readAsStringSync()) as Map)['packages'] as List;
  final test = packages.cast<Map<String, Object?>>().firstWhere(
    (p) => p['name'] == 'test',
    orElse: () {
      stderr.writeln('package:test is not resolved in ${config.path}.');
      exit(2);
    },
  );
  final rootUri = test['rootUri']! as String;
  final root = config.absolute.parent.uri.resolve(
    rootUri.endsWith('/') ? rootUri : '$rootUri/',
  );
  final runner = File.fromUri(root.resolve('bin/test.dart'));
  final testArgs = args.isEmpty ? ['packages/fp_di/test'] : args;
  final plannedSuites = _fuzzSuites(testArgs);
  final evidence = plannedSuites.isEmpty
      ? null
      : await FuzzEvidence.start(
          testArgs: testArgs,
          plannedSuites: plannedSuites,
        );
  if (evidence != null) {
    stderr.writeln('Fuzz evidence: ${evidence.directory.path}');
  }
  var result = -1;
  try {
    final process = await Process.start(Platform.resolvedExecutable, [
      '--packages=${config.path}',
      runner.path,
      ...testArgs,
      if (evidence != null) '--file-reporter=json:${evidence.eventsPath}',
    ], mode: ProcessStartMode.inheritStdio);
    result = await process.exitCode;
  } on ProcessException catch (error) {
    stderr.writeln(error);
  }
  if (evidence != null) {
    await evidence.finish(result);
    stderr.writeln('Fuzz manifest: ${evidence.directory.path}/manifest.json');
  }
  exit(result < 0 ? 1 : result);
}

List<String> _fuzzSuites(List<String> args) {
  if (args.any(['--help', '-h', '--version'].contains)) return const [];
  final targets = args
      .where((arg) => !arg.startsWith('-'))
      .map((arg) => arg.replaceFirst(RegExp(r':\d+(?::\d+)?$'), ''))
      .toList();
  return [
    for (final package in ['fp_di', 'fp_di_fpdart'])
      for (final file in [
        'lifecycle_fuzz_test.dart',
        'lifecycle_fuzz_defect_test.dart',
      ])
        if (targets.any((target) {
          final suite = File('packages/$package/test/$file').absolute.uri;
          if (Directory(target).existsSync()) {
            return suite.path.startsWith(
              Directory(target).absolute.uri.normalizePath().path,
            );
          }
          return suite == File(target).absolute.uri.normalizePath();
        }))
          'packages/$package/test/$file',
  ];
}
