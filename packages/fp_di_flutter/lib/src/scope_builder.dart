import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:fp_di/fp_di.dart';

import 'scope_provider.dart';

/// Builds a widget from a [ScopeSnapshot]. [child] is the `child` of the
/// [ScopeBuilder] or the [ScopeBoundary], which the builder does not build
/// again.
typedef ScopeWidgetBuilder =
    Widget Function(
      BuildContext context,
      ScopeSnapshot snapshot,
      Widget? child,
    );

/// The scope of a [ScopeBuilder] or a [ScopeBoundary] and its state at one
/// build.
///
/// The widget builds again when a transition of the runtime changes [phase]
/// or one of [nodeStates], and when `initialize` fails. A transition of a
/// child scope does not build it again.
@immutable
final class ScopeSnapshot {
  const ScopeSnapshot._({
    required this.scope,
    required this.phase,
    required this.nodeStates,
    required this.error,
    required this.stackTrace,
  });

  /// The scope that the widget publishes.
  final Scope scope;

  /// The phase of [scope] at this build. In [ScopePhase.disposeRequested],
  /// the lookups still answer while a hold delays the disposal.
  final ScopePhase phase;

  /// The state of each node of [scope] at this build, in declaration order.
  /// Empty in the phase [ScopePhase.declared]. See
  /// `ScopeState.nodeStates`.
  final List<NodeState> nodeStates;

  /// The failure of the `initialize` call that the [ScopeBuilder] made for
  /// [scope], or null.
  ///
  /// A failed `initialize` rolls the scope back to [ScopePhase.declared], so
  /// [phase] and [nodeStates] do not show the failure. A [ScopeBoundary]
  /// calls no `initialize`, so its snapshot has no error.
  final Object? error;

  /// The stack trace of [error], or null.
  final StackTrace? stackTrace;

  /// Whether [error] is not null.
  bool get hasError => error != null;
}

/// Creates a scope, publishes it, builds from its state, and disposes it.
///
/// The widget owns the scope. It calls `create` with the scope of the closest
/// [ScopeProvider], calls `initialize`, and disposes the scope when it is
/// unmounted. A replacement of the scope above makes a new scope: the widget
/// calls `create` again, publishes the new scope, and disposes the old one.
///
/// ```dart
/// ScopeBuilder(
///   create: (parent) => parent.child(module: cartModule),
///   builder: (context, snapshot, child) => switch (snapshot) {
///     ScopeSnapshot(:final error?) => ErrorView(error),
///     _ when snapshot.scope.isInitialized => child!,
///     _ => const Loading(),
///   },
///   child: const CartPage(),
/// )
/// ```
///
/// For a scope that the caller owns, use [ScopeBoundary].
///
/// Everything that [builder] returns is below the published scope, from the
/// first build. A lookup there reads the keys of the ancestors at once, and
/// the keys of the scope after their nodes activate. Show the content when
/// `snapshot.scope.isInitialized` is true, not when the phase is
/// [ScopePhase.initialized]: a hold of an ancestor can keep the scope in
/// [ScopePhase.disposeRequested] while its lookups answer, and the content
/// should stay on screen then. `isInitialized` does not mean that each node
/// is active: a node can wait for a key of an ancestor. Read such a key with
/// `watchMaybeDi` or `watchMaybeDiNode`.
///
/// In the phase [ScopePhase.disposeRequested] the lookups answer, so the
/// widget calls [builder]. In [ScopePhase.disposing] and
/// [ScopePhase.disposed] the lookups throw, so the widget calls no builder
/// and keeps no widget below it: it builds an empty widget, also for a
/// rebuild from above.
///
/// {@category Riverpod}
class ScopeBuilder extends StatefulWidget {
  /// Creates a scope with [create], initializes it, publishes it, and
  /// disposes it when this widget is unmounted.
  ///
  /// [create] receives the scope of the closest [ScopeProvider] and returns
  /// a new scope that no code initialized, usually `parent.child(module:)`.
  /// The widget calls [create] again only when the scope above is replaced.
  /// A rebuild with another [create] does not make a new scope; give the
  /// widget another `key` for that.
  ///
  /// Throws a [FlutterError] when no [ScopeProvider] is above.
  const ScopeBuilder({
    required this.create,
    required this.builder,
    this.child,
    super.key,
  });

  /// Creates the scope from the scope of the closest [ScopeProvider].
  final Scope Function(Scope parent) create;

  /// Builds the widgets below the published scope from a [ScopeSnapshot].
  final ScopeWidgetBuilder builder;

  /// A widget that [builder] receives and does not build again.
  final Widget? child;

