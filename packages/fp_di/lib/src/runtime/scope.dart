import 'dart:async';
import 'dart:collection';

import '../model/cancellation.dart';
import '../model/change.dart';
import '../model/component.dart';
import '../model/context.dart';
import '../model/error.dart';
import '../model/exception.dart';
import '../model/key.dart';
import '../model/lease.dart';
import '../model/module.dart';
import '../model/shape_graph.dart';
import '../model/state.dart';
import 'runtime_faults.dart';
import 'runtime_inspector_hooks.dart';
import 'runtime_teardown.dart';

part 'runtime_change_broadcaster.dart';
part 'runtime_mutation_queue.dart';
part 'runtime.dart';
part 'runtime_context.dart';
part 'runtime_inspector.dart';
part 'runtime_state.dart';

/// A hierarchical dependency environment and lifecycle owner.
///
/// {@category Declaration}
/// {@category Guides}
final class Scope {
  Scope._(this._runtime, this._scope);

  /// A new root scope with its own runtime: mutation queue, nodes, and
  /// [errors]. An application needs one; each test can create its own.
  ///
  /// [module] declares the components of this scope. Nothing is created until
  /// [initialize] runs.
  ///
  /// Every lifecycle mutation of the root and its descendants runs on one
  /// queue, so a long one delays the next. With [onSlowMutation], the runtime
  /// reports a mutation that runs longer than [slowMutationThreshold], and
  /// again after each further threshold while it still runs, naming the
  /// activations in flight. Without it, no timer runs.
  factory Scope({
    Module? module,
    SlowMutationListener? onSlowMutation,
    Duration slowMutationThreshold = const Duration(seconds: 2),
  }) {
    _RuntimeInspectorSlowRelay? relay;
    assert(() {
      relay = _RuntimeInspectorSlowRelay.of(onSlowMutation);
      return true;
    }());
    final runtime = _Runtime(
      onSlowMutation: relay?.report ?? onSlowMutation,
      slowMutationThreshold: slowMutationThreshold,
    );
    final scope = _RuntimeScope(null, module ?? Module(components: const []));
    final public = Scope._(runtime, scope);
    scope.public = public;
    runtime.scopes.add(public);
    assert(() {
      _RuntimeInspector.rootCreated(public, relay);
      return true;
    }());
    return public;
  }

  final _Runtime _runtime;
  final _RuntimeScope _scope;

