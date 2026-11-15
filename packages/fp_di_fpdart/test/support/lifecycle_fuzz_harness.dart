// Support library of the random lifecycle histories: the graph descriptors,
// the harness that runs a history against a tree of scopes, the checks of the
// invariants, and the behavior that the fuzz test (`lifecycle_fuzz_test.dart`)
// and the defect controls (`lifecycle_fuzz_defect_test.dart`) share.
//
// A graph fixes up to three scopes, the components of each scope, the reads of
// each component, and the steps of each component. Each `create` and `dispose`
// callback has a mode: it waits on a gate that the harness owns, it settles at
// once, or it settles in a microtask. A history is a sequence of commands over
// the tree: create, run, and dispose scopes, dispose one node, open and close
// holds of a disposal, and complete or fail one gate. The terminal phase closes
// the holds, completes the gates, and waits for every call.
//
// Each check has a prefix that a violation carries.
//
// - `StepSerial`: the dispose functions of one component never overlap.
// - `StepOrder`: a component releases its values from the newest to the oldest.
// - `LeaseAccounted`: every value that a `create` made is released once.
// - `CallersAgree`: the calls that join one disposal give one result.
// - `LateCallNoop`: a call after the end of a disposal does nothing.
// - `RuntimeState`: a node that leaves `active` shows `deactivating` to the
//   listeners first.
// - `NestedCall`: a disposal request from inside a running operation is
//   rejected and records nothing.
// - `UnavailableCause`: `get` of a key behind a failed node lists that node.
// - `ReadsCurrent`: `get` answers the value of the nearest active publisher.
// - `NoDisposalWhileHeld`: no scope reaches `disposing` while a hold of its
//   subtree is open, unless a call ignored the holds.
// - `IgnoredHoldsReported`: a call that ignores open holds reports them once.
// - `HeldCallersComplete`: every call of `dispose` completes.
// - `NoSetupAfterRequest`: no `create` starts after the disposal of its scope
//   was requested.
import 'dart:async';
import 'dart:math';

import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';
import 'package:kiri_check/kiri_check.dart' show boolean, integer;
import 'package:kiri_check/stateful_test.dart';

// ---------------------------------------------------------------------------
// Graph descriptor
// ---------------------------------------------------------------------------

/// How a `create` or `dispose` callback settles.
enum Mode {
  /// Registers a gate and waits. A `Resolve` completes or fails the gate.
  gate,

  /// Returns at once.
  synchronous,

  /// Returns a future that completes in a microtask.
  microtask,
}

/// One step of a component: a `create` with its `dispose`.
final class StepDesc {
  const StepDesc(
    this.create,
    this.dispose, {
    this.failCreate = false,
    this.failDispose = false,
  });

  final Mode create;
  final Mode dispose;

  /// The first call of the `create` throws. Not a gate.
  final bool failCreate;

  /// Every call of the `dispose` throws. Not a gate.
  final bool failDispose;
}

/// A component: the key that it publishes, the components that it reads, and
/// its steps.
final class NodeDesc {
  const NodeDesc(
    this.scope,
    this.index,
    this.keyName,
    this.reads,
    this.steps, {
    this.nested = false,
  });

  final int scope;
  final int index;

  /// The name of the key. A component of a child can reuse the name of a
  /// component of an ancestor, so it shadows it.
  final String keyName;

  /// The `(scope, index)` of each component that this component reads.
  final List<(int, int)> reads;
  final List<StepDesc> steps;

  /// The first `create` calls `dispose` of its scope, from inside the run.
  final bool nested;

  DiKey<int> get key => DiKey<int>(name: keyName);

  String get id => 's${scope}n$index';
}

/// A scope of the tree.
final class ScopeDesc {
  const ScopeDesc(this.parent, this.nodes);

  /// The index of the parent scope, or -1 for the root.
  final int parent;
  final List<NodeDesc> nodes;
}

/// The descriptor of one graph.
final class GraphDesc {
  const GraphDesc(this.seed, this.index, this.scopes);

  final int seed;
  final int index;
  final List<ScopeDesc> scopes;

  int get propertySeed => (seed * 1000003 + index * 7919 + 1) & 0x3fffffff;

  String scopeName(int s) => s == 0 ? 'root' : 'scope $s';

  /// The chain of scope indexes from [s] to the root.
  List<int> chain(int s) => [
    for (var at = s; at >= 0; at = scopes[at].parent) at,
  ];

  /// Whether [s] is [ancestor] or one of its descendants.
  bool inSubtree(int s, int ancestor) => chain(s).contains(ancestor);

