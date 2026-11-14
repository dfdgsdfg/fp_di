// Runs the core fp_di tests on the Dart VM, without the Flutter test engine.
//
// Usage: dart run agents/scripts/test_core.dart [test args...]
//
// `dart test` cannot resolve this Flutter workspace, and `flutter test` runs
// on the Flutter engine. This script starts package:test with the workspace
// package config instead. Run `flutter pub get` first.
import 'dart:convert';
import 'dart:io';

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
  final process = await Process.start(Platform.resolvedExecutable, [
    '--packages=${config.path}',
    runner.path,
    if (args.isEmpty) 'packages/fp_di/test' else ...args,
  ], mode: ProcessStartMode.inheritStdio);
  exit(await process.exitCode);
}