  /// Creates the declared components: each becomes a node of this scope.
  ///
  /// The runtime creates every member node in declaration order, then
  /// activates the members by dependency. A member starts as soon as each
  /// member that publishes a key it reads has settled, so
  /// independent members activate at the same time. A member that settles by
  /// waiting on a key that no member publishes stays dormant. After
  /// every member has settled, the runtime runs one reconciliation, which
  /// repeats its passes until the targets settle. A member whose
  /// requirements are unmet, including one that needs a key that an ancestor
  /// scope publishes after this call, starts dormant and activates when the
  /// key appears. Dormancy is not failure.
  ///
  /// A member publishes its bindings when its own activation succeeds, so the
  /// commit order of independent members follows completion order and is not
  /// deterministic. A member always commits before the members that read its
  /// key start. A listener observes the commits in commit order.
  ///
  /// The call is atomic and does not depend on declaration order. If the
  /// activation of any member throws, the runtime starts no further member
  /// and waits for every member that is still activating to settle. Then it
  /// deactivates and disposes every member in reverse declaration order,
  /// and rethrows the failure of the first failed member in declaration
  /// order. The scope then stays uninitialized, and a later call may retry.
  /// A failing member does not cancel a sibling in flight; each member is
  /// its own failure region. A [dispose] of this scope cancels them all.
  /// A node of a descendant scope that wakes because of the new
  /// bindings follows the reconciliation contract instead: its failure goes
  /// to [errors] and this call succeeds. Dispose failures during the rollback
  /// are attached to an [ActivationException].
  ///
  /// Before it creates anything, it throws [DuplicateKeyError] when two
  /// members of this scope publish the same key, and [UndeclaredKeyError]
  /// when a member requires a key that no member of this scope or its
  /// ancestors declares. It throws [DependencyCycleError] and rolls back when
  /// optional reads among its members feed back and do not settle.
  ///
  /// Completes with this scope, so a caller can declare and initialize in one
  /// expression:
  /// `final session = await app.child(module: module).initialize();`.
  ///
  /// Throws a [StateError] when this scope is already initialized.
  Future<Scope> initialize() {
    _checkActive();
    if (_scope.disposalRequested) throw DisposedScopeError();
    return _runtime.mutate('initialize', () async {
      // Setup never starts for a scope whose disposal was requested while
      // this call waited in the queue.
      if (_scope.disposalRequested && !_scope.disposed) {
        throw ActivationCanceledException();
      }
      _checkActive();
      if (_scope.initialized) {
        throw StateError('The scope is already initialized.');
      }
      final module = _scope.declared;
      final duplicate = _duplicate(module);
      if (duplicate != null) {
        throw DuplicateKeyError(duplicate.key, labels: duplicate.labels);
      }
      final unresolvable = _unresolvable(module);
      if (unresolvable.isNotEmpty) {
        throw UndeclaredKeyError(unresolvable);
      }
      final nodes = <_RuntimeNode>[];
      try {
        for (var i = 0; i < module.components.length; i++) {
          nodes.add(
            _runtime.createNode<Object?>(_scope, switch (module.components[i]) {
              final Component<Object?> c => c,
            }, declarationIndex: i),
          );
        }
        // One transition: the scope has its nodes, and `initialize` runs.
        _scope
          ..nodes = List<_RuntimeNode>.unmodifiable(nodes)
          ..initializing = true;
        _runtime
          ..markChanged(_scope)
          ..scopeTransition([_scope]);
        await _runtime.activateMembers(nodes);
        // A member can first activate here, after a node that the module woke
        // publishes a key it needs. It fails the call like a member that
        // fails during the scheduling above.
        final sink = _RuntimeFailureSink(nodes.toSet());
        await _runtime.reconcile(sink: sink);
        final failed = sink.failures.entries.toList()
          ..sort((a, b) => a.key.id.compareTo(b.key.id));
        if (failed.isNotEmpty) {
          final (error, stackTrace) = failed.first.value;
          final extra = <DisposeFailure>[
            // The defect `DropLater` drops the rollback failures of the
            // other members.
            if (!RuntimeFaults.injects(RuntimeDefect.dropLater))
              for (final entry in failed.skip(1))
                ..._Runtime.disposeFailuresOf(entry.value.$1),
          ];
          Error.throwWithStackTrace(
            _Runtime.withDisposeFailures(error, stackTrace, extra),
            stackTrace,
          );
        }
      } on Object catch (error, stackTrace) {
        final disposeFailures = <DisposeFailure>[];
        for (final node in nodes.reversed) {
          disposeFailures.addAll(
            await _runtime.deactivate(node, permanent: true),
          );
        }
        // The rollback ended. The scope is `declared` again, without nodes,
        // only when no disposal was requested. Otherwise the phase stays
        // `disposeRequested`, and the state keeps the disposed nodes.
        _scope.initializing = false;
        if (!_scope.disposalRequested) {
          _scope.nodes = const [];
          _runtime.markChanged(_scope);
        }
        _runtime.scopeTransition([_scope]);
        // Nodes that the module's bindings woke are dormant now; reconcile
        // leaves the runtime consistent for the rest.
        await _runtime.reconcile();
        if (disposeFailures.isEmpty) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        if (error is ActivationCanceledException) {
          throw ActivationCanceledException(
            cause: error.cause,
            stackTrace: error.stackTrace,
            rollbackFailures: <DisposeFailure>[
              ...error.rollbackFailures,
              ...disposeFailures,
            ],
          );
        }
        if (error is ActivationException) {
          throw ActivationException(
            error.cause,
            error.stackTrace,
            <DisposeFailure>[...error.rollbackFailures, ...disposeFailures],
          );
        }
        throw ActivationException(error, stackTrace, disposeFailures);
      }
      _scope
        ..handles = List<ComponentNode<Object?>>.unmodifiable([
          for (final node in nodes) _handleOf<Object?>(node),
        ])
        ..initialized = true
        ..initializing = false;
      _runtime.scopeTransition([_scope]);
      return this;
    });
  }