  String describe() {
    final out = StringBuffer('graph $index:');
    for (var s = 0; s < scopes.length; s++) {
      out.writeln();
      out.write('  ${scopeName(s)} (parent ${scopes[s].parent})');
      for (final n in scopes[s].nodes) {
        out.write(
          '\n    ${n.id} ${n.keyName} reads '
          '${n.reads.map((r) => 's${r.$1}n${r.$2}').toList()} '
          'steps ${n.steps.length}',
        );
      }
    }
    return out.toString();
  }
}

/// The graph with the number [index] of the run with [seed].
GraphDesc buildGraph(int seed, int index) {
  final random = Random((seed * 31 + index * 17 + 3) & 0x3fffffff);
  Mode mode() => Mode.values[random.nextInt(3)];
  final scopeCount = 2 + random.nextInt(2);
  final scopes = <ScopeDesc>[];
  for (var s = 0; s < scopeCount; s++) {
    final parent = s == 0 ? -1 : (s == 1 ? 0 : random.nextInt(s));
    final count = 2 + random.nextInt(3);
    final nodes = <NodeDesc>[];
    final chain = [for (var at = parent; at >= 0; at = scopes[at].parent) at];
    for (var j = 0; j < count; j++) {
      final reads = <(int, int)>[];
      final candidates = <(int, int)>[
        for (var i = 0; i < j; i++) (s, i),
        for (final a in chain)
          for (var i = 0; i < scopes[a].nodes.length; i++) (a, i),
      ];
      final readCount = candidates.isEmpty ? 0 : random.nextInt(3);
      for (var r = 0; r < readCount; r++) {
        final pick = candidates[random.nextInt(candidates.length)];
        if (!reads.contains(pick)) reads.add(pick);
      }
      // A component of a child that reuses the key of an ancestor shadows it.
      final shadowed = <String>[
        for (final a in chain)
          for (final n in scopes[a].nodes) n.keyName,
      ];
      final shadows = shadowed.isNotEmpty && random.nextInt(4) == 0;
      final keyName = shadows
          ? shadowed[random.nextInt(shadowed.length)]
          : 'k${s}_$j';
      // A component must not read its own key through a shadow.
      reads.removeWhere(
        (r) =>
            (r.$1 == s || chain.contains(r.$1)) &&
            _nameOf(scopes, nodes, s, r) == keyName,
      );
      // A graph of even index has, in each child, a component that reads an
      // ancestor and fails its first create, and a component behind it. A
      // run of the child before its parent then leaves a key behind a failed
      // node.
      final behind = index.isEven && s >= 1 && chain.isNotEmpty && j < 2;
      if (behind) {
        reads
          ..clear()
          ..add(
            j == 0
                ? (chain.first, scopes[chain.first].nodes.length - 1)
                : (s, 0),
          );
      }
      final stepCount = 1 + random.nextInt(3);
      final steps = <StepDesc>[
        for (var k = 0; k < stepCount; k++)
          () {
            final create = mode();
            final dispose = mode();
            return StepDesc(
              behind && j == 0 && k == 0 ? Mode.synchronous : create,
              dispose,
              failCreate:
                  (behind && j == 0 && k == 0) ||
                  (create != Mode.gate && random.nextInt(7) == 0),
              failDispose: dispose != Mode.gate && random.nextInt(5) == 0,
            );
          }(),
      ];
      nodes.add(
        NodeDesc(s, j, keyName, reads, steps, nested: random.nextInt(14) == 0),
      );
    }
    scopes.add(ScopeDesc(parent, nodes));
  }
  return GraphDesc(seed, index, scopes);
}

String _nameOf(
  List<ScopeDesc> scopes,
  List<NodeDesc> own,
  int ownScope,
  (int, int) read,
) => read.$1 == ownScope
    ? own[read.$2].keyName
    : scopes[read.$1].nodes[read.$2].keyName;

// ---------------------------------------------------------------------------
// Violations and statistics
// ---------------------------------------------------------------------------

/// A broken invariant, with the evidence.
final class HistoryViolation implements Exception {
  HistoryViolation(this.report);

  final String report;

  @override
  String toString() => report;
}

/// The events that a run reached, to show that it checks something.
final class FuzzStats {
  static int cycles = 0;
  static int initialized = 0;
  static int creates = 0;
  static int teardowns = 0;
  static int transitions = 0;
  static int joins = 0;
  static int lateCalls = 0;
  static int createFailures = 0;
  static int disposeFailures = 0;
  static int holdsOpened = 0;
  static int ignoringWithHolds = 0;
  static int nestedCalls = 0;
  static int shadowReads = 0;
  static int failedBehind = 0;

