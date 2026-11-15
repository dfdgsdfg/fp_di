// Internal library. The library file does not export this file.
//
// The DevTools inspector. It reads the state of a runtime and changes nothing.
// The `Scope` factory reaches it only inside an `assert`, so a build without
// assertions never runs it. The inspector touches `dart:developer` only
// through `InspectorHooks`.
//
// The protocol is the protocol of the inspector of `fp_di`: the names of the
// service extensions, the JSON of each answer and event, and the version.
import 'dart:async';

import '../cause.dart';
import '../core/core.dart';
import '../failure.dart';
import '../shape_graph.dart';
import '../slow_mutation.dart';
import 'inspector_hooks.dart';
import 'runtime.dart';

const String _format = 'fp_di.devtools';
const int _version = 1;

/// The most changed nodes that one transition event lists.
const int _changedBound = 500;

/// A query that names an argument wrongly. The handler turns it into an error
/// answer.
final class _ArgumentFailure implements Exception {
  _ArgumentFailure(this.message);

  final String message;
}

/// One live root in the registry. It holds the runtime through a weak
/// reference only.
final class _Root {
  _Root(this.id, Runtime runtime, this.scope)
    : ref = WeakReference<Runtime>(runtime);

  final int id;
  final ScopeId scope;
  final WeakReference<Runtime> ref;
}

/// Wraps the `onSlowMutation` listener of a root, so the inspector can post
/// the report before the listener of the caller runs.
final class InspectorSlowRelay {
  InspectorSlowRelay._(this._listener);

  final SlowMutationListener _listener;

  _Root? _root;

  /// The relay of [listener], or `null` when the root has no listener. A root
  /// without a listener measures nothing, so it posts nothing.
  static InspectorSlowRelay? of(SlowMutationListener? listener) =>
      listener == null ? null : InspectorSlowRelay._(listener);

  /// Posts the report, and then calls the listener of the caller.
  void report(SlowMutation report) {
    try {
      Inspector._slowMutation(_root, report);
    } on Object {
      // The inspector never fails the app.
    }
    _listener(report);
  }
}

/// The inspector of one isolate.
final class Inspector {
  static const List<String> _names = [
    'roots',
    'state',
    'node',
    'shape',
    'listen',
  ];

  /// The inspector of this isolate.
  static Inspector get _instance {
    final held = InspectorHooks.state;
    if (held is Inspector) return held;
    final created = Inspector();
    InspectorHooks.state = created;
    return created;
  }

  /// The live roots by id, in creation order. A root leaves when its disposal
  /// ends or when the collector took it.
  final Map<int, _Root> _roots = <int, _Root>{};

  /// The registry entry of each runtime, so the end of a disposal finds its
  /// entry without a walk of the registry.
  final Expando<_Root> _entries = Expando<_Root>('fp_di_fpdart entries');

  /// The size of the registry at which the creation of a root removes the
  /// entries of collected roots. It doubles after each removal, so the cost of
  /// a creation stays constant on average.
  int _pruneAt = 64;
  int _nextRoot = 1;
  int _nextScope = 1;

  /// The scope ids that a query listed, for each runtime. The key is the
  /// runtime, so the inspector keeps no runtime alive.
  final Expando<Map<ScopeId, int>> _scopeIds = Expando<Map<ScopeId, int>>(
    'fp_di_fpdart scope ids',
  );

  /// The runtime listener of a root while the extension listens, and its
  /// subscription to the errors. The key is the runtime, so the registry holds
  /// no path to a runtime.
  final Expando<void Function()> _listeners = Expando<void Function()>(
    'fp_di_fpdart listeners',
  );
  final Expando<StreamSubscription<Cause<DiFailure>>> _subscriptions =
      Expando<StreamSubscription<Cause<DiFailure>>>('fp_di_fpdart errors');

  /// The state that the last transition event of a root showed.
  final Expando<ScopeState> _posted = Expando<ScopeState>(
    'fp_di_fpdart posted state',
  );

  bool _listening = false;
  bool _values = false;
  final Set<_Root> _dirty = <_Root>{};
  bool _flushScheduled = false;

  // ---- Entry points of the runtime. Each one runs inside an `assert`.

  /// Registers the service extensions once in the isolate, and adds the root
  /// scope [scope] of [runtime] to the registry. [relay] wraps the
  /// slow-mutation listener of the root.
  static void rootCreated(
    Runtime runtime,
    ScopeId scope,
    InspectorSlowRelay? relay,
  ) {
    try {
      final inspector = _instance;
      inspector._register();
      if (inspector._roots.length >= inspector._pruneAt) {
        inspector._prune();
        inspector._pruneAt = inspector._roots.length < 32
            ? 64
            : 2 * inspector._roots.length;
      }
      final entry = _Root(inspector._nextRoot++, runtime, scope);
      relay?._root = entry;
      inspector._roots[entry.id] = entry;
      inspector._entries[runtime] = entry;
      if (inspector._listening) inspector._attach(entry);
    } on Object {
      // The inspector never fails the app.
    }
  }