  /// Disposes this scope, its descendants, and everything they own.
  ///
  /// A node releases after every node that read one of its values has
  /// finished, so each release runs while the values it read are alive.
  /// Nodes that do not read each other release at the same time; the dispose
  /// functions of one node run one after another, last registered first. A
  /// [DisposeException] lists its failures in reverse creation order (a
  /// read cycle reports in the depth-first order of its release). Two
  /// members that share an external resource without a key between them
  /// need a token key to keep an order.
  Future<void> dispose() {
    // The disposal of this scope or of an ancestor, if one was requested.
    // Its future completes after the whole mutation, which can still run
    // after the scope is marked disposed.
    _RuntimeScope? owner;
    for (_RuntimeScope? scope = _scope; scope != null; scope = scope.parent) {
      if (scope.disposal != null) {
        owner = scope;
        break;
      }
    }
    // After the disposal finished, a later call does nothing; its result
    // went to the calls made while it ran.
    if (owner != null && owner.disposalFinished) {
      // The defect replays the result of the finished disposal.
      if (RuntimeFaults.injects(RuntimeDefect.replayAfterEnd)) {
        return owner.disposal!;
      }
      return Future.value();
    }
    if (owner == null && _scope.disposed) return Future.value();
    // Reject a call from inside a running mutation before it waits for
    // or starts a disposal: the disposal in progress may be the very
    // mutation it runs in, and would then wait for itself.
    if (_runtime.mutations.inMutation) {
      // The defect records the request before the rejection.
      if (owner == null &&
          RuntimeFaults.injects(RuntimeDefect.lateReentrancyCheck)) {
        _runtime.requestScopeDisposal(_scope);
        _runtime.scopeTransition(_runtime.subtreeOf(_scope));
      }
      return Future.error(
        ReentrantMutationError('Scope.dispose'),
        StackTrace.current,
      );
    }
    // A repeated call, or a call while an ancestor disposes this scope,
    // completes with the disposal that is in progress.
    if (owner != null) {
      // The defect `SecondCallerOk` hides the result from a joining call.
      if (RuntimeFaults.injects(RuntimeDefect.secondCallerOk)) {
        return owner.disposal!.then<void>((_) {}, onError: (Object _) {});
      }
      return owner.disposal!;
    }
    // Cancel the setup in flight now, before the disposal waits in the queue.
    _runtime.requestScopeDisposal(_scope);
    final disposal = _runtime.mutate('Scope.dispose', () async {
      if (_scope.disposed) return;
      final disposeFailures = await _runtime.disposeScope(_scope);
      if (disposeFailures.isNotEmpty) throw DisposeException(disposeFailures);
    });
    _scope.disposal = disposal;
    disposal.then<void>(
      (_) => _scope.disposalFinished = true,
      onError: (Object _) => _scope.disposalFinished = true,
    );
    // The call is accepted: the disposal is recorded and queued. A listener
    // of this transition that calls `dispose` joins it, and a mutation that
    // the listener requests runs after it.
    _runtime.scopeTransition(_runtime.subtreeOf(_scope));
    return disposal;
  }

  /// Whether [initialize] has completed for this scope. It stays true after
  /// [dispose].
  bool get isInitialized => _scope.initialized;

  /// Whether [dispose] was called for this scope or an ancestor.
  ///
  /// It is true from the call, before the disposal runs, and it never
  /// becomes false again: it is true in the phases
  /// [ScopePhase.disposeRequested], [ScopePhase.disposing], and
  /// [ScopePhase.disposed]. The read does not throw and starts no mutation.
  bool get isDisposed => _scope.disposalRequested;

  /// The module that this scope was created with: its declarations.
  ///
  /// Each read returns the same object. A scope that was created without a
  /// module returns an empty module. The component at a position of
  /// `module.components` is the component of the [NodeState] at that position
  /// of `state.nodeStates`, so a tool joins the shape of the module with the
  /// state of the scope by position.
  ///
  /// The module holds the declarations of this scope only, and no component
  /// of an ancestor or of a child scope. Its `publishes`, `requires`, and
  /// `reads` state declared keys, not the keys that resolve now: read
  /// [NodeState.missing] and [findNode] for those. An edit, such as
  /// `module.replacing`, returns a new module and does not change this
  /// scope.
  ///
  /// The read does not throw in any phase, also after the disposal, and
  /// starts no mutation.
  Module get module => _scope.declared;

