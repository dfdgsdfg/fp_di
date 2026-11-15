part of 'scope.dart';

// The DevTools inspector (specs/tooling/devtools). It reads the state of the
// runtime and changes nothing. The `Scope` factory reaches it only inside an
// `assert`, so a build without assertions never runs it. The inspector
// touches `dart:developer` only through `RuntimeInspectorHooks`.

const String _inspectorFormat = 'fp_di.devtools';
const int _inspectorVersion = 1;

/// The longest text that an answer or an event holds, in UTF-16 code units.
const int _inspectorTextBound = 4096;

/// The most changed nodes that one transition event lists.
const int _inspectorChangedBound = 500;

/// The text that stands for a value whose `toString` threw.
const String _inspectorToStringThrew = '<toString threw>';

/// A query that names an argument wrongly. The handler turns it into an
/// error answer.
final class _RuntimeInspectorArgumentError implements Exception {
  _RuntimeInspectorArgumentError(this.message);

  final String message;
}

/// One live root in the registry. It holds the root through a weak
/// reference only.
final class _RuntimeInspectorRoot {
  _RuntimeInspectorRoot(this.id, Scope root) : ref = WeakReference<Scope>(root);

  final int id;
  final WeakReference<Scope> ref;
}

/// Wraps the `onSlowMutation` listener of a root, so the inspector can post
/// the report before the listener of the caller runs.
final class _RuntimeInspectorSlowRelay {
  _RuntimeInspectorSlowRelay(this._listener);

  final SlowMutationListener _listener;

  /// The registry entry of the root, set when the root joins the registry.
  _RuntimeInspectorRoot? root;

  /// The relay of [listener], or null when the root has no listener. A root
  /// without a listener measures nothing, so it posts nothing.
  static _RuntimeInspectorSlowRelay? of(SlowMutationListener? listener) =>
      listener == null ? null : _RuntimeInspectorSlowRelay(listener);

  void report(SlowMutation report) {
    try {
      _RuntimeInspector._slowMutation(root, report);
    } on Object {
      // The inspector never fails the app.
    }
    _listener(report);
  }
}

final class _RuntimeInspector {
  static const List<String> _names = [
    'roots',
    'state',
    'node',
    'shape',
    'listen',
  ];

  /// The inspector of this isolate.
  static _RuntimeInspector get _instance {
    final held = RuntimeInspectorHooks.state;
    if (held is _RuntimeInspector) return held;
    final created = _RuntimeInspector();
    RuntimeInspectorHooks.state = created;
    return created;
  }

  /// The live roots by id, in creation order. A root leaves when its
  /// disposal ends or when the collector took it.
  final Map<int, _RuntimeInspectorRoot> _roots = <int, _RuntimeInspectorRoot>{};

  /// The registry entry of each runtime, so the end of a disposal finds its
  /// entry without a walk of the registry.
  final Expando<_RuntimeInspectorRoot> _entries =
      Expando<_RuntimeInspectorRoot>('fp_di inspector entries');

  /// The size of the registry at which the creation of a root removes the
  /// entries of collected roots. It doubles after each removal, so the cost
  /// of a creation stays constant on average.
  int _pruneAt = 64;
  int _nextRoot = 1;
  int _nextScope = 1;

  /// The scope ids that a query listed. The key is the scope, so the
  /// inspector keeps no scope alive.
  final Expando<int> _scopeIds = Expando<int>('fp_di inspector scope ids');

  /// The runtime listener of a root while the extension listens, and its
  /// subscription to `Scope.errors`. The key is the root, so the registry
  /// holds no path to a root: the root holds both values, not the registry.
  final Expando<void Function()> _listeners = Expando<void Function()>(
    'fp_di inspector listeners',
  );
  final Expando<StreamSubscription<DiException>> _subscriptions =
      Expando<StreamSubscription<DiException>>('fp_di inspector subscriptions');

  /// The state that the last transition event of a root showed.
  final Expando<ScopeState> _posted = Expando<ScopeState>(
    'fp_di inspector posted state',
  );

  bool _listening = false;
  bool _values = false;
  final Set<_RuntimeInspectorRoot> _dirty = <_RuntimeInspectorRoot>{};
  bool _flushScheduled = false;

  // ---- Entry points of the runtime. Each one runs inside an `assert`.