  static String summary() =>
      'cycles=$cycles initialized=$initialized creates=$creates '
      'teardowns=$teardowns transitions=$transitions joins=$joins '
      'lateCalls=$lateCalls createFailures=$createFailures '
      'disposeFailures=$disposeFailures holds=$holdsOpened '
      'ignoringWithHolds=$ignoringWithHolds nested=$nestedCalls '
      'shadowReads=$shadowReads failedBehind=$failedBehind';

  /// The events that a run of many cycles must reach.
  static List<String> missingFloors() => [
    if (joins == 0) 'joining dispose call',
    if (lateCalls == 0) 'late dispose call',
    if (createFailures == 0) 'failed create',
    if (disposeFailures == 0) 'failed dispose',
    if (holdsOpened == 0) 'opened hold',
    if (ignoringWithHolds == 0) 'dispose call that ignores open holds',
    if (nestedCalls == 0) 'nested dispose call',
    if (shadowReads == 0) 'read of a shadowed key',
    if (failedBehind == 0) 'key behind a failed node',
  ];
}

// ---------------------------------------------------------------------------
// The harness
// ---------------------------------------------------------------------------

/// A pending gate of a callback.
final class _Gate {
  _Gate(this.kind, this.node, this.step);

  final String kind;
  final NodeDesc node;
  final int step;
  final completer = Completer<void>();
}

/// One call of `dispose`.
final class _Call {
  _Call(this.scope, this.future, {required this.afterEnd}) {
    future.then<void>(
      (exit) {
        done = true;
        result = exit.isLeft() ? 'left' : 'right';
      },
      onError: (Object error) {
        done = true;
        result = 'error';
      },
    );
  }

  final int scope;
  final Future<Exit<DiFailure, Unit>> future;

  /// Whether the first call of the scope had ended when this call started.
  final bool afterEnd;
  bool done = false;
  String? result;
}

/// The system under test: a tree of scopes, the gates, and the records that
/// the checks read.
final class Harness {
  Harness(this.graph) {
    for (final node in [for (final s in graph.scopes) ...s.nodes]) {
      _liveStack[node.id] = [];
      _releasing[node.id] = 0;
    }
  }

  final GraphDesc graph;
  final scopes = <int, Scope>{};
  final gates = <_Gate>[];
  final calls = <_Call>[];
  final operations = <Future<Object?>>[];
  final errors = <Cause<DiFailure>>[];
  StreamSubscription<Cause<DiFailure>>? _errorSubscription;

  // Records of the callbacks.
  var _nextUid = 0;
  final _uidNode = <int, NodeDesc>{};
  final _created = <int>[];
  final _disposedCount = <int, int>{};
  final _liveStack = <String, List<int>>{};
  final _releasing = <String, int>{};
  final _invocations = <String, int>{};
  var _callbacks = 0;

  // The model that the checks use.
  final requested = <int, bool>{};
  final ignoredChain = <int, bool>{};
  final _holds = <int, List<DisposeHold>>{};
  final _holdOrder = <(int, DisposeHold)>[];
  var expectedIgnoredReports = 0;

  /// The holds that a disposal call without `ignoreHolds` waits for.
  final guarded = <int, List<DisposeHold>>{};

  Scope get root => scopes[0]!;

  /// The first violation of the history, or `null`. A callback of the runtime
  /// catches what it throws, so a check inside a callback records its
  /// violation here, and the next command or the terminal phase throws it.
  HistoryViolation? _violated;

  void _violation(String prefix, String message) {
    _violated ??= HistoryViolation('$prefix: $message\n${graph.describe()}');
  }

  void _throwIfViolated() {
    final violation = _violated;
    if (violation != null) throw violation;
  }

  // ---- The components.

  List<Component<Object?>> _componentsOf(int s) => [
    for (final node in graph.scopes[s].nodes) _component(node),
  ];

  Component<int> _component(NodeDesc node) {
    Dependency<int> dependency = node.reads.isEmpty
        ? Dependency<int>.of(0)
        : node.reads
              .map((r) {
                final read = graph.scopes[r.$1].nodes[r.$2];
                return Dependency.require<int>(key: read.key);
              })
              .reduce((l, r) => (l, r).zip.map((v) => v.$1 + v.$2));
    for (var k = 0; k < node.steps.length; k++) {
      final step = k;
      dependency = dependency.mapTask<int>(
        (_) => Task(() => _create(node, step)),
        dispose: (uid) => _dispose(node, step, uid),
      );
    }
    return Component<int>(
      key: node.key,
      debugLabel: node.id,
      dependency: dependency,
    );
  }

  Future<void> _settle(Mode mode, String kind, NodeDesc node, int step) async {
    switch (mode) {
      case Mode.synchronous:
        return;
      case Mode.microtask:
        await Future<void>.value();
      case Mode.gate:
        final gate = _Gate(kind, node, step);
        gates.add(gate);
        await gate.completer.future;
    }
  }

