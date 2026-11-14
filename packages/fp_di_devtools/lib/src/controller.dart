import 'dart:async';

import 'package:flutter/foundation.dart';

import 'client.dart';
import 'model.dart';

/// What the app shows instead of, or beside, the views.
enum ViewStatus {
  /// No debugged app is connected.
  noConnection,

  /// An app is connected and the first answers are pending.
  connecting,

  /// The app serves another protocol version.
  versionMismatch,

  /// The views show the data.
  ready,
}

/// One line of the timeline.
final class TimelineEntry {
  const TimelineEntry({
    required this.sequence,
    required this.time,
    required this.event,
  });

  final int sequence;
  final DateTime time;
  final InspectorEvent event;
}

/// The state of the extension app: the answers of the inspector, the
/// selection, and the timeline since the app connected.
///
/// The controller only reads. It calls `listen` to start the events and never
/// changes the debugged app.
class InspectorController extends ChangeNotifier {
  InspectorController(this.client);

  /// The most timeline entries that the controller keeps.
  static const int timelineLimit = 1000;

  final InspectorClient client;

  ViewStatus _status = ViewStatus.noConnection;
  int? _foundVersion;
  String? _error;
  List<RootInfo> _roots = const [];
  int? _selectedRoot;
  ScopeInfo? _tree;
  Map<int, ScopeInfo> _scopeOfNode = const {};
  Map<int, NodeInfo> _nodes = const {};
  int? _selectedScope;
  int? _selectedNode;
  NodeDetails? _details;
  final Map<int, ShapeInfo> _shapes = {};
  final List<TimelineEntry> _timeline = [];
  int _sequence = 0;
  bool _showValues = false;
  String? _phaseFilter;
  String _search = '';

  bool _stateLoading = false;
  bool _stateDirty = false;
  bool _disposed = false;
  int _attachGeneration = 0;
  StreamSubscription<RawEvent>? _eventSubscription;
  StreamSubscription<void>? _restartSubscription;

  ViewStatus get status => _status;

  /// The version that the app serves, when [status] is
  /// [ViewStatus.versionMismatch].
  int? get foundVersion => _foundVersion;

  /// The last error answer or failed call, or null.
  String? get error => _error;
  List<RootInfo> get roots => _roots;
  int? get selectedRoot => _selectedRoot;

  /// The scope tree of the selected root.
  ScopeInfo? get tree => _tree;
  int? get selectedScope => _selectedScope;
  int? get selectedNode => _selectedNode;
  NodeDetails? get details => _details;
  List<TimelineEntry> get timeline => List.unmodifiable(_timeline);
  bool get showValues => _showValues;
  String? get phaseFilter => _phaseFilter;
  String get search => _search;

  /// The selected scope, or null.
  ScopeInfo? get scope {
    final id = _selectedScope;
    if (id == null) return null;
    for (final scope in _tree?.subtree ?? const <ScopeInfo>[]) {
      if (scope.id == id) return scope;
    }
    return null;
  }

  /// The shape of the selected scope, or null while it is not loaded.
  ShapeInfo? get shape =>
      _selectedScope == null ? null : _shapes[_selectedScope];

  /// The selected node, or null.
  NodeInfo? get node => _selectedNode == null ? null : _nodes[_selectedNode];

  /// The node [id] of the selected root, or null.
  NodeInfo? nodeWithId(int id) => _nodes[id];

  /// The phases of the nodes of the selected scope.
  List<String> get phasesInScope => {
    for (final node in scope?.nodes ?? const <NodeInfo>[]) node.phase,
  }.toList()..sort();

  /// The nodes of the selected scope that match the phase filter and the
  /// search by key.
  List<NodeInfo> get filteredNodes {
    final query = _search.trim().toLowerCase();
    return [
      for (final node in scope?.nodes ?? const <NodeInfo>[])
        if ((_phaseFilter == null || node.phase == _phaseFilter) &&
            (query.isEmpty ||
                (node.key?.toLowerCase().contains(query) ?? false)))
          node,
    ];
  }