  /// Registers the service extensions once in the isolate, and adds [root] to
  /// the registry. [relay] wraps the slow-mutation listener of [root].
  static void rootCreated(Scope root, _RuntimeInspectorSlowRelay? relay) {
    try {
      final inspector = _instance;
      inspector._register();
      if (inspector._roots.length >= inspector._pruneAt) {
        inspector._prune();
        inspector._pruneAt = inspector._roots.length < 32
            ? 64
            : 2 * inspector._roots.length;
      }
      final entry = _RuntimeInspectorRoot(inspector._nextRoot++, root);
      relay?.root = entry;
      inspector._roots[entry.id] = entry;
      inspector._entries[root._runtime] = entry;
      if (inspector._listening) inspector._attach(entry);
    } on Object {
      // The inspector never fails the app.
    }
  }

  /// Removes the root of [runtime] from the registry at the end of its
  /// disposal.
  static void rootDisposed(_Runtime runtime) {
    try {
      final inspector = RuntimeInspectorHooks.state;
      if (inspector is! _RuntimeInspector) return;
      final entry = inspector._entries[runtime];
      if (entry == null) return;
      inspector._entries[runtime] = null;
      inspector._roots.remove(entry.id);
      inspector._detach(entry);
    } on Object {
      // The inspector never fails the app.
    }
  }

  void _register() {
    if (RuntimeInspectorHooks.registered) return;
    RuntimeInspectorHooks.registered = true;
    for (final name in _names) {
      try {
        Zone.root.run(
          () => RuntimeInspectorHooks.registerExtension(
            'ext.fp_di.$name',
            (method, parameters) => _handle(name, parameters),
          ),
        );
      } on Object {
        // Another copy of the library can hold the name.
      }
    }
  }

