// Random histories of the adapter (V-T-AR-UI-011).
//
// A history mixes the lifecycles that meet in the adapter: the frames of
// Flutter, the mounting of widgets and of routes, the replacement of the
// published scope, and the transitions of the runtime. Each history follows
// the host rule of the architecture spec, and four checks run after each
// step:
//
// - NoFailedRead: no build and no lookup throws.
// - WatcherCurrent: each mounted watcher shows the value of its scope.
// - NoRebuildForDisposal: the disposal of another scope rebuilds no watcher.
// - NoWorkAfterUnmount: an unmounted provider schedules no frame.
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
}

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

  late final Scope app;
  late final ValueNotifier<Scope> current;
  Scope? session;
  bool withdrawn = false;
  int sessions = 0;
  int pages = 0;
  int depth = 0;
  BuildContext? plain;
  VoidCallback? onLeave;

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

  Future<void> login() async {
    final session = world.app.child(
      module: Module(
        components: [
          Component.value(value: ++world.sessions, key: _k),
          Component.value(value: 'm${world.sessions}', key: _m),
        ],
      ),
    );
    await session.initialize();
    world
      ..session = session
      ..withdrawn = false;
    world.current.value = session;
  }

  Future<void> logout() async {
    final session = world.session!;
    world.session = null;
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
      if (session != null) ('logout', logout),
      if (session != null && !world.withdrawn)
        (
          'withdraw a member',
          () async {
            world.withdrawn = true;
            await session.node<int>(key: _k).dispose();
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
            world.withdrawn = true;
            await session.node<int>(key: _k).dispose();
          }
          await frames();
          for (final MapEntry(:key, :value) in builds.entries) {
            if (world.of(key).builds != value) {
              report('NoRebuildForDisposal', '$key rebuilt');
            }
          }
        },
      ),
      if (world.depth < 2)
        (
          'push a page',
          () async {
            world.depth++;
            final id = ++world.pages;
            unawaited(
              world.navigator.currentState!.push(
                MaterialPageRoute<void>(
                  builder: (_) => _Page(world: world, id: id),
                ),
              ),
            );
          },
        ),
      if (world.depth > 0)
        (
          'pop a page',
          () async {
            world.depth--;
            world.navigator.currentState!.pop();
          },
        ),
      (
        'mount or unmount a watcher',
        () async => world.extraWatcher.value = !world.extraWatcher.value,
      ),
      if (!world.leaving.value)
        ('mount the leaving widget', () async => world.leaving.value = true),
      if (session != null && world.leaving.value)
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
  await world.session?.dispose();
  await world.app.dispose();
  world.current.dispose();
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