  /// The state of this scope and its descendants, as an immutable value.
  ///
  /// The value holds the [ScopePhase] of the scope, a [NodeState] for each of
  /// its nodes, and the state of each child scope that is not disposed. A
  /// later transition gives a new value and leaves this one as it was. The
  /// runtime keeps the object of a scope that a transition does not change,
  /// so two reads without a transition between them return the same object,
  /// and `identical` tells that nothing in the scope changed.
  ///
  /// The value holds no ancestor. Read the node of an ancestor with
  /// [findNode] and keep its `state`.
  ///
  /// The read does not throw in any phase and starts no mutation.
  ScopeState get state => _runtime.stateOf(_scope);

  /// Creates a child whose lookup falls back to this scope.
  ///
  /// [module] declares the components of the child. Nothing is created until
  /// the child's [initialize] runs. The child shares the runtime of its root.
  /// Its bindings shadow the bindings of this scope, this scope cannot see
  /// them, and disposing the child disposes its descendants and leaves this
  /// scope intact. A child can initialize before this scope does; its nodes
  /// then wait for the keys that this scope publishes later.
  Scope child({Module? module}) {
    _checkActive();
    final childScope = _RuntimeScope(
      _scope,
      module ?? Module(components: const []),
    );
    _scope.children.add(childScope);
    final child = Scope._(_runtime, childScope);
    childScope.public = child;
    _runtime.scopes.add(child);
    _runtime.childCreated(childScope);
    return child;
  }

  /// The value of [key], from the nearest active publisher of this scope
  /// and its ancestors. Without [key], the key is `DiKey<T>()`.
  ///
  /// Throws an [UnavailableKeyException] when the key has no value. Its
  /// `message` states the case: no node publishes the key, a scope that is
  /// not initialized declares it, or the node of the key waits, failed, or
  /// has another phase. Its `failedNodeStates` holds the state of each failed
  /// node behind the key, with the cause and the stack trace of each
  /// failure. The runtime searches for the cause only on this path.
  ///
  /// Throws a [DisposedScopeError] for a disposed scope.
  T get<T>({DiKey<T>? key}) {
    _checkActive();
    final actual = key ?? DiKey<T>();
    final publisher = _scope.resolve(actual);
    if (publisher == null) throw _runtime.unavailable(_scope, actual);
    return publisher.value as T;
  }

  /// The value of [key] as [get] reads it, or null when the key has no
  /// value.
  ///
  /// The result is null also for a key whose node failed, because a later
  /// change can activate that node. Call [get] where a failure must not
  /// read as a key without a value.
  T? maybeGet<T>({DiKey<T>? key}) {
    _checkActive();
    final publisher = _scope.resolve(key ?? DiKey<T>());
    return publisher?.value as T?;
  }

  /// One node for each declared component, in declaration order. Empty
  /// until [initialize] completes. `state.nodeStates` holds the [NodeState]
  /// of the node at each position, and holds it from the start of
  /// [initialize].
  ///
  /// A member node reads the value, reports whether the member is active,
  /// waits for it with `whenActive`, and disposes the member alone. Disposing
  /// one member withdraws its bindings and deactivates its dependents first.
  /// The disposal does not remove the other members.
  List<ComponentNode<Object?>> get nodes => _scope.handles;

  /// The node of the one member that publishes [key].
  ///
  /// It finds a member the way `Module.replacing` does, so the caller does
  /// not depend on the declaration order. The node reads the value as [T].
  /// Use [nodes] for a member that publishes no key. The read looks at this
  /// scope only; [findNode] gives the node that [get] reads, which can
  /// belong to an ancestor.
  ///
  /// Throws a [StateError] before [initialize] completes, and an
  /// [ArgumentError] when no member publishes [key].
  ComponentNode<T> node<T>({required DiKey<T> key}) {
    _checkActive();
    if (!_scope.initialized) {
      throw StateError('The scope is not initialized.');
    }
    final components = _scope.declared.components;
    for (var i = 0; i < components.length; i++) {
      if (components[i].key == key) {
        return _handleOf<T>(_scope.nodes[i]);
      }
    }
    throw ArgumentError.value(key, 'key', 'no member publishes it');
  }

