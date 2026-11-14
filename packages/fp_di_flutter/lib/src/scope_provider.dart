import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:fp_di/fp_di.dart';

/// Makes one [Scope] available to descendants through the widget tree.
///
/// The caller owns every scope that it supplies. This widget only subscribes
/// to notifications while mounted; it never disposes a scope.
///
/// This widget only publishes. It does not create, initialize, or dispose a
/// scope, so the code that calls `initialize` also gets its failure.
///
/// [ScopeProvider.listenable] takes a [ValueListenable] that holds the
/// current scope, for example a `ValueNotifier<Scope>`. A lookup reads the
/// value of the listenable at the moment of the call. A change of the value
/// therefore reaches every lookup at once, before the next frame rebuilds a
/// widget.
///
/// To replace a scope and dispose it, change the value first. Call `dispose`
/// on the old scope after that:
///
/// ```dart
/// current.value = app;
/// await session.dispose();
/// ```
///
/// A scope answers no read from the moment its disposal starts, not even for
/// a key of its parent. With the other order, a widget that reads before the
/// change gets a `DisposedScopeError`.
class ScopeProvider extends StatefulWidget {
  /// Publishes the scope that [scope] holds at the moment of each lookup.
  const ScopeProvider.listenable({
    required ValueListenable<Scope> scope,
    required this.child,
    super.key,
  }) : _listenable = scope,
       _fixed = null;

  /// Publishes one [scope] that lives longer than this widget.
  ///
  /// Use this constructor only for a scope that is not disposed while this
  /// widget is mounted, such as the one scope of an application or of a
  /// test. A parent that rebuilds this widget with another scope replaces
  /// the scope only at the next frame. A lookup before that frame still
  /// reads the old scope. For a scope that changes, use
  /// [ScopeProvider.listenable].
  const ScopeProvider.fixed({
    required Scope scope,
    required this.child,
    super.key,
  }) : _listenable = null,
       _fixed = scope;

  final ValueListenable<Scope>? _listenable;
  final Scope? _fixed;

  /// The widget below this provider, which reads the published scope.
  final Widget child;

  @override
  State<ScopeProvider> createState() => _ScopeProviderState();

  /// The current [Scope] of the closest [ScopeProvider].
  ///
  /// Pass [key] to rebuild when the value of that key changes. Pass [nodeKey]
  /// to rebuild when the node that publishes that key changes its state, as
  /// `Scope.findNode` reads it. Pass `listenToScope: true` to rebuild only
  /// when the [Scope] object itself is replaced. With none of them, the
  /// lookup registers no rebuild dependency at all.
  ///
  /// A watched key is a [DiKey]. A scope has no lookup for a collection key,
  /// so a collection key has no watcher.
  /// Throws a [FlutterError] when no [ScopeProvider] is above [buildContext].
  /// Use [maybeOf] when a provider is optional.
  static Scope of(
    BuildContext buildContext, {
    DiKey<Object?>? key,
    DiKey<Object?>? nodeKey,
    bool listenToScope = false,
  }) {
    final state = _stateOf(
      buildContext,
      key: key,
      nodeKey: nodeKey,
      listenToScope: listenToScope,
    );
    if (state == null) _missing();
    return state.current;
  }

  /// The current [Scope] of the closest [ScopeProvider], or null when no
  /// [ScopeProvider] is above [buildContext].
  ///
  /// The arguments are those of [of]. A call with [key], [nodeKey], or
  /// `listenToScope: true` that finds no provider rebuilds the widget when
  /// the widget moves below a provider.
  ///
  /// Use it for a widget that also works without a provider, for example
  /// with a scope that the host holds outside the widget tree:
  ///
  /// ```dart
  /// final scope = ScopeProvider.maybeOf(context) ?? fallback;
  /// ```
  static Scope? maybeOf(
    BuildContext buildContext, {
    DiKey<Object?>? key,
    DiKey<Object?>? nodeKey,
    bool listenToScope = false,
  }) => _stateOf(
    buildContext,
    key: key,
    nodeKey: nodeKey,
    listenToScope: listenToScope,
  )?.current;

