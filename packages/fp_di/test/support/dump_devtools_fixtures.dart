// Records real answers and events of the DevTools inspector as JSON files,
// for the extension app (V-T-TL-DT-005) to serve as recorded fixtures.
//
// Run from the workspace root, with assertions on, because the inspector
// exists only then:
//
//   dart run --enable-asserts packages/fp_di/test/support/dump_devtools_fixtures.dart
//
// The files go to `devtools_fixtures/` beside this script. Pass `--out=<dir>`
// to write somewhere else. The fixture uses fixed stack traces, so the files
// hold no path of the machine. The slow-mutation `elapsedMs` varies from run
// to run, so the script writes the threshold instead.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fp_di/fp_di.dart';

import 'devtools_fixture.dart';

const _threshold = Duration(milliseconds: 20);

Future<void> main(List<String> args) async {
  var asserts = false;
  assert(asserts = true);
  if (!asserts) {
    stderr.writeln('Run with assertions: dart run --enable-asserts <script>');
    exit(2);
  }
  final out = args
      .where((arg) => arg.startsWith('--out='))
      .map((arg) => arg.substring('--out='.length))
      .firstOrNull;
  final directory = out != null
      ? Directory(out)
      : Directory.fromUri(Platform.script.resolve('devtools_fixtures/'));
  directory.createSync(recursive: true);

  final recorder = InspectorRecorder()..install();
  final written = <String>[];
  void write(String name, Object? json) {
    const encoder = JsonEncoder.withIndent('  ');
    File(
      '${directory.path}/$name.json',
    ).writeAsStringSync('${encoder.convert(json)}\n');
    written.add(name);
  }

  // The scenario of V-Q-TL-DT-001: a session that opens before the app, a
  // failed activation, a node that waits for it, and a node disposed alone.
  final fixture = DevtoolsFixture.declare();
  await fixture.session.initialize();
  await recorder.call('listen', {'enabled': 'true'});
  await fixture.root.initialize();
  await fixture.root.node(key: doomedKey).dispose();
  await settle();

  final rootId =
      (((await recorder.call('roots'))['roots']! as List).single as Map)['id']
          as int;
  final state = await recorder.call('state', {'root': '$rootId'});
  final tree = state['scope']! as Map<String, Object?>;
  Future<Map<String, Object?>> node(String label, {bool values = false}) =>
      recorder.call('node', {
        'root': '$rootId',
        'node': '${nodeIdByLabel(tree, label)}',
        if (values) 'values': 'true',
      });

  write('state', state);
  write(
    'state_values',
    await recorder.call('state', {'root': '$rootId', 'values': 'true'}),
  );
  write('node_waiting', await node('profile'));
  write('node_failed', await node('login'));
  write('node_collection', await node('registry'));
  write('node_values', await node('config', values: true));
  write(
    'shape',
    await recorder.call('shape', {
      'scope': '${scopeByModule(tree, 'session')!['id']}',
    }),
  );
  write('error_unknown_root', await recorder.call('state', {'root': '999'}));

  final transitions = recorder.of('fp_di:transition');
  final failure = transitions.firstWhere(
    (event) => (event['changed']! as List).any(
      (change) =>
          ((change as Map)['after'] as Map?)?['phase'] == 'activationFailed',
    ),
    orElse: () => transitions.first,
  );
  write('event_transition', failure);
  write('event_error', recorder.of('fp_di:error').first);

  // A slow mutation of a root that was created with `onSlowMutation`.
  final gate = Completer<void>();
  final slowRoot = Scope(
    onSlowMutation: (_) {},
    slowMutationThreshold: _threshold,
    module: Module(
      debugLabel: 'slow app',
      components: [
        Component<int>.effect(
          debugLabel: 'warm cache',
          dependency: Dependency<int>(
            create: () async {
              await gate.future;
              return 1;
            },
          ),
        ),
      ],
    ),
  );
  final setup = slowRoot.initialize();
  while (recorder.of('fp_di:slowMutation').isEmpty) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  gate.complete();
  await setup;
  write('event_slow_mutation', {
    ...recorder.of('fp_di:slowMutation').first,
    'elapsedMs': _threshold.inMilliseconds,
  });

  // Both roots are live now, so `roots` names the root of each event.
  write('roots', await recorder.call('roots'));
  await recorder.call('listen', {'enabled': 'false'});
  await slowRoot.dispose();
  await fixture.root.dispose();
  recorder.uninstall();
  stdout.writeln(
    'Wrote ${written.length} files to ${directory.path}: ${written.join(', ')}',
  );
  stdout.writeln(
    'The scenario posted ${transitions.length} transition events and '
    '${recorder.of('fp_di:error').length} error events.',
  );
}