  /// Completes with the value of [key] once it has one.
  ///
  /// It completes at once when [get] returns a value, and otherwise when a
  /// node of this scope or of an ancestor commits [key]. Without [key], the
  /// key is `DiKey<T>()`, as for [get].
  ///
  /// It waits while a scope of the chain can still publish [key]: a scope
  /// that declares it and is not initialized yet, such as a parent that a
  /// child initializes before, or a scope whose node of [key] waits, runs,
  /// or is inactive.
  ///
  /// It fails with the [UnavailableKeyException] that [get] would throw when
  /// an activation failure is behind [key]; the exception then holds the
  /// failed nodes. It fails the same way when no scope of the chain can
  /// publish [key] any more: no scope declares it, its node was disposed,
  /// or its node is in [NodePhase.disposeFailed]. It fails with a
  /// [DisposedScopeError] when the disposal of this scope or of an ancestor
  /// is requested before [key] has a value.
  ///
  /// The call starts no mutation and changes no state. Do not await it
  /// inside an activation: the value arrives in a mutation, so the wait can
  /// last forever.
  Future<T> getWhenAvailable<T>({DiKey<T>? key}) {
    final actual = key ?? DiKey<T>();
    final completer = Completer<T>();
    bool settle() {
      final publisher = _scope.disposing || _scope.disposed
          ? null
          : _scope.resolve(actual);
      if (publisher != null) {
        completer.complete(publisher.value as T);
        return true;
      }
      if (_scope.disposalRequested) {
        completer.completeError(DisposedScopeError(), StackTrace.current);
        return true;
      }
      final unavailable = _runtime.unavailable(_scope, actual);
      if (unavailable.failedNodeStates.isNotEmpty || !_canPublish(actual)) {
        completer.completeError(unavailable, StackTrace.current);
        return true;
      }
      return false;
    }

    if (settle()) return completer.future;
    late final void Function() listener;
    listener = () {
      if (completer.isCompleted || settle()) {
        _runtime.changes.remove(_scope, listener);
      }
    };
    _runtime.changes.add(_scope, listener);
    return completer.future;
  }

  /// Whether a scope from this scope to the root can still publish [key].
  ///
  /// A scope can when it declares [key], its disposal is not requested, and
  /// it has no nodes yet, runs [initialize], or has a node of [key] that is
  /// not disposed and not in [NodePhase.disposeFailed].
  bool _canPublish(DiKeyBase key) {
    for (_RuntimeScope? s = _scope; s != null; s = s.parent) {
      if (s.disposalRequested || !s.declared.publishes.contains(key)) continue;
      if (s.initializing || s.nodes.isEmpty) return true;
      final node = _runtime.nodeOf(s, key);
      if (node != null && _runtime.phaseOf(node) != NodePhase.disposeFailed) {
        return true;
      }
    }
    return false;
  }

  /// The node that publishes [key] for this scope, or null when this scope
  /// and its ancestors have no such node.
  ///
  /// The error of [get] states why a key has no value. This read gives the
  /// node: null means that no node publishes [key], and a node gives its
  /// `state`, its `missing` keys, and its `activationException`. Without
  /// [key], the key is `DiKey<T>()`, as for [get].
  ///
  /// When [get] returns a value, the result is the node that published it.
  /// Otherwise the result is the nearest node whose component publishes
  /// [key], from this scope to the root. A scope has nodes from its
  /// [initialize] call, so a scope that only declares the key does not
  /// count. A member that was disposed alone does not count.
  ///
  /// The node can belong to an ancestor, and its `dispose` then disposes a
  /// member of that ancestor. Each call returns a new view of the node. The
  /// read starts no mutation and changes no state.
  ///
  /// Throws a [DisposedScopeError] for a disposed scope.
  ComponentNode<T>? findNode<T>({DiKey<T>? key}) {
    _checkActive();
    final actual = key ?? DiKey<T>();
    final publisher = _scope.resolve(actual);
    if (publisher != null) return _handleOf<T>(publisher.owner);
    for (_RuntimeScope? scope = _scope; scope != null; scope = scope.parent) {
      final node = _runtime.nodeOf(scope, actual);
      if (node != null) return _handleOf<T>(node);
    }
    return null;
  }