  /// The state of the closest provider, with the rebuild dependencies that
  /// the arguments ask for, or null when no provider is above.
  static _ScopeProviderState? _stateOf(
    BuildContext buildContext, {
    required DiKey<Object?>? key,
    required DiKey<Object?>? nodeKey,
    required bool listenToScope,
  }) {
    if (key != null || nodeKey != null) {
      _ScopeProviderState? state;
      for (final (watched, aspect) in <(DiKey<Object?>, Object)>[
        if (nodeKey != null) (nodeKey, _NodeAspect(nodeKey)),
        if (key != null) (key, key),
      ]) {
        final model = InheritedModel.inheritFrom<_InheritedDiModel>(
          buildContext,
          aspect: aspect,
        );
        if (model == null) {
          // `inheritFrom` records nothing when it finds no model. This call
          // also finds none, and it makes the framework rebuild the widget
          // when the widget moves below a provider.
          buildContext.dependOnInheritedWidgetOfExactType<_InheritedDiModel>();
          return null;
        }
        model.state.watch(watched);
        state = model.state;
      }
      return state;
    }
    if (listenToScope) {
      return buildContext
          .dependOnInheritedWidgetOfExactType<_InheritedScope>()
          ?.state;
    }
    final identity =
        buildContext
                .getElementForInheritedWidgetOfExactType<_InheritedScope>()
                ?.widget
            as _InheritedScope?;
    return identity?.state;
  }
}

class _ScopeProviderState extends State<ScopeProvider> {
  int _version = 0;

  /// The aspects that changed since the last build: a key for a watcher of
  /// its value, and a [_NodeAspect] for a watcher of its node.
  final Set<Object> _changed = <Object>{};
  bool _notifyAll = false;

  /// The state of the node of each watched key at the last comparison, or
  /// null when no node publishes the key.
  final Map<DiKey<Object?>, NodeState?> _watched =
      <DiKey<Object?>, NodeState?>{};

  /// The frame callback of the scheduled comparison, or null.
  int? _comparison;

  /// Whether a callback after the frame moves this state to the new scope.
  bool _retargetScheduled = false;

  /// The scope whose transitions this state listens to. It is the scope that
  /// the inherited widgets compare, so a replacement notifies the dependents.
  late Scope _subscribed;

  /// The scope that a lookup reads. After a change of the listenable, the
  /// inherited widgets carry the old scope until the next build; this getter
  /// does not.
  Scope get current => widget._listenable?.value ?? widget._fixed!;

  @override
  void initState() {
    super.initState();
    widget._listenable?.addListener(_onSourceChanged);
    _subscribed = current;
    _listen();
  }

