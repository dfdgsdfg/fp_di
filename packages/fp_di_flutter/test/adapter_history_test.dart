// Random histories of the adapter (V-T-AR-UI-011).
//
// A history mixes the lifecycles that meet in the adapter: the frames of
// Flutter, the mounting of widgets and of routes, the replacement of the
// published scope, and the transitions of the runtime. Each history follows
// the host rule of the architecture spec, and five checks run after each
// step:
//
// - NoFailedRead: no build and no lookup throws.
// - WatcherCurrent: each mounted watcher shows the value of its scope.
// - NoRebuildForDisposal: the disposal of another scope rebuilds no watcher.
// - NoWorkAfterUnmount: an unmounted provider schedules no frame.
// - NoReleaseBeforeUnmount: no member of a session is released while a
//   `ScopeBoundary` of the session is mounted, unless a call ignored the
//   holds. After such a call, the boundary keeps no widget below it.
//
// The harness observes a release from the dispose function of each session
// member, and a mounted boundary from the content widget below it: the
// content counts itself in `State.initState` and `State.dispose`, and a
// `GlobalKey` move keeps the count. The host rule for routes (rule 6) puts
// the routes of a session below a boundary: a logout never waits for the
// `dispose` future before it removes the routes.
//
// A control gives the harness one defect and expects its check to report.
// The defects are in this file. The adapter has no fault hook.

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fp_di/fp_di.dart';
import 'package:fp_di_flutter/fp_di_flutter.dart';

/// The app scope publishes 0, and each session scope publishes its number.
const _k = DiKey<int>(name: 'k');

/// Only a session scope publishes this key.
const _m = DiKey<String>(name: 'm');

/// Only the scope of a page publishes this key.
const _p = DiKey<int>(name: 'p');

/// One defect of the harness for a control.
enum _Defect {
  none,

  /// The watcher of `_k` reads with the lookup that does not listen.
  staleWatcher,

  /// A logout disposes the session scope before it changes the listenable.
  disposeBeforeSwap,

  /// The step that disposes another scope also withdraws a watched key.
  noisyDisposal,

  /// The history ends with the provider mounted.
  noUnmount,

  /// A route of the session is below a fixed provider, not a boundary, so
  /// the disposal does not wait for the route.
  routeWithoutBoundary,
}

/// A boundary that a `GlobalKey` moves between two parents.
typedef _Movable = ({Scope scope, int id, int slot});

/// What one watching widget showed at its last build.
final class _Seen {
  int builds = 0;
  bool mounted = false;
  Object? value;
  Scope? scope;
}

/// The state of one history.
final class _World {
  _World(this.defect);

  final _Defect defect;
  final violations = <String>[];
  final seen = <String, _Seen>{};
  final navigator = GlobalKey<NavigatorState>();
  final leaving = ValueNotifier<bool>(true);
  final extraWatcher = ValueNotifier<bool>(false);

  final boundaryKey = GlobalKey();
  final movable = ValueNotifier<_Movable?>(null);

  /// The routes above the home route: the number of the session that a route
  /// reads, or null for a page.
  final stack = <int?>[];

  /// The content widgets that are mounted, by number of session.
  final mounted = <int, int>{};

  /// The sessions that a call disposed with `ignoreHolds`.
  final ignored = <int>{};

  /// The scope of each session, by number.
  final scopes = <int, Scope>{};

  /// The disposals that no step awaited, with their completion.
  final disposals = <Future<void>>[];
  int disposed = 0;

  late final Scope app;
  late final ValueNotifier<Scope> current;
  late final void Function(String check, String detail) report;
  Scope? session;
  int sessionId = 0;
  bool withdrawn = false;

  /// True while a step withdraws a member: that release is not a disposal.
  bool withdrawing = false;
  int sessions = 0;
  int pages = 0;
  int contents = 0;
  BuildContext? plain;
  VoidCallback? onLeave;

