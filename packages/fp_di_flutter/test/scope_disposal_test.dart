// How ScopeProvider treats the disposal of a scope (R-UC-AR-UI-001).
//
// A disposed scope answers no read. A rebuild that the disposal causes can
// therefore only throw, so the provider must not cause one.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fp_di/fp_di.dart';
import 'package:fp_di_flutter/fp_di_flutter.dart';

const _count = DiKey<int>(name: 'count');
const _text = DiKey<String>(name: 'text');

void main() {
  testWidgets('the disposal of the published scope rebuilds no watcher', (
    tester,
  ) async {
    final app = Scope(
      module: Module(components: [Component.value(value: 1, key: _count)]),
    );
    await app.initialize();
    final session = app.child(
      module: Module(
        components: [Component.value(value: 's', key: _text)],
      ),
    );
    await session.initialize();
    var builds = 0;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ScopeProvider.fixed(
          scope: session,
          child: Builder(
            builder: (context) {
              builds++;
              return Text('text:${context.watchDi<String>(key: _text)}');
            },
          ),
        ),
      ),
    );
    expect(find.text('text:s'), findsOneWidget);

    await session.dispose();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(builds, 1);
    await tester.pumpWidget(const SizedBox());
    await app.dispose();
  });

  testWidgets('the disposal of another scope rebuilds no watcher', (
    tester,
  ) async {
    final app = Scope(
      module: Module(components: [Component.value(value: 1, key: _count)]),
    );
    await app.initialize();
    final other = app.child(
      module: Module(
        components: [Component.value(value: 's', key: _text)],
      ),
    );
    await other.initialize();
    var builds = 0;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ScopeProvider.fixed(
          scope: app,
          child: Builder(
            builder: (context) {
              builds++;
              return Text('count:${context.watchDi<int>(key: _count)}');
            },
          ),
        ),
      ),
    );
    expect(builds, 1);

    await other.dispose();
    await tester.pump();

    expect(builds, 1);
    expect(find.text('count:1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await app.dispose();
  });

  testWidgets('a disposal in flight rebuilds no watcher', (tester) async {
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
              create: () => 's',
              dispose: (_) => release.future,
            ),
            key: _text,
          ),
        ],
      ),
    );
    await session.initialize();
    var builds = 0;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ScopeProvider.fixed(
          scope: session,
          child: Builder(
            builder: (context) {
              builds++;
              return Text('text:${context.watchDi<String>(key: _text)}');
            },
          ),
        ),
      ),
    );

    // The release of the member waits, so the disposal has started and has
    // not finished.
    final disposal = session.dispose();
    await tester.pump();
    expect(session.isDisposed, isTrue);
    expect(tester.takeException(), isNull);
    expect(builds, 1);

    release.complete();
    await disposal;
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(builds, 1);

    await tester.pumpWidget(const SizedBox());
    await app.dispose();
  });
}
