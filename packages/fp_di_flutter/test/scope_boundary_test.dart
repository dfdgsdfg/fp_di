// `ScopeBoundary` holds the disposal of a caller-owned scope while it is
// mounted, publishes the scope, and builds from its state (R-UC-AR-UI-007,
// V-T-AR-UI-014).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fp_di/fp_di.dart';
import 'package:fp_di_flutter/fp_di_flutter.dart';

const _name = DiKey<String>(name: 'name');

Module _module(String name, List<String> log) => Module(
  components: [
    Component<String>(
      dependency: Dependency<String>(
        create: () => name,
        dispose: (_) => log.add(name),
      ),
      key: _name,
    ),
  ],
);

/// A boundary of [scope] whose builder reads the name with a strict read.
Widget _page(Scope scope, String title, {String? debugLabel, Key? key}) =>
    ScopeBoundary(
      key: key,
      scope: scope,
      debugLabel: debugLabel,
      builder: (context, snapshot, child) => Text(
        '$title ${snapshot.phase.name} ${context.di<String>(key: _name)}',
      ),
    );

void main() {
  testWidgets('a logout reads the session in each exiting route, and the '
      'disposal waits for the routes', (tester) async {
    final log = <String>[];
    final app = await Scope(module: _module('app', log)).initialize();
    final session = await app
        .child(module: _module('session', log))
        .initialize();
    final current = ValueNotifier<Scope>(session);
    final navigator = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      ScopeProvider.listenable(
        scope: current,
        child: MaterialApp(navigatorKey: navigator, home: const Text('home')),
      ),
    );
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => _page(session, 'editor', debugLabel: 'editor'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: '/profile'),
          builder: (_) => _page(session, 'profile'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      [for (final hold in session.openHolds) hold.debugLabel],
      ['editor', '/profile'],
    );

    // Logout in one turn: change the value, request the disposal, and remove
    // the routes. Nothing waits for the disposal before the routes leave.
    var disposed = false;
    current.value = app;
    unawaited(session.dispose().then((_) => disposed = true));
    navigator.currentState!.popUntil((route) => route.isFirst);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // In the middle of the exit transitions, both routes read the session.
    expect(
      find.text('editor disposeRequested session', skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.text('profile disposeRequested session', skipOffstage: false),
      findsOneWidget,
    );
    expect(
      session.describe(),
      contains('(disposal waits for 2 holds: editor, /profile)'),
    );
    expect(log, isEmpty);
    expect(disposed, isFalse);

    await tester.pumpAndSettle();
    expect(log, ['session']);
    expect(disposed, isTrue);
    expect(tester.takeException(), isNull);
    await app.dispose();
  });

  testWidgets('a boundary that mounts after the request takes no hold', (
    tester,
  ) async {
    final log = <String>[];
    final scope = await Scope(module: _module('s', log)).initialize();
    final manual = scope.disposeHold(debugLabel: 'manual');
    var disposed = false;
    unawaited(scope.dispose().then((_) => disposed = true));

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: _page(scope, 'late'),
      ),
    );
    expect(find.text('late disposeRequested s'), findsOneWidget);
    expect([for (final hold in scope.openHolds) hold.debugLabel], ['manual']);

    manual.close();
    await tester.pump();
    await tester.pump();
    expect(disposed, isTrue);
    expect(log, ['s']);
    // The disposal started while the boundary was mounted: it keeps no
    // widget below it.
    expect(find.textContaining('late'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a disposal that ignores the holds empties a mounted boundary '
      'before a ticking descendant reads', (tester) async {
    final log = <String>[];
    final scope = await Scope(module: _module('s', log)).initialize();
    var builds = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ScopeBoundary(
          scope: scope,
          builder: (context, snapshot, child) {
            builds++;
            return child!;
          },
          child: const _Ticking(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.text('tick s'), findsOneWidget);

    final disposal = scope.dispose(ignoreHolds: true);
    await tester.pump(const Duration(milliseconds: 16));
    await disposal;
    final afterDisposal = builds;
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));

    expect(tester.takeException(), isNull);
    expect(find.byType(_Ticking), findsNothing);
    expect(builds, afterDisposal);
    expect(log, ['s']);
  });

  testWidgets('a rebuild with another scope moves the hold', (tester) async {
    final a = await Scope(module: _module('a', [])).initialize();
    final b = await Scope(module: _module('b', [])).initialize();
    Widget tree(Scope scope) => Directionality(
      textDirection: TextDirection.ltr,
      child: _page(scope, 'page'),
    );

    await tester.pumpWidget(tree(a));
    expect(a.openHolds, hasLength(1));
    await tester.pumpWidget(tree(b));
    expect(a.openHolds, isEmpty);
    expect(b.openHolds, hasLength(1));
    expect(find.text('page initialized b'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(b.openHolds, isEmpty);
    await a.dispose();
    await b.dispose();
  });

  testWidgets('a move with a GlobalKey keeps the hold', (tester) async {
    final log = <String>[];
    final scope = await Scope(module: _module('s', log)).initialize();
    final key = GlobalKey();
    Widget tree({required bool left}) => Directionality(
      textDirection: TextDirection.ltr,
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: left ? _page(scope, 'p', key: key) : null,
          ),
          SizedBox(
            width: 100,
            child: left ? null : _page(scope, 'p', key: key),
          ),
        ],
      ),
    );

    await tester.pumpWidget(tree(left: true));
    var disposed = false;
    unawaited(scope.dispose().then((_) => disposed = true));
    await tester.pumpWidget(tree(left: false));
    await tester.pump();
    expect(scope.openHolds, hasLength(1));
    expect(log, isEmpty);
    expect(disposed, isFalse);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(disposed, isTrue);
    expect(log, ['s']);
  });

  testWidgets('a route that another route covers keeps the disposal waiting', (
    tester,
  ) async {
    final log = <String>[];
    final scope = await Scope(module: _module('s', log)).initialize();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const Text('home')),
    );
    final covered = MaterialPageRoute<void>(
      builder: (_) => _page(scope, 'covered'),
    );
    unawaited(navigator.currentState!.push(covered));
    await tester.pumpAndSettle();
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Text('top')),
      ),
    );
    await tester.pumpAndSettle();

    var disposed = false;
    unawaited(scope.dispose().then((_) => disposed = true));
    await tester.pumpAndSettle();
    expect(disposed, isFalse);
    expect(log, isEmpty);

    navigator.currentState!.removeRoute(covered);
    await tester.pumpAndSettle();
    expect(disposed, isTrue);
    expect(log, ['s']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the documented builder keeps the content of a page scope '
      'while a hold of its parent keeps the disposal waiting', (tester) async {
    final log = <String>[];
    final session = await Scope(module: _module('session', log)).initialize();
    var disposed = false;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ScopeBoundary(
          scope: session,
          builder: (context, snapshot, child) => child!,
          child: ScopeBuilder(
            create: (parent) => parent.child(module: _module('page', log)),
            // The pattern of the README: content once initialized.
            builder: (context, snapshot, child) => switch (snapshot) {
              ScopeSnapshot(:final error?) => Text('error $error'),
              _ when snapshot.scope.isInitialized => Text(
                'content ${snapshot.phase.name} '
                '${context.di<String>(key: _name)}',
              ),
              _ => const Text('loading'),
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('content initialized page'), findsOneWidget);

    unawaited(session.dispose().then((_) => disposed = true));
    await tester.pump();
    await tester.pump();
    expect(find.text('content disposeRequested page'), findsOneWidget);
    expect(find.text('loading'), findsNothing);
    expect(disposed, isFalse);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(disposed, isTrue);
    expect(log, containsAll(<String>['page', 'session']));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a watcher below a boundary follows a withdrawal of an '
      'ancestor during the wait, also below a provider that mounts then', (
    tester,
  ) async {
    const outer = DiKey<String>(name: 'outer');
    final app = await Scope(
      module: Module(
        components: [Component<String>.value(value: 'up', key: outer)],
      ),
    ).initialize();
    final session = await app
        .child(module: _module('session', []))
        .initialize();
    final manual = session.disposeHold(debugLabel: 'manual');
    Widget watcher(String title) => Builder(
      builder: (context) =>
          Text('$title ${context.watchMaybeDi<String>(key: outer) ?? 'none'}'),
    );

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            ScopeBoundary(
              scope: session,
              builder: (context, snapshot, child) => child!,
              child: watcher('boundary'),
            ),
          ],
        ),
      ),
    );
    unawaited(session.dispose());
    await tester.pump();
    // A provider that mounts while the disposal waits.
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            ScopeBoundary(
              scope: session,
              builder: (context, snapshot, child) => child!,
              child: watcher('boundary'),
            ),
            ScopeProvider.fixed(scope: session, child: watcher('late')),
          ],
        ),
      ),
    );
    expect(find.text('boundary up'), findsOneWidget);
    expect(find.text('late up'), findsOneWidget);

    await app.node<String>(key: outer).dispose();
    await tester.pump();
    await tester.pump();
    expect(find.text('boundary none'), findsOneWidget);
    expect(find.text('late none'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    manual.close();
    await tester.pump();
    expect(tester.takeException(), isNull);
    await app.dispose();
  });

  testWidgets('the widget calls no initialize and no dispose', (tester) async {
    final scope = Scope(module: _module('s', []));
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ScopeBoundary(
          scope: scope,
          builder: (context, snapshot, child) =>
              Text('phase ${snapshot.phase.name} ${snapshot.hasError}'),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('phase declared false'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(scope.isDisposed, isFalse);
    expect(scope.state.phase, ScopePhase.declared);
    await scope.dispose();
  });
}

/// Rebuilds on each frame and reads the name with a strict read.
class _Ticking extends StatefulWidget {
  const _Ticking();

  @override
  State<_Ticking> createState() => _TickingState();
}

class _TickingState extends State<_Ticking>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((_) => setState(() {}))..start();

  @override
  Widget build(BuildContext context) {
    _ticker; // starts with the first build
    return Text('tick ${context.di<String>(key: _name)}');
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}
