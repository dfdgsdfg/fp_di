import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:fp_di/fp_di.dart';

import 'scope_provider.dart';

/// Builds a widget from a [ScopeSnapshot]. [child] is the `child` of the
/// [ScopeBuilder], which the builder does not build again.
typedef ScopeWidgetBuilder =
    Widget Function(
      BuildContext context,
      ScopeSnapshot snapshot,
      Widget? child,
    );

/// The scope of a [ScopeBuilder] and its state at one build.
///
/// A [ScopeBuilder] builds again when a transition of the runtime changes
/// [phase] or one of [nodeStates], and when `initialize` fails. A transition
/// of a child scope does not build it again.
@immutable
final class ScopeSnapshot {
  const ScopeSnapshot._({
    required this.scope,
    required this.phase,
    required this.nodeStates,
    required this.error,
    required this.stackTrace,
  });

  /// The scope that the [ScopeBuilder] publishes.
  final Scope scope;

  /// The phase of [scope] at this build.
  final ScopePhase phase;

  /// The state of each node of [scope] at this build, in declaration order.
  /// Empty in the phase [ScopePhase.declared]. See
  /// `ScopeState.nodeStates`.
  final List<NodeState> nodeStates;

  /// The failure of the `initialize` call that the [ScopeBuilder] made for
  /// [scope], or null.
  ///
  /// A failed `initialize` rolls the scope back to [ScopePhase.declared], so
  /// [phase] and [nodeStates] do not show the failure. [ScopeBuilder.value]
  /// calls no `initialize`, so its snapshot has no error.
  final Object? error;

  /// The stack trace of [error], or null.
  final StackTrace? stackTrace;

  /// Whether [error] is not null.
  bool get hasError => error != null;
}

/// Publishes a scope and builds from its state.
///
/// With the unnamed constructor, the widget owns the scope. It calls
/// `create` with the scope of the closest [ScopeProvider], calls
/// `initialize`, and disposes the scope when it is unmounted. A replacement
/// of the scope above makes a new scope: the widget calls `create` again,
/// publishes the new scope, and disposes the old one.
///
/// ```dart
/// ScopeBuilder(
///   create: (parent) => parent.child(module: cartModule),
///   builder: (context, snapshot, child) => switch (snapshot) {
///     ScopeSnapshot(:final error?) => ErrorView(error),
///     ScopeSnapshot(phase: ScopePhase.initialized) => child!,
///     _ => const Loading(),
///   },
///   child: const CartPage(),
/// )
/// ```
///
/// [ScopeBuilder.value] publishes a scope that the caller owns, and builds
/// from its state. It does not call `initialize` or `dispose`.
///
/// Everything that [builder] returns is below the published scope, from the
/// first build. A lookup there reads the keys of the ancestors at once, and
/// the keys of the scope after their nodes activate. The phase
/// [ScopePhase.initialized] does not mean that each node is active: a node
/// can wait for a key of an ancestor. Read such a key with `watchMaybeDi`
/// or `watchMaybeDiNode`.
///
/// While `isDisposed` of the scope is true, the widget does not call
/// [builder], because a lookup of a disposed scope throws. A rebuild from
/// above keeps the widgets of the last build.
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
    required Scope Function(Scope parent) create,
    required this.builder,
    this.child,
    super.key,
  }) : _create = create,
       _value = null;

  /// Publishes [scope], which the caller owns, and builds from its state.
  ///
  /// The widget does not call `initialize` or `dispose`. Use it for a scope
  /// that is not disposed while this widget is mounted, as for
  /// [ScopeProvider.fixed]. A rebuild with another [scope] publishes that
  /// scope at once.
  const ScopeBuilder.value({
    required Scope scope,
    required this.builder,
    this.child,
    super.key,
  }) : _create = null,
       _value = scope;

  final Scope Function(Scope parent)? _create;
  final Scope? _value;

  /// Builds the widgets below the published scope from a [ScopeSnapshot].
  final ScopeWidgetBuilder builder;

  /// A widget that [builder] receives and does not build again.
  final Widget? child;

  @override
  State<ScopeBuilder> createState() => _ScopeBuilderState();
}

class _ScopeBuilderState extends State<ScopeBuilder> {
  /// The scope of the closest provider when [_scope] was created.
  Scope? _parent;

  /// The scope that this widget publishes.
  Scope? _scope;

  /// The listenable of the inner provider. A change of its value reaches
  /// every lookup at once, so the old scope can be disposed after it.
  ValueNotifier<Scope>? _published;

  Object? _error;
  StackTrace? _stackTrace;

  /// The state that the last build read.
  ScopeState? _built;

  /// The widget that the last build returned.
  Widget? _output;

  /// The frame callback of the scheduled build, or null.
  int? _frame;

  bool get _owns => widget._create != null;

  @override
  void initState() {
    super.initState();
    if (widget._value case final scope?) _show(scope);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final create = widget._create;
    if (create == null) return;
    final parent = ScopeProvider.of(context, listenToScope: true);
    if (identical(parent, _parent)) return;
    _parent = parent;
    final scope = create(parent);
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

  @override
  void didUpdateWidget(covariant ScopeBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    assert(
      (oldWidget._create == null) == (widget._create == null),
      'A ScopeBuilder cannot change between its two constructors. Give it '
      'another key.',
    );
    if (widget._value case final scope? when !identical(scope, _scope)) {
      _show(scope);
    }
  }

  /// Publishes [scope] and listens to its transitions.
  void _show(Scope scope) {
    _scope?.removeListener(_onTransition);
    _scope = scope;
    _error = null;
    _stackTrace = null;
    if (!scope.isDisposed) scope.addListener(_onTransition);
    final published = _published;
    if (published == null) {
      _published = ValueNotifier<Scope>(scope);
    } else {
      published.value = scope;
    }
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

  /// A transition of the runtime. The runtime calls a listener inside the
  /// transition, many times in one mutation and also for the other scopes of
  /// the root, so the call only schedules one build before the next frame.
  void _onTransition() {
    if (!mounted || _frame != null) return;
    final scope = _scope!;
    if (scope.isDisposed) return;
    final built = _built;
    if (built != null && _sameOwnState(scope.state, built)) return;
    _scheduleBuild();
  }

  /// Builds again in the transient callbacks of the next frame, where
  /// `setState` is allowed.
  void _scheduleBuild() {
    if (_frame != null) return;
    _frame = SchedulerBinding.instance.scheduleFrameCallback((_) {
      _frame = null;
      if (!mounted || _scope!.isDisposed) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _scope?.removeListener(_onTransition);
    if (_frame case final id?) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(id);
    }
    if (_owns && _scope != null) _release(_scope!);
    // The inner provider is a descendant, so it removed its listener first.
    _published?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = _scope!;
    // The same widget object makes the framework skip the subtree, so no
    // widget below reads the disposed scope.
    if (scope.isDisposed && _output != null) return _output!;
    final state = scope.state;
    _built = state;
    final snapshot = ScopeSnapshot._(
      scope: scope,
      phase: state.phase,
      nodeStates: state.nodeStates,
      error: _error,
      stackTrace: _stackTrace,
    );
    return _output = ScopeProvider.listenable(
      scope: _published!,
      // The builder gets a context below the provider, so its lookups read
      // the published scope.
      child: Builder(
        builder: (context) => widget.builder(context, snapshot, widget.child),
      ),
    );
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