  @override
  State<ScopeBuilder> createState() => _ScopeBuilderState();
}

/// Holds the disposal of a scope that the caller owns while it is mounted,
/// publishes the scope, and builds from its state.
///
/// At the mount the widget takes a hold of the disposal of [scope]
/// (`Scope.disposeHold`), and in `State.dispose` it closes the hold. A host
/// that disposes the scope then moves it to [ScopePhase.disposeRequested] at
/// once, and the disposal starts when the last boundary of the scope
/// unmounts. In that time the lookups answer and no activation starts, so a
/// route that exits reads live values until Flutter removes it after its exit
/// transition. A move with a `GlobalKey` keeps the hold, and a route that
/// another route covers keeps its boundary mounted and its hold open.
///
/// ```dart
/// // Each route of the session reads the session scope until it leaves.
/// ScopeBoundary(
///   scope: session,
///   builder: (context, snapshot, child) => child!,
///   child: const HomePage(),
/// )
///
/// // Logout: remove the routes, change the listenable, dispose. Do not wait
/// // for the disposal before the routes are removed: it waits for them.
/// current.value = app;
/// unawaited(session.dispose());
/// ```
///
/// The widget calls no `initialize` and no `dispose`. A boundary that mounts
/// after the disposal of its scope was requested takes no hold. The rules of
/// [ScopeBuilder] on transitions and on the phases [ScopePhase.disposing]
/// and [ScopePhase.disposed] apply to it: a disposal with `ignoreHolds`
/// leaves a mounted boundary with an empty subtree at the next frame.
///
/// {@category Riverpod}
class ScopeBoundary extends StatefulWidget {
  /// Publishes [scope] and holds its disposal while this widget is mounted.
  ///
  /// [debugLabel] names the hold in `Scope.openHolds`, in `describe`, and in
  /// the report of a slow wait. Without it, the hold has the name of the
  /// route of the widget, else `ScopeBoundary`.
  const ScopeBoundary({
    required this.scope,
    required this.builder,
    this.child,
    this.debugLabel,
    super.key,
  });

  /// The scope that the caller owns.
  final Scope scope;

  /// Builds the widgets below the published scope from a [ScopeSnapshot].
  final ScopeWidgetBuilder builder;

  /// A widget that [builder] receives and does not build again.
  final Widget? child;

  /// The label of the hold of this widget, or null.
  final String? debugLabel;

  @override
  State<ScopeBoundary> createState() => _ScopeBoundaryState();
}

/// The listening, the frame of a build, and the build of both widgets.
mixin _PublishedScope<T extends StatefulWidget> on State<T> {
  /// The scope that this widget publishes.
  Scope? _scope;

  /// The listenable of the inner provider. A change of its value reaches
  /// every lookup at once, so the old scope can be disposed after it.
  ValueNotifier<Scope>? _published;

  Object? _error;
  StackTrace? _stackTrace;

  /// The state that the last build read.
  ScopeState? _built;

  /// The frame callback of the scheduled build, or null.
  int? _frame;

  Widget? get _child;
  ScopeWidgetBuilder get _builder;

  /// Publishes [scope] and listens to its transitions.
  void _show(Scope scope) {
    _scope?.removeListener(_onTransition);
    _scope = scope;
    _error = null;
    _stackTrace = null;
    // A disposal that waits for holds still takes a listener, so a widget
    // that mounts in that time hears the start of the disposal.
    final phase = scope.state.phase;
    if (phase != ScopePhase.disposing && phase != ScopePhase.disposed) {
      scope.addListener(_onTransition);
    }
    final published = _published;
    if (published == null) {
      _published = ValueNotifier<Scope>(scope);
    } else {
      published.value = scope;
    }
  }

  /// A transition of the runtime. The runtime calls a listener inside the
  /// transition, many times in one mutation and also for the other scopes of
  /// the root, so the call only schedules one build before the next frame.
  void _onTransition() {
    if (!mounted || _frame != null) return;
    final built = _built;
    if (built != null && _sameOwnState(_scope!.state, built)) return;
    _scheduleBuild();
  }

  /// Builds again in the transient callbacks of the next frame, where
  /// `setState` is allowed.
  void _scheduleBuild() {
    if (_frame != null) return;
    _frame = SchedulerBinding.instance.scheduleFrameCallback((_) {
      _frame = null;
      if (mounted) setState(() {});
    });
  }

  void _stopWatching() {
    _scope?.removeListener(_onTransition);
    if (_frame case final id?) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = _scope!;
    final state = scope.state;
    _built = state;
    // A lookup of a scope whose disposal mutation started throws, so no
    // widget stays below this one. The framework builds this widget before
    // its descendants, so a descendant that rebuilds by itself in the same
    // frame is removed first.
    if (state.phase == ScopePhase.disposing ||
        state.phase == ScopePhase.disposed) {
      return const SizedBox.shrink();
    }
    final snapshot = ScopeSnapshot._(
      scope: scope,
      phase: state.phase,
      nodeStates: state.nodeStates,
      error: _error,
      stackTrace: _stackTrace,
    );
    return ScopeProvider.listenable(
      scope: _published!,
      // The builder gets a context below the provider, so its lookups read
      // the published scope.
      child: Builder(builder: (context) => _builder(context, snapshot, _child)),
    );
  }
}

