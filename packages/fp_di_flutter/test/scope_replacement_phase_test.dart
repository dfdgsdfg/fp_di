// A replacement of the scope while the widget tree is locked or builds, and
// the frame that a transition of the runtime schedules (R-UC-AR-UI-005).
//
// `State.dispose` runs while the framework has locked the tree, and a build
// of a descendant runs while the framework builds. `setState` is not allowed
// in either moment, so the provider moves to the new scope after the frame.
// A build can also run outside a frame, when a host calls
// `BuildOwner.buildScope`.

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fp_di/fp_di.dart';
import 'package:fp_di_flutter/fp_di_flutter.dart';

const _count = DiKey<int>(name: 'count');

/// An app scope with the count 1 and a session scope with the count 2.
Future<(Scope, Scope)> _scopes() async {
  final app = Scope(
    module: Module(components: [Component.value(value: 1, key: _count)]),
  );
  await app.initialize();
  final session = app.child(
    module: Module(components: [Component.value(value: 2, key: _count)]),
  );
  await session.initialize();
  return (app, session);
}

/// Calls [onDispose] from `State.dispose`.
class _Leaving extends StatefulWidget {
  const _Leaving({required this.onDispose});

  final VoidCallback onDispose;

  @override
  State<_Leaving> createState() => _LeavingState();
}

