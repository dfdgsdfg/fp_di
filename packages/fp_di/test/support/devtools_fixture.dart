// The fixtures of the DevTools inspector tests (V-T-TL-DT-002) and of the
// fixture dump `dump_devtools_fixtures.dart`.
import 'dart:async';
import 'dart:convert';

import 'package:fp_di/fp_di.dart';
import 'package:fp_di/src/runtime/runtime_inspector_hooks.dart';

const baseKey = DiKey<int>(name: 'base');
const tokenKey = DiKey<int>(name: 'token');
const configKey = DiKey<String>(name: 'config');
const doomedKey = DiKey<int>(name: 'doomed');
const registryKey = DiKey<List<String>>(name: 'registry');
const plugins = DiSetKey<String>(name: 'plugins');

/// A fixed stack trace, so a recorded answer holds no path of the machine.
const syntheticStack =
    '#0      Login.start (package:shop/session/login.dart:41:7)\n'
    '#1      Session.open (package:shop/session/session.dart:18:12)\n'
    '#2      main (package:shop/main.dart:9:3)';

/// The recorder that replaces the real `dart:developer` calls.
final class InspectorRecorder {
  /// The names that the inspector registered, in order.
  final List<String> registrations = <String>[];
  final Map<String, InspectorHandler> handlers = <String, InspectorHandler>{};

  /// The posted events, as JSON values.
  final List<({String kind, Map<String, Object?> data})> events = [];

  /// Replaces the hooks. Call it before the first root of the isolate.
  void install() {
    RuntimeInspectorHooks.reset();
    RuntimeInspectorHooks.registerExtension = (method, handler) {
      registrations.add(method);
      handlers[method] = handler;
    };
    RuntimeInspectorHooks.postEvent = (kind, data) {
      events.add((kind: kind, data: _roundTrip(data)));
    };
  }

  /// Calls the handler `ext.fp_di.[name]` as the VM service does, and returns
  /// the answer as a JSON object.
  Future<Map<String, Object?>> call(
    String name, [
    Map<String, String> parameters = const {},
  ]) async {
    final method = 'ext.fp_di.$name';
    final handler = handlers[method];
    if (handler == null) throw StateError('$method is not registered');
    return _roundTrip(await handler(method, parameters));
  }

  /// The events of one kind.
  List<Map<String, Object?>> of(String kind) => [
    for (final event in events)
      if (event.kind == kind) event.data,
  ];

  /// Restores the real hooks.
  void uninstall() => RuntimeInspectorHooks.reset();
}

/// A value as the VM service sends it: encoded and decoded as JSON.
Map<String, Object?> _roundTrip(Map<String, Object?> value) =>
    (jsonDecode(jsonEncode(value)) as Map).cast<String, Object?>();

/// Lets the microtasks and the zero timers run.
Future<void> settle() => Future<void>.delayed(Duration.zero);

/// A root with a child that initialized before it:
///
/// - `app` (the root module) holds an active `config`, an active `base`, a
///   `greeter` that reads `config`, two contributions to `plugins`, a
///   `registry` that reads the collection, a `doomed` node that the fixture
///   disposes alone, and an `orphan` that reads `doomed` and waits.
/// - `session` (a child) holds `login`, which reads `base` and fails when
///   `base` appears, and `profile`, which reads the token of `login` and
///   waits.
/// - `spare` is a child that never initializes.
final class DevtoolsFixture {
  DevtoolsFixture._(this.root, this.session, this.spare);

  final Scope root;
  final Scope session;
  final Scope spare;

  /// Builds the scopes and initializes `session`, then `app`.
  static Future<DevtoolsFixture> create({
    SlowMutationListener? onSlowMutation,
    Duration slowMutationThreshold = const Duration(seconds: 2),
  }) async {
    final fixture = DevtoolsFixture.declare(
      onSlowMutation: onSlowMutation,
      slowMutationThreshold: slowMutationThreshold,
    );
    await fixture.session.initialize();
    await fixture.root.initialize();
    await fixture.root.node(key: doomedKey).dispose();
    return fixture;
  }

  /// Builds the scopes without any `initialize`.
  factory DevtoolsFixture.declare({
    SlowMutationListener? onSlowMutation,
    Duration slowMutationThreshold = const Duration(seconds: 2),
  }) {
    final root = Scope(
      onSlowMutation: onSlowMutation,
      slowMutationThreshold: slowMutationThreshold,
      module: Module(
        debugLabel: 'app',
        components: [
          Component<String>.value(
            value: 'prod',
            key: configKey,
            debugLabel: 'config',
          ),
          Component<int>.value(value: 1, key: baseKey, debugLabel: 'base'),
          Component<String>(
            key: const DiKey<String>(name: 'greeting'),
            debugLabel: 'greeter',
            dependency: Dependency.require<String>(
              key: configKey,
            ).map((config) => 'hello $config'),
          ),
          Component<String>.into(
            key: plugins,
            debugLabel: 'pluginA',
            dependency: Dependency<String>(create: () => 'a'),
          ),
          Component<String>.into(
            key: plugins,
            debugLabel: 'pluginB',
            dependency: Dependency<String>(create: () => 'b'),
          ),
          Component<List<String>>(
            key: registryKey,
            debugLabel: 'registry',
            dependency: Dependency.requireSet(
              key: plugins,
            ).map((set) => set.toList()),
          ),
          Component<int>.value(value: 7, key: doomedKey, debugLabel: 'doomed'),
          Component<int>(
            key: const DiKey<int>(name: 'orphan'),
            debugLabel: 'orphan',
            dependency: Dependency.require<int>(
              key: doomedKey,
            ).map((doomed) => doomed + 1),
          ),
        ],
      ),
    );
    final session = root.child(
      module: Module(
        debugLabel: 'session',
        components: [
          Component<int>(
            key: tokenKey,
            debugLabel: 'login',
            dependency: Dependency.require<int>(key: baseKey).map<int>(
              (_) => Error.throwWithStackTrace(
                StateError('boom'),
                StackTrace.fromString(syntheticStack),
              ),
            ),
          ),
          Component<String>(
            key: const DiKey<String>(name: 'profile'),
            debugLabel: 'profile',
            dependency: Dependency.require<int>(
              key: tokenKey,
            ).map((token) => 'user$token'),
          ),
        ],
      ),
    );
    final spare = root.child();
    return DevtoolsFixture._(root, session, spare);
  }

  Future<void> dispose() => root.dispose();
}

/// The id of the node with [label] in a `state` answer, or null.
int? nodeIdByLabel(Map<String, Object?> scope, String label) {
  for (final node in (scope['nodes']! as List).cast<Map<String, Object?>>()) {
    if (node['label'] == label) return node['id']! as int;
  }
  for (final child
      in (scope['children']! as List).cast<Map<String, Object?>>()) {
    final found = nodeIdByLabel(child, label);
    if (found != null) return found;
  }
  return null;
}

/// The scope of a `state` answer whose module is [module], or null.
Map<String, Object?>? scopeByModule(Map<String, Object?> scope, String module) {
  if (scope['module'] == module) return scope;
  for (final child
      in (scope['children']! as List).cast<Map<String, Object?>>()) {
    final found = scopeByModule(child, module);
    if (found != null) return found;
  }
  return null;
}