  /// A text that lists each node of this scope and its descendants, for
  /// diagnostics.
  ///
  /// Each node entry states its label, its state (`active`, `activating`,
  /// `deactivating`, `waiting`, `activation failed`, `dispose failed`, or
  /// `inactive`), the
  /// keys it publishes, and the required keys that do not resolve. A scope
  /// that is not initialized lists its declared components with the state
  /// `declared`. While `initialize` runs, a component that has a node shows
  /// the state of the node instead. A child scope is indented below its
  /// parent. The read starts no mutation and changes no state. The format
  /// is for people and can change; do not parse it.
  String describe() {
    _checkActive();
    final lines = <String>[];
    void write(_RuntimeScope scope, String path, int depth) {
      final indent = '  ' * depth;
      final title = path.isEmpty ? 'scope' : '${indent}child scope $path';
      lines.add(scope.initialized ? title : '$title (not initialized)');
      String entryOf(_RuntimeNode node) {
        final parts = <String>[_Runtime.stateWord(_runtime.phaseOf(node))];
        final missing = _missingOf(node);
        if (missing.isNotEmpty) parts.add('missing ${missing.join(', ')}');
        final key = node.declaredPublishes
            .where((key) => key is! _DiContributionKey)
            .firstOrNull;
        if (node.contributionKey case final contribution?) {
          parts.add('contributes to ${contribution.set}');
        }
        return '$indent  - ${_describedLabel(node.label, key)}: '
            '${parts.join('; ')}';
      }

      final nodes = [
        for (final node in _runtime.nodes)
          if (identical(node.scope, scope)) node,
      ];
      if (scope.initialized) {
        lines.addAll(nodes.map(entryOf));
      } else {
        // A running `initialize` has created nodes. Each component has one
        // entry: its node, or `declared` when it has no node.
        final created = <int, _RuntimeNode>{
          for (final node in nodes) node.declarationIndex: node,
        };
        final components = scope.declared.components;
        for (var i = 0; i < components.length; i++) {
          final node = created[i];
          final label = _describedLabel(components[i].label, components[i].key);
          lines.add(
            node == null ? '$indent  - $label: declared' : entryOf(node),
          );
        }
      }
      var index = 0;
      for (final child in scope.children) {
        index++;
        write(child, path.isEmpty ? '$index' : '$path.$index', depth + 1);
      }
    }

    write(_scope, '', 0);
    return lines.join('\n');
  }

  /// The number of transitions of the state of the root. Two reads that
  /// return the same number read the same state.
  int get revision => _runtime.changes.revision;

  /// Automatic reactivation failures that cannot be returned to a caller.
  ///
  /// The stream reports a failure after the listener calls of the transition
  /// that shows it.
  Stream<DiException> get errors => _runtime.changes.errors.stream;

  /// Adds [listener] to this scope.
  ///
  /// The runtime calls each listener of every scope of the root once at each
  /// transition of the state, after it replaced the state. A listener reads
  /// [state], compares it with the value that it kept, and returns. The
  /// runtime has one state, so a listener also runs for a transition of
  /// another scope of the root; `identical` on two reads of [state] tells
  /// that this scope did not change.
  ///
  /// A listener runs inside the transition. A mutation that it requests
  /// inside a mutation fails with [ReentrantMutationError]. After the
  /// transition that disposes this scope, the runtime calls its listeners
  /// and removes them. A listener that throws is removed, and [errors]
  /// reports a [DiListenerException].
  ///
  /// One function is one listener of a scope: a second call with the same
  /// function adds nothing. Throws [DisposedScopeError] while [isDisposed]
  /// is true.
  void addListener(void Function() listener) {
    if (_scope.disposalRequested) throw DisposedScopeError();
    _runtime.changes.add(_scope, listener);
  }