  Future<int> _create(NodeDesc node, int step) async {
    _callbacks++;
    FuzzStats.creates++;
    final scope = node.scope;
    if (_requestedAt(scope)) {
      _violation(
        'NoSetupAfterRequest',
        '${node.id} step $step starts after the disposal of '
            '${graph.scopeName(scope)} or an ancestor was requested',
      );
    }
    final spec = node.steps[step];
    final key = 'create:${node.id}:$step';
    final calls = _invocations[key] = (_invocations[key] ?? 0) + 1;
    if (node.nested && step == 0 && calls == 1) await _nested(scope);
    await _settle(spec.create, 'create', node, step);
    if (spec.failCreate && calls == 1) {
      FuzzStats.createFailures++;
      throw StateError('create ${node.id} $step');
    }
    final uid = _nextUid++;
    _uidNode[uid] = node;
    _created.add(uid);
    _liveStack[node.id]!.add(uid);
    return uid;
  }

  /// A call of `dispose` from inside the run: it is rejected, and it records
  /// nothing.
  Future<void> _nested(int s) async {
    final scope = scopes[s];
    if (scope == null) return;
    FuzzStats.nestedCalls++;
    final before = scope.isDisposed;
    final exit = await scope.dispose();
    if (!before && scope.isDisposed) {
      _violation(
        'NestedCall',
        'a dispose call from inside a running operation of '
            '${graph.scopeName(s)} recorded the disposal request '
            '(${exit.isLeft() ? 'rejected' : 'accepted'})',
      );
    }
  }

  Future<void> _dispose(NodeDesc node, int step, int uid) async {
    _callbacks++;
    final id = node.id;
    final count = _releasing[id] = _releasing[id]! + 1;
    if (count > 1) {
      _violation('StepSerial', 'two dispose functions of $id run together');
    }
    try {
      final live = _liveStack[id]!;
      if (live.isEmpty || live.last != uid) {
        _violation(
          'StepOrder',
          '$id releases value $uid while the newest value is '
              '${live.isEmpty ? 'none' : live.last}',
        );
      }
      live.removeLast();
      final times = _disposedCount[uid] = (_disposedCount[uid] ?? 0) + 1;
      if (times > 1) {
        _violation('LeaseAccounted', '$id releases value $uid $times times');
      }
      final spec = node.steps[step];
      await _settle(spec.dispose, 'dispose', node, step);
      if (spec.failDispose) {
        FuzzStats.disposeFailures++;
        throw StateError('dispose $id $step');
      }
    } finally {
      _releasing[id] = _releasing[id]! - 1;
    }
  }

  // ---- The model.

  /// Whether the disposal of [s] or of an ancestor was requested.
  bool _requestedAt(int s) => graph.chain(s).any((a) => requested[a] == true);

  // ---- The commands.

  void createChild(int s) {
    final parent = graph.scopes[s].parent;
    scopes[s] = rightOrThrow(
      scopes[parent]!.child(
        components: _componentsOf(s),
        debugLabel: graph.scopeName(s),
      ),
    );
    _attachObserver(s);
  }

  Scope rightOrThrow(Either<DiFailure, Scope> either) =>
      either.getOrElse((failure) => throw StateError('$failure'));

  void createRoot() {
    scopes[0] = Scope(
      components: _componentsOf(0),
      debugLabel: graph.scopeName(0),
    );
    _errorSubscription = scopes[0]!.errors.listen(errors.add);
    _attachObserver(0);
  }

  /// A listener that follows the phases of the nodes of one scope.
  void _attachObserver(int s) {
    if (s != 0) return;
    var last = scopes[0]!.state;
    scopes[0]!.addListener(() {
      FuzzStats.transitions++;
      final now = scopes[0]!.state;
      for (final (before, after) in now.changedSince(last)) {
        if (before == null || after == null) continue;
        if (before.phase == NodePhase.active &&
            after.phase != NodePhase.active &&
            after.phase != NodePhase.deactivating) {
          _violation(
            'RuntimeState',
            'the listener saw ${after.label} leave active for '
                '${after.phase.name} without deactivating',
          );
        }
      }
      last = now;
    });
  }

  void runScope(int s) {
    final scope = scopes[s]!;
    operations.add(
      scope.run().then<Object?>((exit) {
        if (exit.isRight()) FuzzStats.initialized++;
        return exit;
      }),
    );
  }

  void runBeforeParent(int s) {
    final parent = graph.scopes[s].parent;
    if (scopes[s] == null) createChild(s);
    runScope(s);
    assert(scopes[parent] != null);
  }