  /// Removes the root of [runtime] from the registry at the end of its
  /// disposal.
  static void rootDisposed(Runtime runtime) {
    try {
      final inspector = InspectorHooks.state;
      if (inspector is! Inspector) return;
      final entry = inspector._entries[runtime];
      if (entry == null) return;
      inspector._entries[runtime] = null;
      inspector._roots.remove(entry.id);
      inspector._detach(entry, runtime);
    } on Object {
      // The inspector never fails the app.
    }
  }

  /// Registers each service extension that the isolate does not hold yet.
  ///
  /// A name can be registered one time in an isolate, and the isolate can
  /// hold it already: an app that loads `fp_di` as well has the inspector of
  /// `fp_di` under the same names. The registration of such a name throws. The
  /// inspector skips the name and keeps going. The first owner answers the
  /// queries, and this copy answers none of them.
  void _register() {
    if (InspectorHooks.registered) return;
    InspectorHooks.registered = true;
    for (final name in _names) {
      final method = 'ext.fp_di.$name';
      try {
        Zone.root.run(
          () => InspectorHooks.registerExtension(
            method,
            (_, parameters) => _handle(name, parameters),
          ),
        );
        InspectorHooks.owned.add(method);
      } on Object {
        InspectorHooks.skipped.add(method);
      }
    }
  }

  void _prune() {
    _roots.removeWhere((_, entry) => entry.ref.target == null);
  }

  // ---- Queries.

  Future<Map<String, Object?>> _handle(
    String name,
    Map<String, String> parameters,
  ) async {
    try {
      _prune();
      return switch (name) {
        'roots' => _rootsAnswer(),
        'state' => _stateAnswer(parameters),
        'node' => _nodeAnswer(parameters),
        'shape' => _shapeAnswer(parameters),
        'listen' => _listenAnswer(parameters),
        _ => throw _ArgumentFailure('method: unknown name $name'),
      };
    } on _ArgumentFailure catch (error) {
      return _answer({'error': error.message});
    } on Object catch (error) {
      return _answer({'error': 'internal error: ${error.runtimeType}'});
    }
  }

  static Map<String, Object?> _answer(Map<String, Object?> fields) =>
      <String, Object?>{'format': _format, 'version': _version, ...fields};

  static int _intArgument(Map<String, String> parameters, String name) {
    final text = parameters[name];
    if (text == null) {
      throw _ArgumentFailure('$name: the argument is missing');
    }
    final value = int.tryParse(text);
    if (value == null) {
      throw _ArgumentFailure('$name: "${cutText(text).$1}" is no integer');
    }
    return value;
  }

  static bool _boolArgument(
    Map<String, String> parameters,
    String name, {
    required bool optional,
  }) {
    final text = parameters[name];
    if (text == null) {
      if (optional) return false;
      throw _ArgumentFailure('$name: the argument is missing');
    }
    return switch (text) {
      'true' => true,
      'false' => false,
      _ => throw _ArgumentFailure(
        '$name: "${cutText(text).$1}" is neither true nor false',
      ),
    };
  }

  /// Whether the root of [entry] is live: the runtime exists, and the root
  /// scope did not end its disposal.
  static Runtime? _liveRuntime(_Root entry) {
    final runtime = entry.ref.target;
    if (runtime == null || scopeRecord(runtime.state, entry.scope).disposed) {
      return null;
    }
    return runtime;
  }

  Iterable<(_Root, Runtime)> get _liveRoots sync* {
    for (final entry in _roots.values) {
      final runtime = _liveRuntime(entry);
      if (runtime != null) yield (entry, runtime);
    }
  }

  /// The live root with [id]. A root whose disposal ended is unknown.
  (_Root, Runtime) _rootWith(int id) {
    for (final (entry, runtime) in _liveRoots) {
      if (entry.id == id) return (entry, runtime);
    }
    throw _ArgumentFailure('root: unknown id $id');
  }

  Map<String, Object?> _rootsAnswer() => _answer({
    'roots': [
      for (final (entry, runtime) in _liveRoots)
        <String, Object?>{
          'id': entry.id,
          'label': runtime.scopeLabel(entry.scope) ?? 'root ${entry.id}',
          'revision': runtime.state.revision,
        },
    ],
  });

  Map<String, Object?> _stateAnswer(Map<String, String> parameters) {
    final (entry, runtime) = _rootWith(_intArgument(parameters, 'root'));
    final values = _boolArgument(parameters, 'values', optional: true);
    return _answer({'scope': _scopeJson(runtime, entry.scope, values: values)});
  }