class _LeavingState extends State<_Leaving> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  testWidgets('a replacement from State.dispose reaches the next frame', (
    tester,
  ) async {
    final (app, session) = await _scopes();
    final current = ValueNotifier<Scope>(session);
    final shown = ValueNotifier<bool>(true);
    late BuildContext plain;
    var scopeBuilds = 0;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ScopeProvider.listenable(
          scope: current,
          child: Column(
            children: [
              Builder(
                builder: (context) {
                  plain = context;
                  return const SizedBox();
                },
              ),
              Builder(
                builder: (context) =>
                    Text('watch:${context.watchDi<int>(key: _count)}'),
              ),
              Builder(
                builder: (context) {
                  scopeBuilds++;
                  ScopeProvider.of(context, listenToScope: true);
                  return const SizedBox();
                },
              ),
              ValueListenableBuilder<bool>(
                valueListenable: shown,
                builder: (context, value, _) => value
                    ? _Leaving(onDispose: () => current.value = app)
                    : const SizedBox(),
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('watch:2'), findsOneWidget);
    expect(scopeBuilds, 1);

    // The framework unmounts the widget in this frame and calls its
    // `State.dispose` while the tree is locked.
    shown.value = false;
    await tester.pump();
    expect(tester.takeException(), isNull);
    // A lookup reads the new scope at once, and the provider asks for the
    // frame that moves the widgets.
    expect(plain.di<int>(key: _count), 1);
    expect(tester.binding.hasScheduledFrame, isTrue);

    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('watch:1'), findsOneWidget);
    expect(scopeBuilds, 2);
    expect(tester.binding.hasScheduledFrame, isFalse);

    await tester.pumpWidget(const SizedBox());
    current.dispose();
    shown.dispose();
    await app.dispose();
  });

  testWidgets('a replacement from a build inside a frame reaches the next '
      'frame', (tester) async {
    final (app, session) = await _scopes();
    final current = ValueNotifier<Scope>(session);
    final replace = ValueNotifier<bool>(false);
    late BuildContext plain;
    var scopeBuilds = 0;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ScopeProvider.listenable(
          scope: current,
          child: Column(
            children: [
              Builder(
                builder: (context) {
                  plain = context;
                  return const SizedBox();
                },
              ),
              Builder(
                builder: (context) =>
                    Text('watch:${context.watchDi<int>(key: _count)}'),
              ),
              Builder(
                builder: (context) {
                  scopeBuilds++;
                  ScopeProvider.of(context, listenToScope: true);
                  return const SizedBox();
                },
              ),
              ValueListenableBuilder<bool>(
                valueListenable: replace,
                builder: (context, value, _) {
                  // A build of a descendant replaces the scope.
                  if (value) current.value = app;
                  return const SizedBox();
                },
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('watch:2'), findsOneWidget);

    replace.value = true;
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(plain.di<int>(key: _count), 1);
    expect(tester.binding.hasScheduledFrame, isTrue);

    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('watch:1'), findsOneWidget);
    expect(scopeBuilds, 2);

    await tester.pumpWidget(const SizedBox());
    current.dispose();
    replace.dispose();
    await app.dispose();
  });

  testWidgets('a replacement from a build outside a frame reaches the next '
      'frame', (tester) async {
    final (app, session) = await _scopes();
    final current = ValueNotifier<Scope>(session);
    final replace = ValueNotifier<bool>(false);
    late BuildContext plain;
    var scopeBuilds = 0;
    SchedulerPhase? phase;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ScopeProvider.listenable(
          scope: current,
          child: Column(
            children: [
              Builder(
                builder: (context) {
                  plain = context;
                  return const SizedBox();
                },
              ),
              Builder(
                builder: (context) =>
                    Text('watch:${context.watchDi<int>(key: _count)}'),
              ),
              Builder(
                builder: (context) {
                  scopeBuilds++;
                  ScopeProvider.of(context, listenToScope: true);
                  return const SizedBox();
                },
              ),
              ValueListenableBuilder<bool>(
                valueListenable: replace,
                builder: (context, value, _) {
                  if (value) {
                    phase = SchedulerBinding.instance.schedulerPhase;
                    current.value = app;
                  }
                  return const SizedBox();
                },
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('watch:2'), findsOneWidget);
    // The frame of the first pump has ended, and no frame is scheduled.
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);

    // The host builds the dirty widgets itself. No frame runs.
    replace.value = true;
    tester.binding.buildOwner!.buildScope(tester.binding.rootElement!);
    expect(phase, SchedulerPhase.idle);
    expect(tester.takeException(), isNull);
    expect(plain.di<int>(key: _count), 1);
    // The provider asks for the frame whose end moves it.
    expect(tester.binding.hasScheduledFrame, isTrue);

    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('watch:1'), findsOneWidget);
    expect(scopeBuilds, 2);

    await tester.pumpWidget(const SizedBox());
    current.dispose();
    replace.dispose();
    await session.dispose();
    await app.dispose();
  });

  testWidgets('a State.dispose that replaces the scope and disposes the old '
      'one leaves no failed read', (tester) async {
    final (app, session) = await _scopes();
    final current = ValueNotifier<Scope>(session);
    final shown = ValueNotifier<bool>(true);
    Future<void>? disposal;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ScopeProvider.listenable(
          scope: current,
          child: Column(
            children: [
              Builder(
                builder: (context) =>
                    Text('watch:${context.watchMaybeDi<int>(key: _count)}'),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: shown,
                builder: (context, value, _) => value
                    ? _Leaving(
                        onDispose: () {
                          // The host rule: change the value, then dispose.
                          current.value = app;
                          disposal = session.dispose();
                        },
                      )
                    : const SizedBox(),
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('watch:2'), findsOneWidget);

    shown.value = false;
    await tester.pump();
    expect(tester.takeException(), isNull);
    await disposal;
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('watch:1'), findsOneWidget);
    expect(session.state.phase, ScopePhase.disposed);

    await tester.pumpWidget(const SizedBox());
    current.dispose();
    shown.dispose();
    await app.dispose();
  });

  testWidgets('a transition schedules no frame while no key was watched', (
    tester,
  ) async {
    final (app, session) = await _scopes();
    final current = ValueNotifier<Scope>(session);
    var builds = 0;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ScopeProvider.listenable(
          scope: current,
          child: Builder(
            builder: (context) {
              builds++;
              return Text('plain:${context.di<int>(key: _count)}');
            },
          ),
        ),
      ),
    );
    expect(tester.binding.hasScheduledFrame, isFalse);

    // The creation of a child scope is a transition of the runtime.
    final extra = session.child();
    expect(tester.binding.hasScheduledFrame, isFalse);
    await extra.dispose();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(builds, 1);

    await tester.pumpWidget(const SizedBox());
    current.dispose();
    await app.dispose();
  });

  testWidgets('a transition schedules one frame after a key was watched', (
    tester,
  ) async {
    final (app, session) = await _scopes();
    final current = ValueNotifier<Scope>(session);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ScopeProvider.listenable(
          scope: current,
          child: Builder(
            builder: (context) =>
                Text('watch:${context.watchDi<int>(key: _count)}'),
          ),
        ),
      ),
    );
    expect(tester.binding.hasScheduledFrame, isFalse);

    final extra = session.child();
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('watch:2'), findsOneWidget);

    await extra.dispose();
    await tester.pumpWidget(const SizedBox());
    current.dispose();
    await app.dispose();
  });
}