  void startDispose(int s, {required bool ignoreHolds}) {
    final scope = scopes[s]!;
    final first = !_requestedAt(s);
    if (ignoreHolds) {
      // The disposal of the nearest scope that was requested, or of this
      // scope, ends its wait, and so for the whole subtree of that scope.
      final owner = graph
          .chain(s)
          .firstWhere((a) => requested[a] == true, orElse: () => s);
      final already = graph.chain(owner).any((a) => ignoredChain[a] == true);
      if (_heldIn(owner) > 0 && !already) {
        expectedIgnoredReports++;
        FuzzStats.ignoringWithHolds++;
      }
      for (var d = 0; d < graph.scopes.length; d++) {
        if (graph.inSubtree(d, owner)) ignoredChain[d] = true;
      }
    }
    if (first && !ignoreHolds) {
      // These holds delay the disposal of the scope until they close.
      guarded[s] = [
        for (var d = 0; d < graph.scopes.length; d++)
          if (graph.inSubtree(d, s) &&
              scopes[d]?.state.phase != ScopePhase.disposed)
            ...?_holds[d],
      ];
    }
    requested[s] = true;
    _record(s, scope.dispose(ignoreHolds: ignoreHolds), first: first);
  }

  void disposeAgain(int s) {
    _record(s, scopes[s]!.dispose(), first: false);
  }

  void _record(
    int s,
    Future<Exit<DiFailure, Unit>> future, {
    required bool first,
  }) {
    final earlier = calls.where((c) => c.scope == s).toList();
    final afterEnd = earlier.isNotEmpty && earlier.first.done;
    if (afterEnd) FuzzStats.lateCalls++;
    final before = _callbacks;
    final call = _Call(s, future, afterEnd: afterEnd);
    calls.add(call);
    if (!first && !afterEnd && earlier.isNotEmpty) FuzzStats.joins++;
    if (afterEnd) {
      // A call after the end of the disposal does nothing.
      operations.add(
        future.then<Object?>((exit) {
          if (exit.isLeft() || _callbacks != before) {
            _violation(
              'LateCallNoop',
              'a dispose call after the end of ${graph.scopeName(s)} '
                  'gave ${exit.isLeft() ? 'a failure' : 'a result'} and '
                  '${_callbacks - before} callbacks',
            );
          }
          return exit;
        }),
      );
    }
  }

  void disposeNode(int s, int index) {
    final scope = scopes[s];
    if (scope == null || scope.nodes.isEmpty) return;
    final node = scope.nodes[index % scope.nodes.length];
    operations.add(node.dispose());
  }

  void resolve(int pick, bool fail) {
    if (gates.isEmpty) return;
    final gate = gates.removeAt(pick % gates.length);
    if (fail && gate.kind == 'create') {
      FuzzStats.createFailures++;
      gate.completer.completeError(StateError('gate ${gate.node.id}'));
    } else if (fail) {
      FuzzStats.disposeFailures++;
      gate.completer.completeError(StateError('gate ${gate.node.id}'));
    } else {
      gate.completer.complete();
    }
  }

  void openHold(int s) {
    final hold = scopes[s]!.disposeHold(debugLabel: 'hold$s');
    hold.match((_) {}, (value) {
      (_holds[s] ??= []).add(value);
      _holdOrder.add((s, value));
      FuzzStats.holdsOpened++;
    });
  }

  void closeHold(int pick) {
    final open = [
      for (final (s, hold) in _holdOrder)
        if (_holds[s]!.contains(hold)) (s, hold),
    ];
    if (open.isEmpty) return;
    final (s, hold) = open[pick % open.length];
    hold.close();
    _holds[s]!.remove(hold);
  }

  /// The open holds in the subtree of [s]. The holds of a scope whose disposal
  /// ended do not count: the scope left the tree.
  int _heldIn(int s) {
    var total = 0;
    for (var d = 0; d < graph.scopes.length; d++) {
      if (!graph.inSubtree(d, s)) continue;
      final scope = scopes[d];
      if (scope != null && scope.state.phase == ScopePhase.disposed) continue;
      total += _holds[d]?.length ?? 0;
    }
    return total;
  }

  Future<void> pump([int turns = 6]) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  // ---- The checks after each command.

  Future<void> check() async {
    await pump(2);
    _checkHolds();
    _checkReads();
    _checkUnavailable();
    _throwIfViolated();
  }