  int _scopeId(Runtime runtime, ScopeId scope) {
    final ids = _scopeIds[runtime] ??= <ScopeId, int>{};
    return ids[scope] ??= _nextScope++;
  }

  Map<String, Object?> _scopeJson(
    Runtime runtime,
    ScopeId id, {
    required bool values,
  }) {
    final s = runtime.state;
    final record = scopeRecord(s, id);
    final label = runtime.scopeLabel(id);
    return <String, Object?>{
      'id': _scopeId(runtime, id),
      'phase': scopePhase(s, id).name,
      'module': label,
      'children': [
        for (final child in record.children)
          _scopeJson(runtime, child, values: values),
      ],
      'holds': runtime.holdLabelsOf(id),
      'nodes': [
        for (final n in record.nodes)
          <String, Object?>{
            ...nodeFields(nodeState(s, n)),
            'origin': label,
            if (values) ...valueFields(s, n),
          },
      ],
    };
  }

  NodeId? _nodeWith(Runtime runtime, ScopeId root, int id) {
    final s = runtime.state;
    for (final scope in subtree(s, root)) {
      for (final n in scopeRecord(s, scope).nodes) {
        if (n.value == id) return n;
      }
    }
    return null;
  }

  Map<String, Object?> _nodeAnswer(Map<String, String> parameters) {
    final (entry, runtime) = _rootWith(_intArgument(parameters, 'root'));
    final id = _intArgument(parameters, 'node');
    final values = _boolArgument(parameters, 'values', optional: true);
    final node = _nodeWith(runtime, entry.scope, id);
    if (node == null) throw _ArgumentFailure('node: unknown id $id');
    final s = runtime.state;
    return _answer({
      'reads': nodeReads(s, node),
      'readers': nodeReaders(s, node),
      'failure': failureDetails(s, node),
      'cause': causeSteps(s, node),
      if (values) ...valueFields(s, node),
    });
  }

  Map<String, Object?> _shapeAnswer(Map<String, String> parameters) {
    final id = _intArgument(parameters, 'scope');
    for (final (entry, runtime) in _liveRoots) {
      final ids = _scopeIds[runtime];
      if (ids == null) continue;
      final s = runtime.state;
      for (final MapEntry(key: scope, value: listed) in ids.entries) {
        if (listed != id) continue;
        if (!subtree(s, entry.scope).contains(scope)) continue;
        final chain = <ScopeId>[];
        for (
          var at = scopeRecord(s, scope).parent.toNullable();
          at != null;
          at = scopeRecord(s, at).parent.toNullable()
        ) {
          chain.add(at);
        }
        ShapeModule moduleOf(ScopeId at) => ShapeModule(
          scopeRecord(s, at).components,
          label: runtime.scopeLabel(at),
        );
        final graph = ShapeGraph.ofModule(
          moduleOf(scope),
          ancestors: [for (final at in chain.reversed) moduleOf(at)],
        );
        return _answer({'shape': graph.toJsonObject()});
      }
    }
    throw _ArgumentFailure('scope: unknown id $id');
  }

  Map<String, Object?> _listenAnswer(Map<String, String> parameters) {
    final enabled = _boolArgument(parameters, 'enabled', optional: false);
    final values = _boolArgument(parameters, 'values', optional: true);
    if (enabled) {
      _listening = true;
      _values = values;
      for (final (entry, _) in _liveRoots) {
        _attach(entry);
      }
    } else {
      _listening = false;
      _values = false;
      _dirty.clear();
      for (final entry in _roots.values) {
        _detach(entry, entry.ref.target);
      }
    }
    return _answer({'listening': _listening});
  }

  // ---- Events.

  /// Adds the listener and the error subscription of [entry], and keeps the
  /// state that the next transition event compares with.
  void _attach(_Root entry) {
    final runtime = entry.ref.target;
    if (runtime == null || _listeners[runtime] != null) return;
    if (disposalRequested(runtime.state, entry.scope)) return;
    // The closures come from methods that see the entry and not the runtime,
    // so the runtime does not reach the registry through them.
    final listener = _listenerOf(entry);
    runtime.addListener(entry.scope, listener);
    _listeners[runtime] = listener;
    _posted[runtime] = runtime.scopeStateOf(entry.scope);
    final handler = _errorHandlerOf(entry);
    try {
      // The subscription runs in the root zone, so it does not depend on the
      // zone of the caller.
      _subscriptions[runtime] = Zone.root.run(
        () => runtime.errors.listen(handler),
      );
    } on Object {
      // A closed stream needs no subscription.
    }
  }

