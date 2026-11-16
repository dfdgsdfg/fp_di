import 'dart:async';
import 'dart:collection';

import '../core/core_activation.dart';
import '../core/core_cause.dart';
import '../core/core_describe.dart';
import '../core/core_graph.dart';
import '../core/core_node.dart';
import '../core/core_plan.dart';
import '../core/core_resolve.dart';
import '../core/core_scope.dart';
import '../core/core_search.dart';
import '../core/core_transition.dart';
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

part 'runtime.dart';
part 'runtime_activation.dart';
part 'runtime_change_broadcaster.dart';
part 'runtime_inspector.dart';
part 'runtime_journal.dart';
part 'runtime_mutation_queue.dart';
part 'runtime_state.dart';

/// A hierarchical dependency environment and lifecycle owner.
///
/// {@category Declaration}
/// {@category Guides}
/// {@category Riverpod}
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
      if (debugInspector) {
        relay = _RuntimeInspectorSlowRelay.of(onSlowMutation);
      }
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
      if (debugInspector) _RuntimeInspector.rootCreated(public, relay);
      return true;
    }());
    return public;
  }

  /// Whether a root scope created from now on serves the DevTools inspector.
  ///
  /// The default is false. Set it to true before the first root, for example
  /// at the start of `main`, to inspect the app in the `fp_di` tab of
  /// DevTools. The runtime reads the switch only inside an `assert`, so a
  /// build without assertions, such as a release build, never serves the
  /// inspector.
  ///
  /// The first root created while the switch is true registers the service
  /// extensions of the isolate. A root created while it is false never joins
  /// the inspector. A later change of the switch does not remove a root that
  /// joined, and the service extensions stay registered.
  static bool debugInspector = false;

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
      final duplicate = coreDuplicate(module);
      if (duplicate != null) {
        throw DuplicateKeyError(duplicate.key, labels: duplicate.labels);
      }
      final unresolvable = coreUnresolvable(_scope, module);
      if (unresolvable.isNotEmpty) {
        throw UndeclaredKeyError(unresolvable);
      }
      final nodes = <_RuntimeNode>[];
      var failure = CoreCause.empty;
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
          ..beginInitialize();
        _runtime
          ..markChanged(_scope)
          ..scopeTransition([_scope]);
        failure = await _runtime.activateMembers(nodes);
        if (failure.isEmpty) {
          // A member can first activate here, after a node that the module
          // woke publishes a key it needs. It fails the call like a member
          // that fails during the scheduling above.
          final sink = _RuntimeFailureSink(nodes.toSet());
          await _runtime.reconcile(sink: sink);
          failure = CoreCause.all([
            for (final node
                in sink.failures.keys.toList()
                  ..sort((a, b) => a.id.compareTo(b.id)))
              sink.failures[node]!,
          ]);
        }
      } on Object catch (error, stackTrace) {
        // A throw of the runtime itself fails the call like a member.
        failure = CoreFail(error, stackTrace);
      }
      if (!failure.isEmpty) {
        var rollback = CoreCause.empty;
        for (final node in nodes.reversed) {
          rollback = rollback.then(
            await _runtime.deactivate(node, permanent: true),
          );
        }
        // The rollback ended. The scope is `declared` again, without nodes,
        // only when no disposal was requested. Otherwise the phase stays
        // `disposeRequested`, and the state keeps the disposed nodes.
        _scope.rollbackInitialize();
        if (!_scope.disposalRequested) {
          _scope.nodes = const [];
          _runtime.markChanged(_scope);
        }
        _runtime.scopeTransition([_scope]);
        // Nodes that the module's bindings woke are dormant now; reconcile
        // leaves the runtime consistent for the rest.
        await _runtime.reconcile();
        final thrown = failure
            .then(rollback)
            .activationError(
              // The defect `DropLater` drops the rollback failures of the
              // other members.
              dropOthers: RuntimeFaults.injects(RuntimeDefect.dropLater),
            );
        Error.throwWithStackTrace(thrown.error, thrown.stackTrace);
      }
      _scope
        ..handles = List<ComponentNode<Object?>>.unmodifiable([
          for (final node in nodes) _handleOf<Object?>(node),
        ])
        ..finishInitialize();
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
  ///
  /// The disposal waits while a hold of this scope or of a descendant is
  /// open ([disposeHold]). In that time [isDisposed] is true, the lookups
  /// answer, and no node starts an activation. With [ignoreHolds], the
  /// disposal starts at once, also when an earlier call waits; that call
  /// then completes with this disposal. Do not wait for the result before
  /// you close the holds of this scope: the disposal waits for them.
  Future<void> dispose({bool ignoreHolds = false}) {
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
    final joined = owner?.disposal;
    if (joined != null && joined.finished) {
      // The defect replays the result of the finished disposal.
      if (RuntimeFaults.injects(RuntimeDefect.replayAfterEnd)) {
        return joined.result;
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
      // A call that ignores the holds ends the wait of the disposal it joins.
      final parked = owner.parked;
      if (ignoreHolds && parked != null) {
        // The disposal reports the ignored holds after its start transition.
        parked.queue(_runtime.holdStatesOf(owner));
      }
      // The defect `SecondCallerOk` hides the result from a joining call.
      if (RuntimeFaults.injects(RuntimeDefect.secondCallerOk)) {
        return owner.disposal!.result.then<void>(
          (_) {},
          onError: (Object _) {},
        );
      }
      return owner.disposal!.result;
    }
    // Cancel the setup in flight now, before the disposal waits in the queue.
    _runtime.requestScopeDisposal(_scope);
    final result = Completer<void>();
    // This call runs outside a mutation of the runtime, so its zone can
    // queue the disposal when a hold closes inside a mutation.
    final callerZone = Zone.current;
    var queued = false;
    void queue([List<HoldState> ignored = const []]) {
      if (queued) return;
      queued = true;
      _scope.endWaitForHolds();
      // A waiting disposal of a descendant completes with this one, which
      // releases its nodes.
      final waiting = [
        for (final scope in _runtime.subtreeOf(_scope))
          if (!identical(scope, _scope) && scope.parked != null) scope,
      ];
      final zone = _runtime.mutations.inMutation ? callerZone : Zone.current;
      final disposal = zone.run(
        () => _runtime.mutate('Scope.dispose', () async {
          if (_scope.disposed) {
            // An ancestor released this scope first: share its result.
            for (
              var scope = _scope.parent;
              scope != null;
              scope = scope.parent
            ) {
              final ancestor = scope.disposal;
              if (ancestor != null) return ancestor.result;
            }
            return;
          }
          final released = await _runtime.disposeScope(
            _scope,
            // The defect `dropIgnoredReport` skips the report.
            started:
                ignored.isEmpty ||
                    RuntimeFaults.injects(RuntimeDefect.dropIgnoredReport)
                ? null
                : () => _runtime.changes.report(IgnoredHoldsException(ignored)),
          );
          released.throwDisposeError();
        }),
      );
      result.complete(disposal);
      for (final scope in waiting) {
        final held = scope.endWaitForHolds()?.result;
        // The defect `loseHeldCaller` leaves the waiting call incomplete.
        if (!RuntimeFaults.injects(RuntimeDefect.loseHeldCaller)) {
          held?.complete(disposal);
        }
      }
    }

    final disposal = result.future;
    _scope.disposal = _RuntimeDisposal(disposal);
    final ignored = ignoreHolds
        ? _runtime.holdStatesOf(_scope)
        : const <HoldState>[];
    // The defect `queueWithHolds` queues the disposal while a hold is open.
    if (ignoreHolds ||
        RuntimeFaults.injects(RuntimeDefect.queueWithHolds) ||
        _runtime.subtreeHolds(_scope) == 0) {
      queue(ignored);
    } else {
      _scope.parked = _RuntimeParkedDisposal(
        queue: queue,
        result: result,
        timer: _watchHolds(callerZone),
      );
    }
    // The call is accepted: the disposal is recorded, and queued or waiting
    // for holds. A listener of this transition that calls `dispose` joins
    // it, and a mutation that the listener requests runs after it.
    _runtime.scopeTransition(_runtime.subtreeOf(_scope));
    return disposal;
  }

  /// Reports a wait for holds after each threshold of the listener of slow
  /// work. The timer runs in the zone of the caller, outside any mutation.
  Timer? _watchHolds(Zone callerZone) {
    final listener = _runtime.slowListener;
    if (listener == null) return null;
    final watch = Stopwatch()..start();
    return callerZone.run(
      () => Timer.periodic(
        _runtime.slowThreshold,
        (_) => listener(
          SlowMutation(
            operation: 'Scope.dispose (waiting for holds)',
            elapsed: watch.elapsed,
            running: const [],
            ignoringCancellation: const [],
            queued: 0,
            holds: _runtime.holdStatesOf(_scope),
          ),
        ),
      ),
    );
  }

  /// Delays the disposal of this scope until the returned hold closes.
  ///
  /// A consumer that reads this scope from outside the runtime, such as a
  /// page of a widget tree, takes a hold and closes it when it leaves. A
  /// [dispose] call then marks the scope disposed at once and cancels its
  /// work, but it releases the nodes only after every hold of this scope and
  /// of its descendants closed, or after a call with `ignoreHolds`. The
  /// lookups answer until then.
  ///
  /// Throws [DisposedScopeError] when the disposal of this scope or of an
  /// ancestor was requested.
  ///
  /// [debugLabel] names the holder in [openHolds], in [describe], and in the
  /// reports of a slow wait and of a disposal that ignored the hold.
  DisposeHold disposeHold({String? debugLabel}) {
    if (_scope.disposalRequested) throw DisposedScopeError();
    final hold = _RuntimeHold(debugLabel);
    assert(() {
      hold.stackTrace = StackTrace.current;
      return true;
    }());
    _scope.holds.add(hold);
    return DisposeHold._(this, hold);
  }

  /// The open holds of the disposal of this scope and of its descendants.
  ///
  /// The read does not throw in any phase and starts no mutation.
  List<HoldState> get openHolds =>
      List.unmodifiable(_runtime.holdStatesOf(_scope));

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
      if (unavailable.failedNodeStates.isNotEmpty ||
          !coreCanPublish(_scope, actual)) {
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
    final node = coreNearestNode(_scope, actual);
    return node == null ? null : _handleOf<T>(node);
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
    return coreDescribe<_RuntimeScope, _RuntimePublisher, _RuntimeNode>(
      _scope,
      _runtime.nodes,
      (scope) => [
        for (final hold in _runtime.holdStatesOf(scope))
          hold.debugLabel ?? 'hold',
      ],
    );
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
  /// function adds nothing. Throws [DisposedScopeError] once the disposal
  /// mutation of this scope or of an ancestor starts. A disposal that waits
  /// for holds still accepts a listener, which then hears the start and the
  /// end of the disposal.
  void addListener(void Function() listener) {
    if (_scope.disposing || _scope.disposed) throw DisposedScopeError();
    _runtime.changes.add(_scope, listener);
  }

  /// Removes [listener] from this scope. It does not throw in any phase.
  void removeListener(void Function() listener) {
    _runtime.changes.remove(_scope, listener);
  }

  void _checkActive() {
    if (_scope.disposed || _scope.disposing) throw DisposedScopeError();
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

  Future<void> _disposeNode(_RuntimeNode node) {
    final pending = node.disposal;
    if (pending != null && pending.finished) return Future.value();
    if (pending == null && node.removed) return Future.value();
    // As for a scope: reject a reentrant call before sharing a disposal.
    if (_runtime.mutations.inMutation) {
      return Future.error(
        ReentrantMutationError('ComponentNode.dispose'),
        StackTrace.current,
      );
    }
    if (pending != null) return pending.result;
    _runtime.requestNodeDisposal(node);
    final disposal = _runtime.mutate('ComponentNode.dispose', () async {
      if (node.removed) {
        _runtime.finishWithdrawal(node);
        return;
      }
      final released = await _runtime.deactivate(node, permanent: true);
      // The readers that this withdrawal canceled may activate again now.
      _runtime.finishWithdrawal(node);
      await _runtime.reconcile();
      released.throwDisposeError();
    });
    node.disposal = _RuntimeDisposal(disposal);
    return disposal;
  }
}

/// The state that the runtime keeps for one [Scope].
/// A hold of the disposal of a scope, from [Scope.disposeHold].
///
/// While it is open, a requested disposal of the scope or of an ancestor
/// waits, unless a call ignores the holds. Close it when the consumer that
/// took it leaves.
///
/// {@category Lifecycle}
final class DisposeHold {
  DisposeHold._(this._owner, this._hold);

  final Scope _owner;
  final _RuntimeHold _hold;
  bool _closed = false;

  /// Ends the hold. A waiting disposal starts when its last hold closes.
  ///
  /// A second call does nothing, and a call after the disposal started
  /// changes nothing. The call never throws, also inside a mutation of the
  /// runtime, a listener, or a dispose function: the disposal then starts
  /// after that mutation.
  void close() {
    if (_closed) return;
    _closed = true;
    final scope = _owner._scope;
    scope.holds.remove(_hold);
    _owner._runtime.holdClosed(scope);
  }
}

/// One open hold, as the scope that gave it keeps it.
final class _RuntimeHold {
  _RuntimeHold(this.debugLabel);

  final String? debugLabel;
  final Stopwatch _open = Stopwatch()..start();

  /// The stack trace of the `disposeHold` call, recorded inside an assert.
  StackTrace? stackTrace;

  HoldState stateIn(String scopePath) => HoldState(
    debugLabel: debugLabel,
    scopePath: scopePath,
    elapsed: _open.elapsed,
    debugStackTrace: stackTrace,
  );
}

final class _RuntimeScope
    implements CoreScope<_RuntimeScope, _RuntimePublisher, _RuntimeNode> {
  _RuntimeScope(this.parent, this.declared);

  @override
  final _RuntimeScope? parent;

  /// The components that `initialize` creates.
  @override
  final Module declared;

  /// The internal contribution key of each declared set contribution, by
  /// declaration index, or null for another component. It exists before any
  /// node, so a reader can count a contribution of a scope that is not
  /// initialized.
  @override
  late final List<_DiContributionKey?> contributionKeys = [
    for (final component in declared.components)
      if (component.contributesTo case final set?)
        _DiContributionKey(set)
      else
        null,
  ];

  /// The declaration index of the component that publishes a key, and of
  /// the set contribution that has an internal contribution key.
  @override
  late final Map<DiKeyBase, int> declarationIndexes = () {
    final result = <DiKeyBase, int>{};
    final components = declared.components;
    for (var i = 0; i < components.length; i++) {
      if (components[i].key case final key?) result.putIfAbsent(key, () => i);
      if (contributionKeys[i] case final key?) result[key] = i;
    }
    return result;
  }();

  // The flags `initialized`, `initializing`, `disposeRequested`, `disposing`,
  // and `disposed` hold the lifecycle of this scope. Only the transition
  // methods `beginInitialize` to `markDisposed` write them, and each method
  // asks the table of `core_transition.dart` first.

  /// `initialize` completed for this scope.
  bool _initialized = false;

  @override
  bool get initialized => _initialized;

  /// The `initialize` mutation of this scope runs.
  bool _initializing = false;

  @override
  bool get initializing => _initializing;

  /// The nodes of this scope in declaration order, from their creation by
  /// `initialize`. A disposed node stays at its position. Empty before
  /// `initialize` and after an `initialize` that failed without a disposal
  /// request.
  @override
  List<_RuntimeNode> nodes = const [];

  /// The phase of this scope in the state of the runtime. Only
  /// `_Runtime.scopeTransition` and `_Runtime.childCreated` write it.
  @override
  ScopePhase phase = ScopePhase.declared;

  /// The last `ScopeState` that the runtime built for this scope, or null.
  ScopeState? state;

  /// Whether the value of this scope or of a descendant changed since
  /// [state] was built. Each ancestor of a changed scope is changed.
  bool changed = false;

  /// The phase that the fields of this scope give.
  ScopePhase get currentPhase => coreScopePhase(this);

  List<ComponentNode<Object?>> handles = const [];
  @override
  final Set<_RuntimeScope> children = <_RuntimeScope>{};
  final Map<DiKeyBase, _RuntimePublisher> bindings =
      <DiKeyBase, _RuntimePublisher>{};

  /// The public scope of this state.
  Scope? public;

  /// The disposal mutation of this scope or of an ancestor runs.
  bool _disposing = false;

  @override
  bool get disposing => _disposing;

  /// The disposal mutation released the nodes of this scope.
  bool _disposed = false;

  @override
  bool get disposed => _disposed;

  /// `dispose` was called, and its mutation has not finished. Set at the
  /// call, before the mutation reaches the queue.
  bool _disposeRequested = false;

  @override
  bool get disposeRequested => _disposeRequested;

  /// `initialize` creates the nodes and starts to run.
  void beginInitialize() {
    final next = _expect(CoreScopeEvent.beginInitialize);
    _initializing = true;
    _confirm(CoreScopeEvent.beginInitialize, next);
  }

  /// `initialize` ended with success.
  void finishInitialize() {
    final next = _expect(CoreScopeEvent.finishInitialize);
    _initialized = true;
    _initializing = false;
    _confirm(CoreScopeEvent.finishInitialize, next);
  }

  /// `initialize` ended with a rollback.
  void rollbackInitialize() {
    final next = _expect(CoreScopeEvent.rollbackInitialize);
    // The fault leaves the flag set.
    if (!RuntimeFaults.breaks(RuntimeSelfCheckFault.scopeTransition)) {
      _initializing = false;
    }
    _confirm(CoreScopeEvent.rollbackInitialize, next);
  }

  /// A `dispose` call was accepted for this scope.
  void requestDisposal() {
    final next = _expect(CoreScopeEvent.requestDisposal);
    _disposeRequested = true;
    _confirm(CoreScopeEvent.requestDisposal, next);
  }

  /// The disposal mutation of this scope, or of an ancestor, starts.
  void markDisposing() {
    final next = _expect(CoreScopeEvent.markDisposing);
    _disposing = true;
    _confirm(CoreScopeEvent.markDisposing, next);
  }

  /// The disposal mutation released the nodes of this scope.
  void markDisposed() {
    final next = _expect(CoreScopeEvent.markDisposed);
    _disposed = true;
    _disposing = false;
    _confirm(CoreScopeEvent.markDisposed, next);
  }

  /// The own phase that [event] gives from the own phase now. The method
  /// reads the table only inside an `assert`, so it returns null when the
  /// self-checks are off or muted. It throws when the table forbids [event].
  ScopePhase? _expect(CoreScopeEvent event) {
    ScopePhase? next;
    assert(() {
      if (RuntimeFaults.selfChecksMuted) return true;
      next = coreScopeTransition(coreOwnScopePhase(this), event);
      if (next == null) {
        throw AssertionError(
          'SelfCheck ScopeTransition: ${event.name} is not allowed in the '
          'phase ${coreOwnScopePhase(this).name}',
        );
      }
      return true;
    }());
    return next;
  }

  /// Checks that the flags after [event] give the phase that [expected]
  /// names. [expected] is null when [_expect] did not run.
  void _confirm(CoreScopeEvent event, ScopePhase? expected) {
    assert(
      RuntimeFaults.selfChecksMuted ||
          expected == null ||
          coreOwnScopePhase(this) == expected,
      'SelfCheck ScopeTransition: ${event.name} leaves the phase '
      '${coreOwnScopePhase(this).name}, not ${expected.name}',
    );
  }

  /// The disposal that the first `dispose` call started, which a repeated
  /// call shares. The scope is marked disposed before the disposal finishes.
  _RuntimeDisposal? disposal;

  /// The open holds of the disposal of this scope.
  final Set<_RuntimeHold> holds = <_RuntimeHold>{};

  /// The disposal of this scope while it waits for holds, or null.
  _RuntimeParkedDisposal? parked;

  /// Ends the wait of the disposal of this scope: stops its timer and
  /// forgets it. Returns the disposal that waited, or null.
  _RuntimeParkedDisposal? endWaitForHolds() {
    final waiting = parked;
    waiting?.timer?.cancel();
    parked = null;
    return waiting;
  }

  @override
  bool get waitsForHolds => parked != null;

  @override
  int get holdCount => holds.length;

  /// Whether the disposal of this scope or an ancestor was requested.
  bool get disposalRequested => coreDisposalRequested(this);

  /// The nearest available publisher of [key], from this scope to the root.
  /// A publisher that [excludeOwner] owns does not count.
  _RuntimePublisher? resolve(DiKeyBase key, {_RuntimeNode? excludeOwner}) =>
      coreResolve(
        this,
        key,
        excludeOwner: excludeOwner,
        // The defect keeps walking and returns the farthest binding.
        farthest: RuntimeFaults.injects(RuntimeDefect.farthestBinding),
      );

  @override
  _RuntimePublisher? bindingOf(DiKeyBase key) => bindings[key];
}
