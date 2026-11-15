import 'dart:io';

import 'package:test/test.dart';

/// The words that the pure core must not hold: the effect types, and the
/// words of the asynchronous shell.
final banned = RegExp('Future|async|IORef|Zone|Timer|Task');

Directory coreDirectory() {
  for (final path in ['lib/src/core', 'packages/fp_di_fpdart/lib/src/core']) {
    final directory = Directory(path);
    if (directory.existsSync()) return directory;
  }
  throw StateError('The directory lib/src/core does not exist.');
}

void main() {
  test('the core holds no effect type and no asynchronous word', () {
    final files = coreDirectory()
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .toList();
    expect(files, isNotEmpty);
    for (final file in files) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        expect(
          banned.hasMatch(lines[i]),
          isFalse,
          reason: '${file.path}:${i + 1}: ${lines[i]}',
        );
      }
    }
  });

  test('the core does not import dart:async', () {
    for (final file in coreDirectory().listSync().whereType<File>()) {
      expect(file.readAsStringSync(), isNot(contains('dart:async')));
    }
  });
}