  void Function() _listenerOf(_Root entry) =>
      () => _changed(entry);

  void Function(Cause<DiFailure>) _errorHandlerOf(_Root entry) =>
      (cause) => _error(entry, cause);

  void _detach(_Root entry, Runtime? runtime) {
    if (runtime == null) return;
    final listener = _listeners[runtime];
    _listeners[runtime] = null;
    if (listener != null) runtime.removeListener(entry.scope, listener);
    final subscription = _subscriptions[runtime];
    _subscriptions[runtime] = null;
    if (subscription != null) unawaited(subscription.cancel());
  }

  /// A runtime listener. It runs inside a transition, so it only marks the
  /// root and schedules the flush.
  void _changed(_Root entry) {
    if (!_listening) return;
    _dirty.add(entry);
    if (_flushScheduled) return;
    _flushScheduled = true;
    // A timer runs after the microtasks of this turn, so one event holds the
    // transitions of the whole turn, also of an awaited `run`. The root zone
    // always runs its timers; the zone of a test can stop.
    Zone.root.createTimer(Duration.zero, _flush);
  }

  void _flush() {
    _flushScheduled = false;
    final entries = List<_Root>.of(_dirty);
    _dirty.clear();
    if (!_listening) return;
    for (final entry in entries) {
      try {
        _postTransition(entry);
      } on Object {
        // The inspector never fails the app.
      }
    }
  }

  void _postTransition(_Root entry) {
    final runtime = entry.ref.target;
    if (runtime == null) return;
    final earlier = _posted[runtime];
    final state = runtime.scopeStateOf(entry.scope);
    _posted[runtime] = state;
    if (earlier == null) return;
    final pairs = state.changedSince(earlier);
    // A scope can change without a node: its phase, or a new child.
    if (pairs.isEmpty && state == earlier) return;
    final shown = pairs.length > _changedBound
        ? pairs.sublist(0, _changedBound)
        : pairs;
    final s = runtime.state;
    final omitted = pairs.length - shown.length;
    _post('fp_di:transition', {
      'root': entry.id,
      'revision': s.revision,
      'changed': [
        for (final (before, after) in shown)
          <String, Object?>{
            'node': (after ?? before)!.id.value,
            'before': before == null ? null : nodeFields(before),
            'after': after == null
                ? null
                : <String, Object?>{
                    ...nodeFields(after),
                    if (_values && s.nodes.containsKey(after.id))
                      ...valueFields(s, after.id),
                  },
          },
      ],
      'omitted': omitted,
      if (omitted > 0) 'truncated': true,
    });
  }

  void _error(_Root entry, Cause<DiFailure> cause) {
    try {
      if (!_listening) return;
      final failure = cause.failures.firstOrNull;
      final String type;
      final String text;
      if (failure != null) {
        type = '${failure.runtimeType}';
        text = failure.message;
      } else {
        final summary = failureSummary(cause);
        type = summary.type;
        text = summary.message;
      }
      final (message, messageCut) = cutText(text);
      final trace = firstStackTrace(cause).toNullable();
      final (stack, stackCut) = trace == null
          ? (null, false)
          : cutText(trace.toString());
      _post('fp_di:error', {
        'root': entry.id,
        'type': type,
        'message': message,
        'stackTrace': stack,
        if (messageCut || stackCut) 'truncated': true,
      });
    } on Object {
      // The inspector never fails the app.
    }
  }

  /// Posts the report of a slow operation of the root of [entry].
  static void _slowMutation(_Root? entry, SlowMutation report) {
    final inspector = InspectorHooks.state;
    if (entry == null || inspector is! Inspector || !inspector._listening) {
      return;
    }
    var cut = false;
    List<String> labels(List<String> source) {
      final shown = source.length > _changedBound
          ? source.sublist(0, _changedBound)
          : source;
      if (shown.length != source.length) cut = true;
      return [
        for (final label in shown)
          () {
            final (text, labelCut) = cutText(label);
            if (labelCut) cut = true;
            return text;
          }(),
      ];
    }

    final (operation, operationCut) = cutText(report.operation);
    final running = labels(report.running);
    final ignoring = labels(report.ignoringCancellation);
    final disposing = labels(report.disposing);
    inspector._post('fp_di:slowMutation', {
      'root': entry.id,
      'operation': operation,
      'elapsedMs': report.elapsed.inMilliseconds,
      'running': running,
      'ignoringCancellation': ignoring,
      'disposing': disposing,
      'queued': report.queued,
      if (cut || operationCut) 'truncated': true,
    });
  }

  void _post(String kind, Map<String, Object?> fields) {
    try {
      InspectorHooks.postEvent(kind, _answer(fields));
    } on Object {
      // The inspector never fails the app.
    }
  }
}
