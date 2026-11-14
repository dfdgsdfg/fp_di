import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fp_di_devtools/src/client.dart';
import 'package:fp_di_devtools/src/model.dart';

/// The folder of the answers that the real inspector served, recorded by
/// `packages/fp_di/test/support/dump_devtools_fixtures.dart`. The app and the
/// protocol cannot drift, because the tests read the same files.
Directory fixtureDirectory() {
  const relative = 'test/support/devtools_fixtures';
  for (final candidate in ['../fp_di/$relative', 'packages/fp_di/$relative']) {
    final directory = Directory(candidate);
    if (directory.existsSync()) return directory;
  }
  throw StateError('The recorded fixtures are missing: $relative');
}

/// A recorded answer or event, without the change of its fields.
Map<String, Object?> fixture(String name) {
  final file = File('${fixtureDirectory().path}/$name.json');
  return Map<String, Object?>.from(jsonDecode(file.readAsStringSync()) as Map);
}

/// A call that the app made.
typedef Call = ({String method, Map<String, String> args});

/// An [InspectorClient] that serves the recorded answers.
///
/// Root 1 and its nodes come from the fixtures. A node or a scope without a
/// recorded answer gets an empty answer. [version] replaces the `version` of
/// each answer.
final class FakeInspectorClient implements InspectorClient {
  FakeInspectorClient({this.version = protocolVersion, bool connected = true})
    : _connected = ValueNotifier<bool>(connected);

  final int version;
  final ValueNotifier<bool> _connected;
  final StreamController<RawEvent> _events =
      StreamController<RawEvent>.broadcast();
  final StreamController<void> _restarts = StreamController<void>.broadcast();

  /// The names of the queries that answer with the recorded error answer.
  final Set<String> failing = {};

  /// The `shape` object that scope 2 serves instead of the recorded one.
  Map<String, Object?>? shapeOverride;

  /// Every call, in order.
  final List<Call> calls = [];

  /// The nodes of root 1 with a recorded answer.
  static const Map<int, String> nodeFixtures = {
    0: 'node_failed',
    1: 'node_waiting',
    2: 'node_values',
    7: 'node_collection',
  };

  List<Call> callsTo(String name) => [
    for (final call in calls)
      if (call.method == 'ext.fp_di.$name') call,
  ];

  /// Connects or disconnects the fake app.
  void setConnected(bool value) => _connected.value = value;

  /// Posts an event as the VM service does.
  void emit(String kind, Map<String, Object?> data) =>
      _events.add((kind: kind, data: data));

  /// Tells the app that the debugged app restarted.
  void restart() => _restarts.add(null);

  @override
  ValueListenable<bool> get connected => _connected;

  @override
  Stream<RawEvent> get events => _events.stream;

  @override
  Stream<void> get restarts => _restarts.stream;

  @override
  Future<Map<String, Object?>> query(
    String method, [
    Map<String, String> args = const {},
  ]) async {
    calls.add((method: method, args: args));
    final name = method.substring('ext.fp_di.'.length);
    final answer = failing.contains(name)
        ? fixture('error_unknown_root')
        : _answer(method, args);
    return {...answer, 'version': version};
  }

  Map<String, Object?> _answer(String method, Map<String, String> args) {
    final root = args['root'];
    final values = args['values'] == 'true';
    switch (method) {
      case 'ext.fp_di.roots':
        return fixture('roots');
      case 'ext.fp_di.listen':
        return {
          'format': protocolFormat,
          'version': protocolVersion,
          'listening': args['enabled'] == 'true',
        };
      case 'ext.fp_di.state':
        if (root == '1') return fixture(values ? 'state_values' : 'state');
        if (root == '2') {
          return {
            'format': protocolFormat,
            'version': protocolVersion,
            'scope': {
              'id': 10,
              'phase': 'initialized',
              'module': 'slow app',
              'children': <Object?>[],
              'nodes': <Object?>[],
            },
          };
        }
        return fixture('error_unknown_root');
      case 'ext.fp_di.node':
        if (root != '1') return fixture('error_unknown_root');
        final name = nodeFixtures[int.parse(args['node']!)];
        if (name == null) {
          return {
            'format': protocolFormat,
            'version': protocolVersion,
            'reads': <Object?>[],
            'readers': <Object?>[],
            'failure': null,
            'cause': null,
          };
        }
        final answer = fixture(name);
        if (!values) answer.remove('value');
        return answer;
      case 'ext.fp_di.shape':
        if (args['scope'] == '2') {
          final recorded = fixture('shape');
          final override = shapeOverride;
          return override == null ? recorded : {...recorded, 'shape': override};
        }
        // A scope without a recorded shape has no members.
        return {
          'format': protocolFormat,
          'version': protocolVersion,
          'shape': {
            'format': 'fp_di.shape',
            'version': 1,
            'label': 'scope ${args['scope']}',
            'members': <Object?>[],
            'edges': <Object?>[],
            'undeclared': <Object?>[],
            'duplicates': <Object?>[],
            'cycles': <Object?>[],
            'longestChain': <Object?>[],
            'ancestors': {'labels': <Object?>[], 'publishes': <Object?>[]},
          },
        };
    }
    throw StateError('unknown call $method');
  }

  @override
  void dispose() {
    _connected.dispose();
    unawaited(_events.close());
    unawaited(_restarts.close());
  }
}