  void _prune() {
    _roots.removeWhere((_, entry) {
      if (entry.ref.target != null) return false;
      _detach(entry);
      return true;
    });
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
        _ => throw _RuntimeInspectorArgumentError('method: unknown name $name'),
      };
    } on _RuntimeInspectorArgumentError catch (error) {
      return _answer({'error': error.message});
    } on Object catch (error) {
      return _answer({'error': 'internal error: ${error.runtimeType}'});
    }
  }

  static Map<String, Object?> _answer(Map<String, Object?> fields) =>
      <String, Object?>{
        'format': _inspectorFormat,
        'version': _inspectorVersion,
        ...fields,
      };

  static int _intArgument(Map<String, String> parameters, String name) {
    final text = parameters[name];
    if (text == null) {
      throw _RuntimeInspectorArgumentError('$name: the argument is missing');
    }
    final value = int.tryParse(text);
    if (value == null) {
      throw _RuntimeInspectorArgumentError(
        '$name: "${_cut(text).$1}" is no integer',
      );
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
      throw _RuntimeInspectorArgumentError('$name: the argument is missing');
    }
    return switch (text) {
      'true' => true,
      'false' => false,
      _ => throw _RuntimeInspectorArgumentError(
        '$name: "${_cut(text).$1}" is neither true nor false',
      ),
    };
  }

  /// The live root with [id]. A root whose disposal ended is unknown.
  Scope _rootWith(int id) {
    for (final entry in _roots.values) {
      final root = entry.ref.target;
      if (entry.id == id && root != null && !root._scope.disposed) return root;
    }
    throw _RuntimeInspectorArgumentError('root: unknown id $id');
  }

  Iterable<(_RuntimeInspectorRoot, Scope)> get _liveRoots sync* {
    for (final entry in _roots.values) {
      final root = entry.ref.target;
      if (root != null && !root._scope.disposed) yield (entry, root);
    }
  }

  Map<String, Object?> _rootsAnswer() => _answer({
    'roots': [
      for (final (entry, root) in _liveRoots)
        <String, Object?>{
          'id': entry.id,
          'label': root.module.debugLabel ?? 'root ${entry.id}',
          'revision': root.revision,
        },
    ],
  });

  Map<String, Object?> _stateAnswer(Map<String, String> parameters) {
    final root = _rootWith(_intArgument(parameters, 'root'));
    final values = _boolArgument(parameters, 'values', optional: true);
    return _answer({'scope': _scopeJson(root._scope, values: values)});
  }

  int _scopeId(_RuntimeScope scope) => _scopeIds[scope] ??= _nextScope++;

  Map<String, Object?> _scopeJson(_RuntimeScope scope, {required bool values}) {
    final origins = scope.declared.origins;
    return <String, Object?>{
      'id': _scopeId(scope),
      'phase': scope.phase.name,
      'module': scope.declared.debugLabel,
      'children': [
        for (final child in scope.children) _scopeJson(child, values: values),
      ],
      'holds': [for (final hold in scope.holds) _holdLabel(hold)],
      'nodes': [
        for (var i = 0; i < scope.nodes.length; i++)
          <String, Object?>{
            ..._nodeFields(scope.nodes[i].state),
            'origin': i < origins.length ? origins[i] : null,
            if (values) ..._valueFields(scope.nodes[i]),
          },
      ],
    };
  }

  /// The label of an open hold of a disposal: its `debugLabel`, or `hold`
  /// for a hold without a label.
  static String _holdLabel(_RuntimeHold hold) => hold.debugLabel ?? 'hold';

  /// The fields that a node state shows in an answer and in an event.
  static Map<String, Object?> _nodeFields(NodeState state) => <String, Object?>{
    'id': state.id,
    'label': state.label,
    'key': state.key?.toString(),
    'phase': state.phase.name,
    'missing': [for (final key in state.missing) '$key'],
    'failure': _failureSummary(state.activationException),
    'commits': state.commits,
  };

  static Map<String, Object?>? _failureSummary(ActivationException? failure) {
    if (failure == null) return null;
    final (message, cut) = _text(failure.cause);
    return <String, Object?>{
      'type': '${failure.cause.runtimeType}',
      'message': message,
      if (cut) 'truncated': true,
    };
  }

  /// The `value` of a node, and `truncated` when the text is cut. A node
  /// that is not active has no value.
  static Map<String, Object?> _valueFields(_RuntimeNode node) {
    if (node.removed || node.state.phase != NodePhase.active) {
      return const <String, Object?>{'value': null};
    }
    final (text, cut) = _text(node.value);
    return <String, Object?>{'value': text, if (cut) 'truncated': true};
  }

  /// The text of [value], cut at the bound. A `toString` that throws gives
  /// the placeholder. The flag tells that the text was cut.
  static (String, bool) _text(Object? value) {
    final String text;
    try {
      text = '$value';
    } on Object {
      return (_inspectorToStringThrew, false);
    }
    return _cut(text);
  }

  static (String, bool) _cut(String text) {
    if (text.length <= _inspectorTextBound) return (text, false);
    var end = _inspectorTextBound;
    // Do not split a surrogate pair.
    final last = text.codeUnitAt(end - 1);
    if (last >= 0xD800 && last <= 0xDBFF) end--;
    return (text.substring(0, end), true);
  }

  _RuntimeNode? _nodeWith(Scope root, int id) {
    for (final scope in root._runtime.subtreeOf(root._scope)) {
      for (final node in scope.nodes) {
        if (node.id == id) return node;
      }
    }
    return null;
  }

  Map<String, Object?> _nodeAnswer(Map<String, String> parameters) {
    final root = _rootWith(_intArgument(parameters, 'root'));
    final id = _intArgument(parameters, 'node');
    final values = _boolArgument(parameters, 'values', optional: true);
    final node = _nodeWith(root, id);
    if (node == null) {
      throw _RuntimeInspectorArgumentError('node: unknown id $id');
    }
    final failure = node.state.activationException;
    Map<String, Object?>? failureJson;
    if (failure != null) {
      final (cause, causeCut) = _text(failure.cause);
      final (stack, stackCut) = _text(failure.stackTrace);
      failureJson = <String, Object?>{
        'cause': cause,
        'stackTrace': stack,
        if (causeCut || stackCut) 'truncated': true,
      };
    }
    return _answer({
      'reads': _reads(root._runtime, node),
      'readers': _readers(node),
      'failure': failureJson,
      'cause': _causeSteps(root._runtime, node),
      if (values) ..._valueFields(node),
    });
  }

  /// A read of [key] by [node]. The publisher is the node that gives the
  /// value, or for a key without a value, the nearest node that publishes
  /// [key], which the search of the cause follows.
  static Map<String, Object?> _read(
    _Runtime runtime,
    DiKeyBase key,
    String kind,
    _RuntimeNode node,
  ) {
    final publisher = node.resolve(key);
    return <String, Object?>{
      'key': '$key',
      'kind': kind,
      'resolves': publisher != null,
      'publisher': publisher?.owner.id ?? runtime._nodeBehind(node, key)?.id,
    };
  }

  /// The keys that [node] reads. A collection read has no one publisher, so
  /// its entry has a null `publisher` and lists its `members`.
  static List<Map<String, Object?>> _reads(
    _Runtime runtime,
    _RuntimeNode node,
  ) {
    Map<String, Object?> collection(DiCollectionKey<Object?> key, String kind) {
      final members = [
        for (final member in node.contributionKeysOf(key))
          _read(runtime, member, 'member', node),
      ];
      return <String, Object?>{
        'key': '$key',
        'kind': kind,
        'resolves': members.every((member) => member['resolves'] == true),
        'publisher': null,
        'members': members,
      };
    }

    return [
      for (final key in node.declaredRequires)
        _read(runtime, key, 'require', node),
      for (final key in node.declaredPlainReads)
        if (!node.declaredRequires.contains(key))
          _read(runtime, key, 'optional', node),
      for (final key in node.collectionKeys) collection(key, 'collection'),
      for (final key in node.optionalCollectionKeys)
        collection(key, 'optionalCollection'),
    ];
  }

  /// The ids of the nodes whose committed reads include a value of [node].
  static List<int> _readers(_RuntimeNode node) {
    final ids = <int>{
      for (final publisher in node.publishers)
        for (final dependent in publisher.dependents)
          if (!identical(dependent, node)) dependent.id,
    };
    return ids.toList()..sort();
  }

  /// The search of R-UC-RT-LC-030 as steps, or null when the key of [first]
  /// has a value. It visits the nodes in the order of `_Runtime.unavailable`
  /// and changes nothing.
  static List<Map<String, Object?>>? _causeSteps(
    _Runtime runtime,
    _RuntimeNode first,
  ) {
    if (first.publicKey == null || first.state.phase == NodePhase.active) {
      return null;
    }
    final steps = <Map<String, Object?>>[];
    final seen = <_RuntimeNode>{};
    final pending = <_RuntimeNode>[first];
    while (pending.isNotEmpty) {
      final node = pending.removeLast();
      if (!seen.add(node)) continue;
      final state = node.state;
      steps.add(<String, Object?>{
        'node': node.id,
        'phase': state.phase.name,
        'waitsFor': [for (final key in state.missing) '$key'],
      });
      if (state.phase != NodePhase.waiting) continue;
      final next = <_RuntimeNode>[];
      for (final missing in state.missing) {
        if (missing is DiCollectionKey<Object?>) {
          for (final contribution in node.contributionKeysOf(missing)) {
            if (node.resolve(contribution) != null) continue;
            if (runtime._nodeBehind(node, contribution) case final behind?) {
              next.add(behind);
            }
          }
        } else if (runtime._nodeBehind(node, missing) case final behind?) {
          next.add(behind);
        }
      }
      pending.addAll(next.reversed);
    }
    return steps;
  }

  Map<String, Object?> _shapeAnswer(Map<String, String> parameters) {
    final id = _intArgument(parameters, 'scope');
    for (final (_, root) in _liveRoots) {
      for (final scope in root._runtime.subtreeOf(root._scope)) {
        if (_scopeIds[scope] != id) continue;
        final ancestors = <Module>[];
        for (var s = scope.parent; s != null; s = s.parent) {
          ancestors.add(s.declared);
        }
        final graph = ShapeGraph.of(
          scope.declared,
          ancestorModules: ancestors.reversed.toList(),
        );
        return _answer({'shape': graph.toJsonObject()});
      }
    }
    throw _RuntimeInspectorArgumentError('scope: unknown id $id');
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
        _detach(entry);
      }
    }
    return _answer({'listening': _listening});
  }

  // ---- Events.

  /// Adds the listener and the error subscription of [entry], and keeps the
  /// state that the next transition event compares with.
  void _attach(_RuntimeInspectorRoot entry) {
    final root = entry.ref.target;
    if (root == null || _listeners[root] != null) return;
    if (root._scope.disposalRequested) return;
    // The closures come from methods that see the entry and not the root, so
    // the root does not reach the registry through them.
    final listener = _listenerOf(entry);
    try {
      root.addListener(listener);
    } on Object {
      return;
    }
    _listeners[root] = listener;
    _posted[root] = root.state;
    final handler = _errorHandlerOf(entry);
    try {
      // The subscription runs in the root zone, so it does not depend on the
      // zone of the caller.
      _subscriptions[root] = Zone.root.run(() => root.errors.listen(handler));
    } on Object {
      // A closed stream needs no subscription.
    }
  }

  void Function() _listenerOf(_RuntimeInspectorRoot entry) =>
      () => _changed(entry);

  void Function(DiException) _errorHandlerOf(_RuntimeInspectorRoot entry) =>
      (error) => _error(entry, error);

  void _detach(_RuntimeInspectorRoot entry) {
    final root = entry.ref.target;
    if (root == null) return;
    final listener = _listeners[root];
    _listeners[root] = null;
    if (listener != null) {
      try {
        root.removeListener(listener);
      } on Object {
        // The root is gone for good.
      }
    }
    final subscription = _subscriptions[root];
    _subscriptions[root] = null;
    if (subscription != null) unawaited(subscription.cancel());
  }

  /// A runtime listener. It runs inside a transition, so it only marks the
  /// root and schedules the flush.
  void _changed(_RuntimeInspectorRoot entry) {
    if (!_listening) return;
    _dirty.add(entry);
    if (_flushScheduled) return;
    _flushScheduled = true;
    // A timer runs after the microtasks of this turn, so one event holds the
    // transitions of the whole turn, also of an awaited `initialize`. The
    // root zone always runs its timers; the zone of a test can stop.
    Zone.root.createTimer(Duration.zero, _flush);
  }

  void _flush() {
    _flushScheduled = false;
    final entries = List<_RuntimeInspectorRoot>.of(_dirty);
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

  void _postTransition(_RuntimeInspectorRoot entry) {
    final root = entry.ref.target;
    if (root == null) return;
    final earlier = _posted[root];
    final state = root.state;
    _posted[root] = state;
    if (earlier == null) return;
    final pairs = state.changedSince(earlier);
    // A scope can change without a node: its phase, or a new child.
    if (pairs.isEmpty && state == earlier) return;
    final shown = pairs.length > _inspectorChangedBound
        ? pairs.sublist(0, _inspectorChangedBound)
        : pairs;
    final nodes = <int, _RuntimeNode>{
      if (_values)
        for (final scope in root._runtime.subtreeOf(root._scope))
          for (final node in scope.nodes) node.id: node,
    };
    final omitted = pairs.length - shown.length;
    _post('fp_di:transition', {
      'root': entry.id,
      'revision': root.revision,
      'changed': [
        for (final (before, after) in shown)
          <String, Object?>{
            'node': (after ?? before)!.id,
            'before': before == null ? null : _nodeFields(before),
            'after': after == null
                ? null
                : <String, Object?>{
                    ..._nodeFields(after),
                    if (_values && nodes[after.id] != null)
                      ..._valueFields(nodes[after.id]!),
                  },
          },
      ],
      'omitted': omitted,
      if (omitted > 0) 'truncated': true,
    });
  }

  void _error(_RuntimeInspectorRoot entry, DiException error) {
    try {
      if (!_listening) return;
      final (message, messageCut) = _cut(error.message);
      final stack = switch (error) {
        ActivationException(:final stackTrace) => stackTrace,
        ActivationCanceledException(:final stackTrace) => stackTrace,
        DiListenerException(:final stackTrace) => stackTrace,
        DisposeException(:final disposeFailures) =>
          disposeFailures.isEmpty ? null : disposeFailures.first.stackTrace,
        _ => null,
      };
      final (trace, traceCut) = stack == null
          ? (null, false)
          : _cut(stack.toString());
      _post('fp_di:error', {
        'root': entry.id,
        'type': '${error.runtimeType}',
        'message': message,
        'stackTrace': trace,
        if (messageCut || traceCut) 'truncated': true,
      });
    } on Object {
      // The inspector never fails the app.
    }
  }

  /// Posts the report of a slow mutation of the root of [entry].
  static void _slowMutation(_RuntimeInspectorRoot? entry, SlowMutation report) {
    final inspector = RuntimeInspectorHooks.state;
    if (entry == null ||
        inspector is! _RuntimeInspector ||
        !inspector._listening) {
      return;
    }
    var cut = false;
    List<String> labels(List<String> source) {
      final shown = source.length > _inspectorChangedBound
          ? source.sublist(0, _inspectorChangedBound)
          : source;
      if (shown.length != source.length) cut = true;
      return [
        for (final label in shown)
          () {
            final (text, labelCut) = _cut(label);
            if (labelCut) cut = true;
            return text;
          }(),
      ];
    }

    final (operation, operationCut) = _cut(report.operation);
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
      RuntimeInspectorHooks.postEvent(kind, _answer(fields));
    } on Object {
      // The inspector never fails the app.
    }
  }
}