  void _checkHolds() {
    for (final MapEntry(key: s, value: waits) in guarded.entries) {
      final scope = scopes[s];
      if (scope == null) continue;
      final phase = scope.state.phase;
      if (phase != ScopePhase.disposing && phase != ScopePhase.disposed) {
        continue;
      }
      final ignored = graph.chain(s).any((a) => ignoredChain[a] == true);
      // A hold of a scope whose disposal a call with `ignoreHolds` ended no
      // longer counts: the scope left the tree.
      final open = [
        for (final hold in waits)
          for (final entry in _holds.entries)
            if (entry.value.contains(hold) &&
                !(ignoredChain[entry.key] == true &&
                    scopes[entry.key]?.state.phase == ScopePhase.disposed))
              hold,
      ];
      if (!ignored && open.isNotEmpty) {
        _violation(
          'NoDisposalWhileHeld',
          '${graph.scopeName(s)} is ${phase.name} while ${open.length} holds '
              'of its subtree are open',
        );
      }
    }
  }

  /// `get` answers the value of the nearest active publisher.
  void _checkReads() {
    final names = {
      for (final scope in graph.scopes)
        for (final node in scope.nodes) node.keyName: node.key,
    };
    for (var s = 0; s < graph.scopes.length; s++) {
      final scope = scopes[s];
      if (scope == null || scope.state.phase == ScopePhase.disposed) continue;
      if (scope.state.phase == ScopePhase.disposing) continue;
      for (final key in names.values) {
        int? expected;
        var depth = 0;
        // A scope that runs, or that left its run by a disposal request,
        // lists no node, but a node that committed already publishes its key,
        // so the check has no expectation then.
        var unknown = false;
        for (final a in graph.chain(s)) {
          final holder = scopes[a];
          if (holder == null) {
            depth++;
            continue;
          }
          if (!holder.isInitialized &&
              holder.state.phase != ScopePhase.declared) {
            unknown = true;
            break;
          }
          final nodes = graph.scopes[a].nodes;
          final index = nodes.indexWhere((n) => n.keyName == key.name);
          if (index >= 0 && holder.nodes.length > index) {
            final value = holder.nodes[index].value;
            if (holder.nodes[index].isActive) {
              expected = value.getOrElse((_) => -1) as int;
              if (depth > 0) FuzzStats.shadowReads++;
              break;
            }
          }
          depth++;
        }
        final found = scope.get<int>(key: key);
        if (!unknown && expected != null) {
          final got = found.getOrElse((_) => -2);
          if (got != expected) {
            _violation(
              'ReadsCurrent',
              'get ${key.name} from ${graph.scopeName(s)} gave $got, '
                  'the nearest active publisher has $expected',
            );
          }
        }
      }
    }
  }

  /// `get` of a key behind a failed node lists that node.
  void _checkUnavailable() {
    for (var s = 0; s < graph.scopes.length; s++) {
      final scope = scopes[s];
      if (scope == null || scope.state.phase != ScopePhase.initialized) {
        continue;
      }
      for (final node in scope.nodes) {
        final state = node.state;
        if (state.phase != NodePhase.waiting || state.key.isNone()) continue;
        for (final missing in state.missing) {
          if (missing is! DiKey<int>) continue;
          final behind = scope.findNode<Object?>(key: missing);
          if (behind.isNone()) continue;
          final failed = behind.toNullable()!.state;
          if (failed.phase != NodePhase.activationFailed) continue;
          final got = scope.get<Object?>(key: state.key.toNullable());
          // A key that a nearer scope shadows can have a value of an ancestor.
          if (got.isRight()) continue;
          FuzzStats.failedBehind++;
          final ids = got.match(
            (failure) => failure is UnavailableKeyFailure
                ? [for (final f in failure.failedNodeStates) f.id]
                : <NodeId>[],
            (_) => <NodeId>[],
          );
          if (!ids.contains(failed.id)) {
            _violation(
              'UnavailableCause',
              'get of ${state.label} does not list the failed node '
                  '${failed.label}',
            );
          }
        }
      }
    }
  }

  // ---- The terminal phase.

  /// Closes the holds, completes the gates, waits for every call, and checks
  /// the accounts.
  Future<void> terminal() async {
    for (final (s, hold) in _holdOrder) {
      if (_holds[s]?.contains(hold) ?? false) {
        hold.close();
        _holds[s]!.remove(hold);
      }
    }
    await _quiesce();
    if (scopes[0] != null && !_requestedAt(0)) {
      requested[0] = true;
      _record(0, scopes[0]!.dispose(), first: true);
    }
    await _quiesce();
    for (final call in calls) {
      if (!call.done) {
        _violation(
          'HeldCallersComplete',
          'a dispose call of ${graph.scopeName(call.scope)} did not complete',
        );
      }
    }
    await Future.wait(
      operations.map((f) => f.then<void>((_) {}, onError: (Object _) {})),
    ).timeout(const Duration(seconds: 5));
    FuzzStats.teardowns++;
    for (final uid in _created) {
      final times = _disposedCount[uid] ?? 0;
      if (times != 1) {
        _violation(
          'LeaseAccounted',
          'value $uid of ${_uidNode[uid]!.id} was released $times times',
        );
      }
    }
    final reports = errors
        .where((c) => c.failures.any((f) => f is IgnoredHoldsFailure))
        .length;
    if (reports != expectedIgnoredReports) {
      _violation(
        'IgnoredHoldsReported',
        'the harness expected $expectedIgnoredReports reports and got '
            '$reports',
      );
    }
    _checkNoSetupLeak();
    _checkCallers();
    _throwIfViolated();
  }