  /// NoReleaseBeforeUnmount: a member of session [id] is released.
  void released(int id, String member) {
    if (withdrawing || ignored.contains(id)) return;
    final content = mounted[id] ?? 0;
    final holds = scopes[id]?.openHolds.length ?? 0;
    if (content > 0 || holds > 0) {
      report(
        'NoReleaseBeforeUnmount',
        'session $id released $member with $content contents and $holds '
            'holds',
      );
    }
  }

  /// True while a route, a pushed route that exits, or a movable boundary
  /// of session [id] is mounted or about to mount.
  bool hasBoundary(int id) =>
      stack.contains(id) ||
      movable.value?.id == id ||
      (mounted[id] ?? 0) > 0 ||
      (scopes[id]?.openHolds.isNotEmpty ?? false);

  _Seen of(String name) => seen.putIfAbsent(name, _Seen.new);
}

/// Records each build of [builder] in the entry [name] of the world.
class _Watcher extends StatefulWidget {
  const _Watcher({
    required this.world,
    required this.name,
    required this.builder,
  });

  final _World world;
  final String name;
  final (Object? value, Scope scope) Function(BuildContext context) builder;

  @override
  State<_Watcher> createState() => _WatcherState();
}

class _WatcherState extends State<_Watcher> {
  @override
  void initState() {
    super.initState();
    widget.world.of(widget.name).mounted = true;
  }

  @override
  void dispose() {
    widget.world.of(widget.name).mounted = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (value, scope) = widget.builder(context);
    widget.world.of(widget.name)
      ..builds += 1
      ..value = value
      ..scope = scope;
    return const SizedBox();
  }
}

/// The content below a boundary, or below a fixed provider for the defect. It
/// reads a session key with a strict read and also watches the key.
class _Content extends StatefulWidget {
  const _Content({required this.world, required this.id});

  final _World world;
  final int id;

  @override
  State<_Content> createState() => _ContentState();
}

class _ContentState extends State<_Content> {
  @override
  void initState() {
    super.initState();
    final mounted = widget.world.mounted;
    mounted[widget.id] = (mounted[widget.id] ?? 0) + 1;
  }

  @override
  void dispose() {
    final mounted = widget.world.mounted;
    mounted[widget.id] = (mounted[widget.id] ?? 1) - 1;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strict = context.di<String>(key: _m);
    final watched = context.watchDi<String>(key: _m);
    final expected = 'm${widget.id}';
    if (strict != expected || watched != expected) {
      widget.world.report(
        'WatcherCurrent',
        'a boundary content shows $strict and $watched, not $expected',
      );
    }
    return const SizedBox();
  }
}

/// A route of the session: a boundary of the scope, or a fixed provider for
/// the defect of the harness.
Widget _sessionRoute(_World world, Scope scope, int id) {
  final content = _Content(world: world, id: id);
  if (world.defect == _Defect.routeWithoutBoundary) {
    return ScopeProvider.fixed(scope: scope, child: content);
  }
  return ScopeBoundary(
    scope: scope,
    debugLabel: 'route of session $id',
    builder: (context, snapshot, child) => content,
  );
}

/// Calls the `onLeave` of the world from `State.dispose`, while the framework
/// has locked the tree.
class _Leaving extends StatefulWidget {
  const _Leaving({required this.world});

  final _World world;

  @override
  State<_Leaving> createState() => _LeavingState();
}