  /// Subscribes to the client and loads the first answers.
  void start() {
    _eventSubscription = client.events.listen(_onEvent);
    _restartSubscription = client.restarts.listen((_) => unawaited(_attach()));
    client.connected.addListener(_onConnectionChange);
    _onConnectionChange();
  }

  @override
  void dispose() {
    _disposed = true;
    client.connected.removeListener(_onConnectionChange);
    unawaited(_eventSubscription?.cancel());
    unawaited(_restartSubscription?.cancel());
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  void _onConnectionChange() {
    if (client.connected.value) {
      unawaited(_attach());
    } else {
      _attachGeneration++;
      _status = ViewStatus.noConnection;
      _error = null;
      notifyListeners();
    }
  }

  // ---- Loading.

  Future<Map<String, Object?>?> _call(
    String name, [
    Map<String, String> args = const {},
  ]) async {
    try {
      final answer = await client.query('ext.fp_di.$name', args);
      return checkAnswer(answer);
    } on ProtocolMismatch catch (mismatch) {
      _mismatch(mismatch.found);
    } on InspectorError catch (failure) {
      _error = failure.message;
      notifyListeners();
    } on Object catch (failure) {
      _error = 'ext.fp_di.$name failed: $failure';
      notifyListeners();
    }
    return null;
  }

  void _mismatch(int? found) {
    _status = ViewStatus.versionMismatch;
    _foundVersion = found;
    notifyListeners();
  }

  /// Calls `roots` and `listen`, then loads the state of the selected root.
  ///
  /// The app calls it after a connection and after a restart.
  Future<void> _attach() async {
    final generation = ++_attachGeneration;
    if (_status != ViewStatus.versionMismatch) {
      _status = ViewStatus.connecting;
    }
    _error = null;
    _selectedRoot = null;
    _tree = null;
    _scopeOfNode = const {};
    _nodes = const {};
    _selectedScope = null;
    _selectedNode = null;
    _details = null;
    _shapes.clear();
    notifyListeners();
    final roots = await _call('roots');
    if (roots == null || generation != _attachGeneration) return;
    _status = ViewStatus.ready;
    _applyRoots(roots);
    await _listen();
    if (generation != _attachGeneration) return;
    await reloadState();
  }

  Future<void> _listen() =>
      _call('listen', {'enabled': 'true', if (_showValues) 'values': 'true'});

  void _applyRoots(Map<String, Object?> answer) {
    final list = answer['roots'];
    _roots = [
      if (list is List)
        for (final root in list)
          RootInfo.fromJson(Map<String, Object?>.from(root! as Map)),
    ];
    if (!_roots.any((root) => root.id == _selectedRoot)) {
      _selectedRoot = _roots.isEmpty ? null : _roots.first.id;
      _tree = null;
      _selectedScope = null;
      _selectedNode = null;
      _details = null;
    }
    notifyListeners();
  }

  /// Reloads the list of roots.
  Future<void> refreshRoots() async {
    final answer = await _call('roots');
    if (answer == null) return;
    _applyRoots(answer);
    await reloadState();
  }

  /// Reloads `state` of the selected root. A call during a load schedules one
  /// more load after it.
  Future<void> reloadState() async {
    if (_stateLoading) {
      _stateDirty = true;
      return;
    }
    _stateLoading = true;
    try {
      do {
        _stateDirty = false;
        await _loadStateOnce();
      } while (_stateDirty && !_disposed);
    } finally {
      _stateLoading = false;
    }
  }

  Future<void> _loadStateOnce() async {
    final root = _selectedRoot;
    if (root == null) return;
    // Each reload starts without the error of the last one.
    if (_error != null) {
      _error = null;
      notifyListeners();
    }
    final answer = await _call('state', {
      'root': '$root',
      if (_showValues) 'values': 'true',
    });
    if (answer == null || root != _selectedRoot) return;
    final tree = ScopeInfo.fromJson(
      Map<String, Object?>.from(answer['scope']! as Map),
    );
    _tree = tree;
    final scopeOfNode = <int, ScopeInfo>{};
    final nodes = <int, NodeInfo>{};
    for (final scope in tree.subtree) {
      for (final node in scope.nodes) {
        scopeOfNode[node.id] = scope;
        nodes[node.id] = node;
      }
    }
    _scopeOfNode = scopeOfNode;
    _nodes = nodes;
    if (scope == null) _selectedScope = tree.id;
    if (!nodes.containsKey(_selectedNode)) {
      _selectedNode = null;
      _details = null;
    }
    if (_phaseFilter != null && !phasesInScope.contains(_phaseFilter)) {
      _phaseFilter = null;
    }
    notifyListeners();
    await Future.wait([_loadShape(), _loadDetails()]);
  }

  Future<void> _loadShape() async {
    final id = _selectedScope;
    if (id == null || _shapes.containsKey(id)) return;
    final answer = await _call('shape', {'scope': '$id'});
    if (answer == null) return;
    final shape = answer['shape'];
    if (shape is! Map) return;
    _shapes[id] = ShapeInfo.fromJson(Map<String, Object?>.from(shape));
    notifyListeners();
  }

  Future<void> _loadDetails() async {
    final root = _selectedRoot;
    final id = _selectedNode;
    if (root == null || id == null) return;
    final answer = await _call('node', {
      'root': '$root',
      'node': '$id',
      if (_showValues) 'values': 'true',
    });
    if (answer == null || root != _selectedRoot || id != _selectedNode) return;
    _details = NodeDetails.fromJson(answer);
    notifyListeners();
  }

  // ---- Selection.

  Future<void> selectRoot(int id) async {
    if (id == _selectedRoot) return;
    _selectedRoot = id;
    _tree = null;
    _selectedScope = null;
    _selectedNode = null;
    _details = null;
    _shapes.clear();
    notifyListeners();
    await reloadState();
  }

  Future<void> selectScope(int id) async {
    if (id == _selectedScope) return;
    _selectedScope = id;
    _selectedNode = null;
    _details = null;
    if (_phaseFilter != null && !phasesInScope.contains(_phaseFilter)) {
      _phaseFilter = null;
    }
    notifyListeners();
    await _loadShape();
  }

  /// Selects the node [id] of the selected root, and its scope.
  Future<void> selectNode(int id) async {
    final owner = _scopeOfNode[id];
    if (owner == null) return;
    final scopeChanged = owner.id != _selectedScope;
    _selectedScope = owner.id;
    _selectedNode = id;
    _details = null;
    if (_phaseFilter != null && !phasesInScope.contains(_phaseFilter)) {
      _phaseFilter = null;
    }
    if (scopeChanged) _search = '';
    notifyListeners();
    await Future.wait([_loadDetails(), if (scopeChanged) _loadShape()]);
  }

  void setPhaseFilter(String? phase) {
    _phaseFilter = phase;
    notifyListeners();
  }

  void setSearch(String text) {
    _search = text;
    notifyListeners();
  }

  /// Turns the display of values on or off. The values leave the app only
  /// while the toggle is on.
  Future<void> setShowValues(bool show) async {
    if (show == _showValues) return;
    _showValues = show;
    notifyListeners();
    await _listen();
    await reloadState();
  }

  // ---- Events.

  void _onEvent(RawEvent raw) {
    final InspectorEvent? event;
    try {
      event = InspectorEvent.parse(raw.kind, raw.data);
    } on ProtocolMismatch catch (mismatch) {
      _mismatch(mismatch.found);
      return;
    } on Object {
      return;
    }
    if (event == null) return;
    _timeline.add(
      TimelineEntry(sequence: _sequence++, time: DateTime.now(), event: event),
    );
    if (_timeline.length > timelineLimit) {
      _timeline.removeRange(0, _timeline.length - timelineLimit);
    }
    final known = _roots.any((root) => root.id == event!.root);
    notifyListeners();
    if (!known) {
      unawaited(refreshRoots());
    } else if (event is TransitionEvent && event.root == _selectedRoot) {
      unawaited(reloadState());
    }
  }
}
