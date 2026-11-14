// A ScopeProvider whose scope is the value of a listenable
// (R-UC-AR-UI-001). A lookup reads the value at the moment of the call, so a
// host can replace a scope and dispose it with no frame between the two.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fp_di/fp_di.dart';
import 'package:fp_di_flutter/fp_di_flutter.dart';

const _count = DiKey<int>(name: 'count');
const _text = DiKey<String>(name: 'text');

void main() {
  testWidgets('a lookup reads the current scope before the next frame', (
    tester,
  ) async {
    final app = Scope(
      module: Module(components: [Component.value(value: 1, key: _count)]),
    );
    await app.initialize();
    final session = app.child(
      module: Module(components: [Component.value(value: 2, key: _count)]),
    );
    await session.initialize();
    final current = ValueNotifier<Scope>(session);
    late BuildContext plain;
    var plainBuilds = 0;
    var watchedBuilds = 0;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ScopeProvider.listenable(
          scope: current,
          child: Column(
            children: [
              Builder(
                builder: (context) {
                  plainBuilds++;
                  plain = context;
                  return const SizedBox();
                },
              ),
              Builder(
                builder: (context) {
                  watchedBuilds++;
                  return Text('watch:${context.watchDi<int>(key: _count)}');
                },
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('watch:2'), findsOneWidget);
    expect(plain.di<int>(key: _count), 2);

    // The host replaces the scope and disposes the old one in one turn.
    current.value = app;
    await session.dispose();

    // No frame ran. A widget that was not rebuilt reads the parent scope.
    expect(plain.di<int>(key: _count), 1);
    expect(identical(ScopeProvider.of(plain), app), isTrue);

    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('watch:1'), findsOneWidget);
    expect(plainBuilds, 1);
    expect(watchedBuilds, 2);

    await tester.pumpWidget(const SizedBox());
    current.dispose();
    await app.dispose();
  });

  testWidgets('a lookup reads the current scope while the old one disposes', (
    tester,
  ) async {
    final app = Scope(
      module: Module(components: [Component.value(value: 1, key: _count)]),
    );
    await app.initialize();
    final release = Completer<void>();
    final session = app.child(
      module: Module(
        components: [
          Component(
            dependency: Dependency(
              create: () => 2,
              dispose: (_) => release.future,
            ),
            key: _count,
          ),
        ],
      ),
    );
    await session.initialize();
    final current = ValueNotifier<Scope>(session);
    late BuildContext plain;
    var watchedBuilds = 0;

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
                builder: (context) {
                  watchedBuilds++;
                  return Text('watch:${context.watchDi<int>(key: _count)}');
                },
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('watch:2'), findsOneWidget);

    // The release of the member waits, so the disposal has started and has
    // not finished.
    current.value = app;
    final disposal = session.dispose();
    expect(plain.di<int>(key: _count), 1);

    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('watch:1'), findsOneWidget);
    expect(watchedBuilds, 2);

    release.complete();
    await disposal;
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(watchedBuilds, 2);

    await tester.pumpWidget(const SizedBox());
    current.dispose();
    await app.dispose();
  });

  testWidgets('a watcher follows the keys of the replacement scope', (
    tester,
  ) async {
    final a = Scope();
    await a.initialize();
    // The parent of `b` initializes later, so its key arrives as a change.
    final late = Scope(
      module: Module(
        components: [Component.value(value: 'late', key: _text)],
      ),
    );
    final b = late.child();
    await b.initialize();
    final current = ValueNotifier<Scope>(a);
    var builds = 0;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ScopeProvider.listenable(
          scope: current,
          child: Builder(
            builder: (context) {
              builds++;
              final text = context.watchMaybeDi<String>(key: _text);
              return Text('text:$text');
            },
          ),
        ),
      ),
    );
    expect(find.text('text:null'), findsOneWidget);

    current.value = b;
    await tester.pump();
    expect(builds, 2);
    expect(find.text('text:null'), findsOneWidget);

    await late.initialize();
    await tester.pump();
    expect(builds, 3);
    expect(find.text('text:late'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    current.dispose();
    await a.dispose();
    await late.dispose();
  });

  testWidgets('a widget that listens to the scope rebuilds on replacement', (
    tester,
  ) async {
    final a = Scope(
      module: Module(components: [Component.value(value: 1, key: _count)]),
    );
    final b = Scope();
    await b.initialize();
    final current = ValueNotifier<Scope>(a);
    final seen = <Scope>[];

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ScopeProvider.listenable(
          scope: current,
          child: Builder(
            builder: (context) {
              seen.add(ScopeProvider.of(context, listenToScope: true));
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    expect(seen, [a]);

    // The change of a key is not a replacement of the scope.
    await a.initialize();
    await tester.pump();
    expect(seen, [a]);

    current.value = b;
    await a.dispose();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(seen, [a, b]);

    await tester.pumpWidget(const SizedBox());
    current.dispose();
    await b.dispose();
  });

  testWidgets('a new listenable replaces the subscription', (tester) async {
    final a = Scope(
      module: Module(components: [Component.value(value: 1, key: _count)]),
    );
    final b = Scope(
      module: Module(components: [Component.value(value: 2, key: _count)]),
    );
    await a.initialize();
    await b.initialize();
    final first = ValueNotifier<Scope>(a);
    final second = ValueNotifier<Scope>(b);

    Widget tree(ValueNotifier<Scope> source) => Directionality(
      textDirection: TextDirection.ltr,
      child: ScopeProvider.listenable(
        scope: source,
        child: Builder(
          builder: (context) =>
              Text('watch:${context.watchDi<int>(key: _count)}'),
        ),
      ),
    );

    await tester.pumpWidget(tree(first));
    expect(find.text('watch:1'), findsOneWidget);

    await tester.pumpWidget(tree(second));
    expect(find.text('watch:2'), findsOneWidget);
    // ignore: invalid_use_of_protected_member
    expect(first.hasListeners, isFalse);

    await tester.pumpWidget(const SizedBox());
    // ignore: invalid_use_of_protected_member
    expect(second.hasListeners, isFalse);
    first.dispose();
    second.dispose();
    await a.dispose();
    await b.dispose();
  });
}