  /// Removes [listener] from this scope. It does not throw in any phase.
  void removeListener(void Function() listener) {
    _runtime.changes.remove(_scope, listener);
  }

  void _checkActive() {
    if (_scope.disposed || _scope.disposing) throw DisposedScopeError();
  }

  /// The first key that more than one member of [module] publishes, with the
  /// labels of those members, or null.
  ({DiKeyBase key, List<String> labels})? _duplicate(Module module) {
    final publishers = <DiKeyBase, List<String>>{};
    for (final member in module.components) {
      final key = member.key;
      if (key != null) {
        publishers.putIfAbsent(key, () => <String>[]).add(member.label);
      }
    }
    for (final MapEntry(:key, value: members) in publishers.entries) {
      if (members.length > 1) return (key: key, labels: members);
    }
    return null;
  }

  /// The required keys of [module] that no other member and no member
  /// declared by an ancestor publishes, in declaration order.
  ///
  /// The declarations are fixed, so such a member could never activate. An
  /// ancestor counts whether or not it is initialized, so a child may still
  /// initialize before its parent.
  List<({String label, DiKeyBase key})> _unresolvable(Module module) {
    if (module.requires.isEmpty) return const [];
    final declared = <DiKeyBase>{};
    for (var scope = _scope.parent; scope != null; scope = scope.parent) {
      declared.addAll(scope.declared.publishes);
    }
    final members = module.components;
    final result = <({String label, DiKeyBase key})>[];
    for (var i = 0; i < members.length; i++) {
      for (final key in members[i].requires) {
        if (declared.contains(key)) continue;
        var published = false;
        for (var j = 0; j < members.length && !published; j++) {
          published = j != i && members[j].key == key;
        }
        if (!published) {
          result.add((label: members[i].label, key: key));
        }
      }
    }
    return result;
  }

  /// The public view of [node], listed in `nodes`.
  ComponentNode<A> _handleOf<A>(_RuntimeNode node) => createComponentNode<A>(
    dispose: () => _disposeNode(node),
    read: () {
      if (node.state.phase != NodePhase.active) {
        throw InactiveNodeException(node.state.missing);
      }
      return node.value as A;
    },
    isActive: () => node.state.phase == NodePhase.active,
    whenActive: () {
      if (node.state.phase == NodePhase.active) {
        return Future<A>.value(node.value as A);
      }
      if (node.removed) {
        return Future<A>.error(InactiveNodeException());
      }
      final waiter = (node.activationWaiters ??= <Zone, Completer<Object?>>{})
          .putIfAbsent(Zone.current, Completer<Object?>.new);
      return waiter.future.then((value) => value as A);
    },
    state: () => node.state,
  );

  /// The keys that `describe` lists as missing, computed from the fields of
  /// [node]. `describe` does not read the held state, so the two can be
  /// compared.
  List<DiKeyBase> _missingOf(_RuntimeNode node) =>
      !node.removed && (!node.active || node.deactivating)
      ? List<DiKeyBase>.unmodifiable(node.unmet)
      : const <DiKeyBase>[];

  /// The label of a member in `describe`, followed by its key when the label
  /// is not the key.
  static String _describedLabel(String label, DiKeyBase? key) =>
      key == null || label == '$key' ? label : '$label ($key)';

  Future<void> _disposeNode(_RuntimeNode node) {
    final pending = node.disposal;
    if (pending != null && node.disposalFinished) return Future.value();
    if (pending == null && node.removed) return Future.value();
    // As for a scope: reject a reentrant call before sharing a disposal.
    if (_runtime.mutations.inMutation) {
      return Future.error(
        ReentrantMutationError('ComponentNode.dispose'),
        StackTrace.current,
      );
    }
    if (pending != null) return pending;
    _runtime.requestNodeDisposal(node);
    final disposal = _runtime.mutate('ComponentNode.dispose', () async {
      if (node.removed) {
        _runtime.finishWithdrawal(node);
        return;
      }
      final disposeFailures = await _runtime.deactivate(node, permanent: true);
      // The readers that this withdrawal canceled may activate again now.
      _runtime.finishWithdrawal(node);
      await _runtime.reconcile();
      if (disposeFailures.isNotEmpty) throw DisposeException(disposeFailures);
    });
    node.disposal = disposal;
    disposal.then<void>(
      (_) => node.disposalFinished = true,
      onError: (Object _) => node.disposalFinished = true,
    );
    return disposal;
  }
}