  /// The calls that join one disposal give one result.
  void _checkCallers() {
    for (var s = 0; s < graph.scopes.length; s++) {
      final own = calls.where((c) => c.scope == s).toList();
      if (own.length < 2) continue;
      final first = own.first;
      for (final other in own.skip(1)) {
        if (other.afterEnd) continue;
        if (other.result != first.result) {
          _violation(
            'CallersAgree',
            'two calls of ${graph.scopeName(s)} that joined one disposal '
                'gave ${first.result} and ${other.result}',
          );
        }
      }
    }
  }

  void _checkNoSetupLeak() {
    for (final stack in _liveStack.values) {
      if (stack.isNotEmpty) {
        _violation('LeaseAccounted', 'values $stack are still live');
      }
    }
  }

  /// Completes every gate, and lets the runtime settle, until nothing moves.
  Future<void> _quiesce() async {
    for (var round = 0; round < 400; round++) {
      await pump(8);
      if (gates.isEmpty) {
        final pending = calls.where((c) => !c.done).toList();
        if (pending.isEmpty) return;
        await pump(20);
        if (gates.isEmpty) return;
      }
      while (gates.isNotEmpty) {
        gates.removeAt(0).completer.complete();
      }
    }
  }

  /// A fixed history: every scope exists, the children run before their
  /// parents, the gates complete one at a time with a check after each, and the
  /// terminal phase ends it. It reaches the events that a random history
  /// reaches rarely: a key behind a failed node, and a nested call.
  Future<void> fixedHistory() async {
    for (var s = 1; s < graph.scopes.length; s++) {
      createChild(s);
    }
    for (var s = graph.scopes.length - 1; s >= 0; s--) {
      runScope(s);
      await check();
    }
    for (var i = 0; i < 40; i++) {
      resolve(0, false);
      await check();
      // A run that failed rolled back. A new run tries again, and a create
      // that fails only at its first call then succeeds.
      if (i % 10 == 9) {
        for (final scope in scopes.entries) {
          if (!scope.value.isInitialized && !scope.value.isDisposed) {
            runScope(scope.key);
          }
        }
      }
    }
    await terminal();
  }

  Future<void> close() async {
    for (final scope in scopes.values) {
      unawaited(
        scope
            .dispose(ignoreHolds: true)
            .catchError(
              (Object _) => const Right<Cause<DiFailure>, Unit>(unit),
            ),
      );
    }
    while (gates.isNotEmpty) {
      gates.removeAt(0).completer.complete();
    }
    await pump(10);
    await _errorSubscription?.cancel();
  }
}

// ---------------------------------------------------------------------------
// The model and the behavior
// ---------------------------------------------------------------------------

/// The model of a history: which scopes exist, ran, and have a disposal
/// request, and how many holds are open.
final class FuzzModel {
  FuzzModel(this.graph)
    : exists = [for (var s = 0; s < graph.scopes.length; s++) s == 0],
      ran = List<bool>.filled(graph.scopes.length, false),
      requested = List<bool>.filled(graph.scopes.length, false),
      openOrder = [];

  final GraphDesc graph;
  final List<bool> exists;
  final List<bool> ran;
  final List<bool> requested;

  /// Whether the terminal phase ran. No command follows it.
  bool ended = false;

  /// The scope of each open hold, in the order of opening.
  final List<int> openOrder;

  int holdsOf(int s) => openOrder.where((a) => a == s).length;

  bool isRequested(int s) => graph.chain(s).any((a) => requested[a]);

  int heldIn(int s) {
    var total = 0;
    for (var d = 0; d < graph.scopes.length; d++) {
      if (graph.inSubtree(d, s)) total += holdsOf(d);
    }
    return total;
  }
}

final class FuzzBehavior extends Behavior<FuzzModel, Harness> {
  FuzzBehavior(this.graph);

  final GraphDesc graph;

  @override
  FuzzModel initialState() => FuzzModel(graph);

  @override
  Harness createSystem(FuzzModel state) {
    FuzzStats.cycles++;
    return Harness(state.graph)..createRoot();
  }