class _LeavingState extends State<_Leaving> {
  @override
  void dispose() {
    widget.world.onLeave?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

/// A page that owns a scope, as the host rule states: the `State` creates a
/// child of the ambient scope and disposes it in `State.dispose`.
class _Page extends StatefulWidget {
  const _Page({required this.world, required this.id});

  final _World world;
  final int id;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  Scope? _parent;
  Scope? _scope;
  Future<Scope>? _ready;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final parent = ScopeProvider.of(context, listenToScope: true);
    if (identical(parent, _parent)) return;
    _parent = parent;
    _close();
    final scope = parent.child(
      module: Module(
        components: [Component.value(value: widget.id, key: _p)],
      ),
    );
    _scope = scope;
    _ready = scope.initialize()..ignore();
  }

  void _close() {
    final scope = _scope;
    if (scope == null) return;
    _scope = null;
    unawaited(
      scope.dispose().catchError((Object error) {
        widget.world.violations.add('NoFailedRead page dispose: $error');
      }),
    );
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Scope>(
      future: _ready,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done ||
            snapshot.hasError) {
          return const SizedBox();
        }
        final scope = snapshot.requireData;
        return ScopeProvider.fixed(
          scope: scope,
          child: _Watcher(
            world: widget.world,
            name: 'page${widget.id}',
            builder: (context) => (
              (
                context.watchMaybeDi<int>(key: _p),
                context.watchMaybeDi<int>(key: _k),
              ),
              scope,
            ),
          ),
        );
      },
    );
  }
}

/// The widgets below the root provider.
class _Base extends StatelessWidget {
  const _Base({required this.world});

  final _World world;