/// The state that the runtime keeps for one [Scope].
final class _RuntimeScope {
  _RuntimeScope(this.parent, this.declared);

  final _RuntimeScope? parent;

  /// The components that `initialize` creates.
  final Module declared;

  /// The internal contribution key of each declared set contribution, by
  /// declaration index, or null for another component. It exists before any
  /// node, so a reader can count a contribution of a scope that is not
  /// initialized.
  late final List<_DiContributionKey?> contributionKeys = [
    for (final component in declared.components)
      if (component.contributesTo case final set?)
        _DiContributionKey(set)
      else
        null,
  ];

  /// The declaration index of the component that publishes a key, and of
  /// the set contribution that has an internal contribution key.
  late final Map<DiKeyBase, int> declarationIndexes = () {
    final result = <DiKeyBase, int>{};
    final components = declared.components;
    for (var i = 0; i < components.length; i++) {
      if (components[i].key case final key?) result.putIfAbsent(key, () => i);
      if (contributionKeys[i] case final key?) result[key] = i;
    }
    return result;
  }();
  bool initialized = false;

  /// The `initialize` mutation of this scope runs.
  bool initializing = false;

  /// The nodes of this scope in declaration order, from their creation by
  /// `initialize`. A disposed node stays at its position. Empty before
  /// `initialize` and after an `initialize` that failed without a disposal
  /// request.
  List<_RuntimeNode> nodes = const [];

  /// The phase of this scope in the state of the runtime. Only
  /// `_Runtime.scopeTransition` and `_Runtime.childCreated` write it.
  ScopePhase phase = ScopePhase.declared;

  /// The last `ScopeState` that the runtime built for this scope, or null.
  ScopeState? state;

  /// Whether the value of this scope or of a descendant changed since
  /// [state] was built. Each ancestor of a changed scope is changed.
  bool changed = false;

  /// The phase that the fields of this scope give.
  ScopePhase get currentPhase {
    if (disposed) return ScopePhase.disposed;
    if (disposing) return ScopePhase.disposing;
    if (disposalRequested) return ScopePhase.disposeRequested;
    if (initialized) return ScopePhase.initialized;
    if (initializing) return ScopePhase.initializing;
    return ScopePhase.declared;
  }

  List<ComponentNode<Object?>> handles = const [];
  final Set<_RuntimeScope> children = <_RuntimeScope>{};
  final Map<DiKeyBase, _RuntimePublisher> bindings =
      <DiKeyBase, _RuntimePublisher>{};

  /// The public scope of this state.
  Scope? public;
  bool disposing = false;
  bool disposed = false;

  /// `dispose` was called, and its mutation has not finished. Set at the
  /// call, before the mutation reaches the queue.
  bool disposeRequested = false;

  /// The result of the first `dispose` call, which a repeated call shares.
  Future<void>? disposal;

  /// Whether [disposal] completed. The scope is marked disposed earlier.
  bool disposalFinished = false;

  /// Whether the disposal of this scope or an ancestor was requested.
  bool get disposalRequested {
    for (_RuntimeScope? scope = this; scope != null; scope = scope.parent) {
      if (scope.disposeRequested || scope.disposing || scope.disposed) {
        return true;
      }
    }
    return false;
  }

  /// The nearest available publisher of [key], from this scope to the root.
  /// A publisher that [excludeOwner] owns does not count.
  _RuntimePublisher? resolve(DiKeyBase key, {_RuntimeNode? excludeOwner}) {
    // The defect keeps walking and returns the farthest binding.
    final farthest = RuntimeFaults.injects(RuntimeDefect.farthestBinding);
    _RuntimePublisher? found;
    for (_RuntimeScope? scope = this; scope != null; scope = scope.parent) {
      final publisher = scope.bindings[key];
      if (publisher != null &&
          publisher.available &&
          (excludeOwner == null || publisher.owner != excludeOwner)) {
        if (!farthest) return publisher;
        found = publisher;
      }
    }
    return found;
  }
}