  @override
  void didUpdateWidget(covariant ScopeProvider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget._listenable, widget._listenable)) {
      oldWidget._listenable?.removeListener(_onSourceChanged);
      widget._listenable?.addListener(_onSourceChanged);
    }
    _retarget();
  }

  void _onSourceChanged() {
    if (!mounted) return;
    if (!_acceptsSetState) {
      _retargetAfterFrame();
      return;
    }
    setState(_retarget);
  }

  /// Whether the framework accepts `setState` now.
  ///
  /// The framework builds, lays out, paints, and unmounts in the persistent
  /// callbacks of a frame. A `State.dispose` runs there while the tree is
  /// locked. A build can also run outside a frame, when a host calls
  /// `BuildOwner.buildScope`, and only the debug flag of the build owner
  /// shows it. The check of `setState` is an assertion of the framework, so
  /// an assertion reads the flag.
  bool get _acceptsSetState {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      return false;
    }
    var building = false;
    assert(() {
      building = context.owner?.debugBuilding ?? false;
      return true;
    }());
    return !building;
  }

  /// Moves to the new scope after the frame that runs or that comes next.
  ///
  /// A lookup already reads the new scope. The widgets that listen rebuild in
  /// the frame after the callback.
  void _retargetAfterFrame() {
    if (_retargetScheduled) return;
    _retargetScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _retargetScheduled = false;
      if (mounted) setState(_retarget);
    });
    // A build outside a frame has no frame that runs the callback.
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  /// Listens to [_subscribed]. A scope whose disposal was requested takes no
  /// listener, and it has no transition that a watcher reads.
  void _listen() {
    if (!_subscribed.isDisposed) _subscribed.addListener(_onTransition);
  }

  /// Moves the subscription to [current] when the scope was replaced.
  void _retarget() {
    final next = current;
    if (identical(next, _subscribed)) return;
    _subscribed.removeListener(_onTransition);
    _subscribed = next;
    _version++;
    _notifyAll = true;
    _listen();
    for (final key in _watched.keys.toList()) {
      _watched[key] = _read(key);
    }
  }

  /// Starts to compare the node of [key] at each comparison.
  void watch(DiKey<Object?> key) {
    if (!_watched.containsKey(key)) _watched[key] = _read(key);
  }

  NodeState? _read(DiKey<Object?> key) {
    if (_subscribed.isDisposed) return null;
    return _subscribed.findNode<Object?>(key: key)?.state;
  }

  /// A transition of the runtime. The runtime calls a listener many times in
  /// one mutation, so the call only schedules one comparison before the next
  /// frame. A transition schedules no frame while no key was watched, because
  /// the comparison would read nothing.
  void _onTransition() {
    if (!mounted || _comparison != null || _watched.isEmpty) return;
    _comparison = SchedulerBinding.instance.scheduleFrameCallback(
      (_) => _compare(),
    );
  }

  /// Compares the node of each watched key with the state that was kept.
  void _compare() {
    _comparison = null;
    if (!mounted) return;
    // A disposed scope answers no read, so a rebuild could only throw. The
    // owner replaces the scope, and the replacement notifies each dependent.
    if (_subscribed.isDisposed) return;
    final changed = <Object>{};
    for (final key in _watched.keys.toList()) {
      final before = _watched[key];
      final next = _read(key);
      if (next == before) continue;
      _watched[key] = next;
      changed.add(_NodeAspect(key));
      // A watcher of the value reads another value only when another node
      // answers, when the node committed again, or when the value appears
      // or leaves.
      if (before?.id != next?.id ||
          before?.commits != next?.commits ||
          (before?.phase == NodePhase.active) !=
              (next?.phase == NodePhase.active)) {
        changed.add(key);
      }
    }
    if (changed.isEmpty) return;
    setState(() {
      _version++;
      _changed.addAll(changed);
    });
  }

  @override
  void dispose() {
    widget._listenable?.removeListener(_onSourceChanged);
    _subscribed.removeListener(_onTransition);
    if (_comparison case final id?) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(id);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final changedKeys = Set<Object>.of(_changed);
    final notifyAll = _notifyAll;
    _changed.clear();
    _notifyAll = false;
    // The identity publisher sits inside, so a descendant that only needs the
    // scope object rebuilds on a scope swap and on nothing else.
    return _InheritedDiModel(
      state: this,
      scope: _subscribed,
      version: _version,
      changedKeys: changedKeys,
      notifyAll: notifyAll,
      child: _InheritedScope(
        state: this,
        scope: _subscribed,
        child: widget.child,
      ),
    );
  }
}

/// Carries the scope object only. Notifies solely on identity change.
class _InheritedScope extends InheritedWidget {
  const _InheritedScope({
    required this.state,
    required this.scope,
    required super.child,
  });

  final _ScopeProviderState state;
  final Scope scope;

  @override
  bool updateShouldNotify(_InheritedScope oldWidget) =>
      scope != oldWidget.scope;
}

/// Carries per-key change notifications for `watchDi` and per-node change
/// notifications for `watchMaybeDiNode`.
class _InheritedDiModel extends InheritedModel<Object> {
  const _InheritedDiModel({
    required this.state,
    required this.scope,
    required this.version,
    required this.changedKeys,
    required this.notifyAll,
    required super.child,
  });

  final _ScopeProviderState state;
  final Scope scope;
  final int version;
  final Set<Object> changedKeys;
  final bool notifyAll;

  @override
  bool updateShouldNotify(_InheritedDiModel oldWidget) {
    return scope != oldWidget.scope || version != oldWidget.version;
  }

  @override
  bool updateShouldNotifyDependent(
    _InheritedDiModel oldWidget,
    Set<Object> dependencies,
  ) {
    if (scope != oldWidget.scope) return true;
    if (notifyAll) return true;
    return dependencies.any(changedKeys.contains);
  }
}

/// The aspect of a widget that watches the node of [key].
@immutable
class _NodeAspect {
  const _NodeAspect(this.key);

  final DiKey<Object?> key;

  @override
  bool operator ==(Object other) => other is _NodeAspect && other.key == key;

  @override
  int get hashCode => Object.hash(_NodeAspect, key);
}

Never _missing() {
  throw FlutterError(
    'No ScopeProvider found above this BuildContext. '
    'Wrap the subtree in ScopeProvider before using di/watchDi.',
  );
}