  @override
  Widget build(BuildContext context) {
    final stale = world.defect == _Defect.staleWatcher;
    Widget kWatcher(String name) => _Watcher(
      world: world,
      name: name,
      builder: (context) => (
        stale
            ? context.maybeDi<int>(key: _k)
            : context.watchMaybeDi<int>(key: _k),
        ScopeProvider.of(context),
      ),
    );
    return Column(
      children: [
        Builder(
          builder: (context) {
            world.plain = context;
            return const SizedBox();
          },
        ),
        kWatcher('k'),
        _Watcher(
          world: world,
          name: 'node',
          builder: (context) => (
            context.watchMaybeDiNode<String>(key: _m)?.state.phase,
            ScopeProvider.of(context),
          ),
        ),
        _Watcher(
          world: world,
          name: 'scope',
          builder: (context) {
            final scope = ScopeProvider.of(context, listenToScope: true);
            return (scope, scope);
          },
        ),
        ValueListenableBuilder<bool>(
          valueListenable: world.extraWatcher,
          builder: (context, shown, _) =>
              shown ? kWatcher('k2') : const SizedBox(),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: world.leaving,
          builder: (context, shown, _) =>
              shown ? _Leaving(world: world) : const SizedBox(),
        ),
        ValueListenableBuilder<_Movable?>(
          valueListenable: world.movable,
          builder: (context, movable, _) {
            // One boundary with a `GlobalKey` under one of two parents.
            final boundary = movable == null
                ? null
                : ScopeBoundary(
                    key: world.boundaryKey,
                    scope: movable.scope,
                    debugLabel: 'movable of session ${movable.id}',
                    builder: (context, snapshot, child) =>
                        _Content(world: world, id: movable.id),
                  );
            return Column(
              children: [
                Padding(
                  padding: EdgeInsets.zero,
                  child: movable?.slot == 0 ? boundary : null,
                ),
                Align(child: movable?.slot == 1 ? boundary : null),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// Runs one history and returns the violations that the checks reported.
Future<List<String>> _run(
  WidgetTester tester, {
  required int seed,
  required int steps,
  _Defect defect = _Defect.none,
  Map<String, int>? tally,
}) async {
  final random = Random(seed);
  final world = _World(defect);
  world.app = Scope(
    module: Module(components: [Component.value(value: 0, key: _k)]),
  );
  await world.app.initialize();
  world.current = ValueNotifier<Scope>(world.app);
  var step = -1;
  var name = 'mount';

  void report(String check, String detail) {
    world.violations.add('$check seed=$seed step=$step ($name): $detail');
  }

  world.report = report;

  void takeException() {
    final exception = tester.takeException();
    if (exception != null) {
      report('NoFailedRead', '$exception'.split('\n').first);
    }
  }

  /// Runs the frames that the step asked for. A route transition asks for a
  /// frame after each frame, so the loop has a bound.
  Future<void> frames() async {
    for (var i = 0; i < 4; i++) {
      await tester.pump();
      takeException();
      if (!tester.binding.hasScheduledFrame) return;
    }
  }

  /// NoFailedRead for a lookup, and WatcherCurrent for each mounted watcher.
  void check() {
    final current = world.current.value;
    final plain = world.plain;
    if (plain != null && plain.mounted) {
      try {
        plain.maybeDi<int>(key: _k);
      } on Object catch (error) {
        report('NoFailedRead', 'a lookup threw ${error.runtimeType}');
      }
    }
    // NoReleaseBeforeUnmount: after a call that ignored the holds, the next
    // frame leaves no boundary content of that session.
    for (final id in world.ignored) {
      final content = world.mounted[id] ?? 0;
      if (content != 0) {
        report('NoReleaseBeforeUnmount', 'session $id keeps $content contents');
      }
    }
    if (current.isDisposed) return;
    for (final name in ['k', 'k2']) {
      final seen = world.of(name);
      if (!seen.mounted) continue;
      final expected = current.maybeGet<int>(key: _k);
      if (seen.value != expected) {
        report('WatcherCurrent', '$name shows ${seen.value}, not $expected');
      }
    }
    final node = world.of('node');
    final phase = current.findNode<String>(key: _m)?.state.phase;
    if (node.mounted && node.value != phase) {
      report('WatcherCurrent', 'node shows ${node.value}, not $phase');
    }
    final scope = world.of('scope');
    if (scope.mounted && !identical(scope.value, current)) {
      report('WatcherCurrent', 'a widget listens to a replaced scope');
    }
    for (final entry in world.seen.entries) {
      if (!entry.key.startsWith('page')) continue;
      final seen = entry.value;
      final own = seen.scope;
      if (!seen.mounted || own == null || own.isDisposed) continue;
      final expected = (own.maybeGet<int>(key: _p), own.maybeGet<int>(key: _k));
      if (seen.value != expected) {
        report(
          'WatcherCurrent',
          '${entry.key} shows ${seen.value}, not $expected',
        );
      }
    }
  }

  await tester.pumpWidget(
    ScopeProvider.listenable(
      scope: world.current,
      child: MaterialApp(
        navigatorKey: world.navigator,
        home: Material(child: _Base(world: world)),
      ),
    ),
  );
  takeException();
  check();

  /// A member of a session whose release the harness logs.
  Component<T> member<T>(int id, DiKey<T> key, T value) => Component<T>(
    dependency: Dependency<T>(
      create: () => value,
      dispose: (_) => world.released(id, '${key.name}'),
    ),
    key: key,
  );

  Future<void> login() async {
    final id = ++world.sessions;
    final session = world.app.child(
      module: Module(components: [member(id, _k, id), member(id, _m, 'm$id')]),
    );
    await session.initialize();
    world
      ..session = session
      ..sessionId = id
      ..withdrawn = false;
    world.scopes[id] = session;
    // A boundary of an earlier session that a disposal ignored stays mounted.
    world.movable.value = null;
    world.current.value = session;
  }

  /// A disposal that no step awaits: the holds of the boundaries delay it
  /// until the routes unmount.
  void startDisposal(Scope scope, {bool ignoreHolds = false}) {
    world.disposals.add(
      scope
          .dispose(ignoreHolds: ignoreHolds)
          .catchError((Object error) {
            report('NoFailedRead', 'session dispose: $error');
          })
          .whenComplete(() => world.disposed++),
    );
  }

  /// Pops the routes down to the lowest route of session [id]. Each route
  /// then exits with a transition over the next frames.
  void popRoutesOf(int id) {
    while (world.stack.contains(id)) {
      world.stack.removeLast();
      world.navigator.currentState!.pop();
    }
  }

  Future<void> logout() async {
    final session = world.session!;
    world
      ..session = null
      ..movable.value = null;
    if (defect == _Defect.disposeBeforeSwap) {
      await session.dispose();
      check();
      world.current.value = world.app;
      return;
    }
    // The host rule: change the value first.
    world.current.value = world.app;
    await session.dispose();
  }

  for (step = 0; step < steps; step++) {
    final session = world.session;
    final id = world.sessionId;
    final bounded = session != null && world.hasBoundary(id);
    final choices = <(String, Future<void> Function())>[
      ('frame', () async {}),
      (
        'part of a transition',
        () async {
          await tester.pump(const Duration(milliseconds: 80));
          takeException();
        },
      ),
      if (session == null) ('login', login),
      if (session != null && !bounded) ('logout', logout),
      if (session != null && bounded)
        (
          'logout with boundary routes',
          () async {
            // The host rule: change the value, request the disposal without
            // waiting, and remove the routes of the session.
            world
              ..session = null
              ..movable.value = null;
            world.current.value = world.app;
            startDisposal(session);
            popRoutesOf(id);
          },
        ),
      if (session != null && bounded)
        (
          'dispose that ignores the holds',
          () async {
            world
              ..session = null
              ..current.value = world.app;
            popRoutesOf(id);
            // The disposal comes in the middle of the exit transitions.
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 80));
            takeException();
            world.ignored.add(id);
            await session.dispose(ignoreHolds: true);
          },
        ),
      if (session != null && world.movable.value == null)
        (
          'mount a movable boundary',
          () async => world.movable.value = (scope: session, id: id, slot: 0),
        ),
      if (world.movable.value case final movable?)
        (
          'move a boundary',
          () async => world.movable.value = (
            scope: movable.scope,
            id: movable.id,
            slot: 1 - movable.slot,
          ),
        ),
      if (session != null && !world.withdrawn)
        (
          'withdraw a member',
          () async {
            world
              ..withdrawn = true
              ..withdrawing = true;
            await session.node<int>(key: _k).dispose();
            world.withdrawing = false;
          },
        ),
      (
        'dispose another scope',
        () async {
          final builds = {
            for (final name in ['k', 'k2', 'node', 'scope'])
              name: world.of(name).builds,
          };
          final other = world.app.child(
            module: Module(components: [Component.value(value: -1, key: _p)]),
          );
          await other.initialize();
          await other.dispose();
          if (defect == _Defect.noisyDisposal &&
              session != null &&
              !world.withdrawn) {
            world
              ..withdrawn = true
              ..withdrawing = true;
            await session.node<int>(key: _k).dispose();
            world.withdrawing = false;
          }
          await frames();
          for (final MapEntry(:key, :value) in builds.entries) {
            if (world.of(key).builds != value) {
              report('NoRebuildForDisposal', '$key rebuilt');
            }
          }
        },
      ),
      if (world.stack.length < 3)
        (
          'push a page',
          () async {
            world.stack.add(null);
            final page = ++world.pages;
            unawaited(
              world.navigator.currentState!.push(
                MaterialPageRoute<void>(
                  builder: (_) => _Page(world: world, id: page),
                ),
              ),
            );
          },
        ),
      if (session != null && world.stack.length < 3)
        (
          'push a route below a boundary',
          () async {
            world.stack.add(id);
            unawaited(
              world.navigator.currentState!.push(
                MaterialPageRoute<void>(
                  builder: (_) => _sessionRoute(world, session, id),
                ),
              ),
            );
          },
        ),
      if (world.stack.isNotEmpty)
        (
          'pop a page',
          () async {
            world.stack.removeLast();
            world.navigator.currentState!.pop();
          },
        ),
      (
        'mount or unmount a watcher',
        () async => world.extraWatcher.value = !world.extraWatcher.value,
      ),
      if (!world.leaving.value)
        ('mount the leaving widget', () async => world.leaving.value = true),
      if (session != null && !bounded && world.leaving.value)
        (
          'logout from State.dispose',
          () async {
            // The replacement runs while the framework has locked the tree.
            world.onLeave = () => world.current.value = world.app;
            world.session = null;
            world.leaving.value = false;
            await tester.pump();
            takeException();
            world.onLeave = null;
            await session.dispose();
          },
        ),
    ];
    final (label, action) = choices[random.nextInt(choices.length)];
    name = label;
    tally?.update(label, (count) => count + 1, ifAbsent: () => 1);
    await action();
    await frames();
    check();
  }

  name = 'unmount';
  if (defect != _Defect.noUnmount) {
    await tester.pumpWidget(const SizedBox());
    takeException();
  }
  await frames();
  // A transition after the unmount: the creation of a child scope.
  final scheduled = tester.binding.hasScheduledFrame;
  final probe = world.app.child();
  if (!scheduled && tester.binding.hasScheduledFrame) {
    report('NoWorkAfterUnmount', 'a transition scheduled a frame');
  }
  await probe.dispose();
  await tester.pumpWidget(const SizedBox());
  takeException();
  // The unmount of the routes closes each hold, so each disposal completes.
  for (var i = 0; i < 5 && world.disposed < world.disposals.length; i++) {
    await tester.pump();
  }
  if (world.disposed < world.disposals.length) {
    report('NoFailedRead', 'a disposal waits for a hold after the unmount');
  }
  await world.session?.dispose();
  await world.app.dispose();
  world.current.dispose();
  world.movable.dispose();
  world.leaving.dispose();
  world.extraWatcher.dispose();
  return world.violations;
}

/// Each kind of step that a history can take.
const _stepKinds = [
  'frame',
  'part of a transition',
  'login',
  'logout',
  'withdraw a member',
  'dispose another scope',
  'push a page',
  'pop a page',
  'mount or unmount a watcher',
  'mount the leaving widget',
  'logout from State.dispose',
  'push a route below a boundary',
  'logout with boundary routes',
  'dispose that ignores the holds',
  'mount a movable boundary',
  'move a boundary',
];

/// The checks that [violations] name.
Set<String> _checks(List<String> violations) => {
  for (final violation in violations) violation.split(' ').first,
};

void main() {
  const histories = 40;
  const steps = 40;

  testWidgets('random histories that follow the host rule report nothing', (
    tester,
  ) async {
    final violations = <String>[];
    final tally = <String, int>{};
    for (var seed = 0; seed < histories; seed++) {
      violations.addAll(
        await _run(tester, seed: seed, steps: steps, tally: tally),
      );
    }
    expect(violations, isEmpty, reason: violations.take(5).join('\n'));
    // Each kind of step ran, so the result is about the whole mix.
    expect(tally.keys, containsAll(_stepKinds), reason: '$tally');
  });

  for (final (defect, check) in [
    (_Defect.staleWatcher, 'WatcherCurrent'),
    (_Defect.disposeBeforeSwap, 'NoFailedRead'),
    (_Defect.noisyDisposal, 'NoRebuildForDisposal'),
    (_Defect.noUnmount, 'NoWorkAfterUnmount'),
    (_Defect.routeWithoutBoundary, 'NoReleaseBeforeUnmount'),
  ]) {
    testWidgets('the control ${defect.name} reports $check', (tester) async {
      final violations = <String>[];
      const seeds = 10;
      for (var seed = 0; seed < seeds; seed++) {
        violations.addAll(
          await _run(tester, seed: seed, steps: steps, defect: defect),
        );
      }
      expect(
        _checks(violations),
        contains(check),
        reason:
            'the defect ${defect.name} over the seeds 0 to ${seeds - 1} '
            'reported only ${_checks(violations)}',
      );
    });
  }
}