  @override
  Future<void> destroySystem(Harness system) => system.close();

  @override
  List<Command<FuzzModel, Harness>> generateCommands(FuzzModel state) {
    final commands = <Command<FuzzModel, Harness>>[];
    Command<FuzzModel, Harness> action(
      String name, {
      required bool Function(FuzzModel) precondition,
      required void Function(FuzzModel) nextState,
      required FutureOr<void> Function(Harness) run,
    }) => Action0<FuzzModel, Harness, void>(
      name,
      precondition: (m) => !m.ended && precondition(m),
      nextState: nextState,
      run: (h) async {
        await run(h);
        await h.check();
      },
    );

    for (var s = 0; s < graph.scopes.length; s++) {
      final name = graph.scopeName(s);
      if (s > 0) {
        final parent = graph.scopes[s].parent;
        final create = action(
          'CreateChild($name)',
          precondition: (m) =>
              !m.exists[s] && m.exists[parent] && !m.isRequested(parent),
          nextState: (m) => m.exists[s] = true,
          run: (h) => h.createChild(s),
        );
        commands
          ..add(create)
          ..add(create);
        commands.add(
          action(
            'RunBeforeParent($name)',
            precondition: (m) =>
                m.exists[parent] &&
                !m.ran[parent] &&
                !m.ran[s] &&
                !m.isRequested(parent),
            nextState: (m) {
              m.exists[s] = true;
              m.ran[s] = true;
            },
            run: (h) => h.runBeforeParent(s),
          ),
        );
      }
      final run = action(
        'Run($name)',
        precondition: (m) => m.exists[s] && !m.ran[s] && !m.isRequested(s),
        nextState: (m) => m.ran[s] = true,
        run: (h) => h.runScope(s),
      );
      commands
        ..add(run)
        ..add(run)
        ..add(run);
      commands.add(
        action(
          'StartDispose($name)',
          precondition: (m) => m.exists[s] && !m.isRequested(s),
          nextState: (m) => m.requested[s] = true,
          run: (h) => h.startDispose(s, ignoreHolds: false),
        ),
      );
      commands.add(
        action(
          'StartDisposeIgnoringHolds($name)',
          precondition: (m) =>
              m.exists[s] && (!m.isRequested(s) || m.heldIn(s) > 0),
          nextState: (m) => m.requested[s] = true,
          run: (h) => h.startDispose(s, ignoreHolds: true),
        ),
      );
      commands.add(
        action(
          'DisposeAgain($name)',
          precondition: (m) => m.exists[s] && m.isRequested(s),
          nextState: (m) {},
          run: (h) => h.disposeAgain(s),
        ),
      );
      commands.add(
        action(
          'OpenHold($name)',
          precondition: (m) => m.exists[s] && !m.isRequested(s),
          nextState: (m) => m.openOrder.add(s),
          run: (h) => h.openHold(s),
        ),
      );
      commands.add(
        Action1<FuzzModel, Harness, int, void>(
          'DisposeNode($name)',
          integer(min: 0, max: 8),
          precondition: (m, _) => !m.ended && m.exists[s] && m.ran[s],
          nextState: (m, _) {},
          run: (h, pick) async {
            h.disposeNode(s, pick);
            await h.check();
          },
        ),
      );
    }
    commands.add(
      Action1<FuzzModel, Harness, int, void>(
        'CloseHold',
        integer(min: 0, max: 20),
        precondition: (m, _) => !m.ended && m.openOrder.isNotEmpty,
        // The model closes the same hold as the harness: the one at the
        // position `pick` of the open holds, in the order of opening.
        nextState: (m, pick) => m.openOrder.removeAt(pick % m.openOrder.length),
        run: (h, pick) async {
          h.closeHold(pick);
          await h.check();
        },
      ),
    );
    commands.add(
      Action2<FuzzModel, Harness, int, bool, void>(
        'Resolve',
        integer(min: 0, max: 20),
        boolean(),
        precondition: (m, _, _) => !m.ended,
        nextState: (m, _, _) {},
        run: (h, pick, fail) async {
          h.resolve(pick, fail);
          await h.check();
        },
      ),
    );
    commands.add(
      Action1<FuzzModel, Harness, int, void>(
        'Resolve',
        integer(min: 0, max: 20),
        precondition: (m, _) => !m.ended,
        nextState: (m, _) {},
        run: (h, pick) async {
          h.resolve(pick, false);
          await h.check();
        },
      ),
    );
    commands.add(
      Action0<FuzzModel, Harness, void>(
        'Terminal',
        precondition: (m) => !m.ended && m.exists[0],
        nextState: (m) => m.ended = true,
        run: (h) => h.terminal(),
      ),
    );
    return commands;
  }
}