class _ScopeBuilderState extends State<ScopeBuilder>
    with _PublishedScope<ScopeBuilder> {
  /// The scope of the closest provider when [_scope] was created.
  Scope? _parent;

  @override
  Widget? get _child => widget.child;

  @override
  ScopeWidgetBuilder get _builder => widget.builder;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final parent = ScopeProvider.of(context, listenToScope: true);
    if (identical(parent, _parent)) return;
    _parent = parent;
    final scope = widget.create(parent);
    assert(
      scope.state.phase == ScopePhase.declared,
      'The create function of a ScopeBuilder must return a new scope that '
      'no code initialized.',
    );
    final old = _scope;
    _show(scope);
    if (old != null) _release(old);
    _initialize(scope);
  }

  void _initialize(Scope scope) {
    Future<Scope>.sync(scope.initialize).then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        final shown = mounted && identical(scope, _scope);
        final canceled = error is ActivationCanceledException;
        if (shown) {
          _error = error;
          _stackTrace = stackTrace;
          _scheduleBuild();
        }
        // A canceled call of a scope that this widget disposed is expected.
        // The failures of its rollback still need a report.
        if (canceled && error.rollbackFailures.isNotEmpty) {
          _report(error, stackTrace, 'while rolling back a ScopeBuilder scope');
        } else if (!shown && !canceled) {
          _report(error, stackTrace, 'while initializing a ScopeBuilder scope');
        }
      },
    );
  }

  /// Disposes [scope] and reports the failure of the disposal.
  void _release(Scope scope) {
    unawaited(
      Future<void>.sync(scope.dispose).catchError(
        (Object error, StackTrace stackTrace) =>
            _report(error, stackTrace, 'while disposing a ScopeBuilder scope'),
      ),
    );
  }

  @override
  void dispose() {
    _stopWatching();
    if (_scope case final scope?) _release(scope);
    // The inner provider is a descendant, so it removed its listener first.
    _published?.dispose();
    super.dispose();
  }
}

class _ScopeBoundaryState extends State<ScopeBoundary>
    with _PublishedScope<ScopeBoundary> {
  DisposeHold? _hold;

  @override
  Widget? get _child => widget.child;

  @override
  ScopeWidgetBuilder get _builder => widget.builder;

  @override
  void initState() {
    super.initState();
    _show(widget.scope);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The name of the route needs the context, so the first hold is taken
    // here, still in the mount.
    _hold ??= _holdOf(widget.scope);
  }

  @override
  void didUpdateWidget(covariant ScopeBoundary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(widget.scope, oldWidget.scope)) return;
    final old = _hold;
    _hold = _holdOf(widget.scope);
    _show(widget.scope);
    // The new scope is published first, so no lookup reads the old one
    // after its disposal starts.
    old?.close();
  }

  /// A hold of [scope], or null when its disposal was requested.
  DisposeHold? _holdOf(Scope scope) {
    if (scope.isDisposed) return null;
    final label =
        widget.debugLabel ??
        ModalRoute.of(context)?.settings.name ??
        'ScopeBoundary';
    return scope.disposeHold(debugLabel: label);
  }

  @override
  void dispose() {
    _stopWatching();
    // `State.dispose`, not `deactivate`, so a move with a `GlobalKey` keeps
    // the hold.
    _hold?.close();
    _published?.dispose();
    super.dispose();
  }
}

/// Whether [a] and [b] have the same phase and the same state of each node.
/// The states of child scopes do not count.
bool _sameOwnState(ScopeState a, ScopeState b) =>
    identical(a, b) ||
    (a.phase == b.phase && listEquals(a.nodeStates, b.nodeStates));

void _report(Object error, StackTrace stackTrace, String context) {
  FlutterError.reportError(
    FlutterErrorDetails(
      exception: error,
      stack: stackTrace,
      library: 'fp_di_flutter',
      context: ErrorDescription(context),
    ),
  );
}
