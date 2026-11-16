// The purity of the rules of `lib/src/core/` (V-L-AR-DI-004): no effect type,
// no word of the asynchronous shell, and no import of `runtime/`.
import 'dart:io';

import 'package:test/test.dart';

/// The words that a file of the core must not hold, comments included.
final banned = RegExp('Future|Completer|Stream|Timer|Zone|async|await');

Directory coreDirectory() {
  for (final path in ['lib/src/core', 'packages/fp_di/lib/src/core']) {
    final directory = Directory(path);
    if (directory.existsSync()) return directory;
  }
  throw StateError('The directory lib/src/core does not exist.');
}

List<File> coreFiles() => coreDirectory()
    .listSync()
    .whereType<File>()
    .where((file) => file.path.endsWith('.dart'))
    .toList();

void main() {
  test('the core folder has files that start with core', () {
    final files = coreFiles();
    expect(files, isNotEmpty);
    for (final file in files) {
      expect(file.uri.pathSegments.last, startsWith('core'));
    }
  });

  test('no line of the core holds an effect type or an asynchronous word', () {
    for (final file in coreFiles()) {
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

  test('no file of the core imports dart:async or a file of runtime/', () {
    final imports = RegExp(r'''^\s*(import|export)\s+['"]([^'"]+)['"]''');
    for (final file in coreFiles()) {
      for (final line in file.readAsLinesSync()) {
        final uri = imports.firstMatch(line)?.group(2);
        if (uri == null) continue;
        expect(uri, isNot('dart:async'), reason: file.path);
        expect(uri, isNot(contains('runtime/')), reason: file.path);
        expect(uri, isNot(contains('/runtime_')), reason: file.path);
      }
    }
  });
}
