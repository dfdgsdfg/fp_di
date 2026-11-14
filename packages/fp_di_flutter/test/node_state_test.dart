// `watchMaybeDiNode` rebuilds a widget when the state of a node changes
// (R-UC-AR-UI-003).
//
// A child scope initializes before its parent, so its members wait for the
// keys of the parent. The parent initializes later: one member activates and
// one fails. The failure of an automatic activation goes to no caller, so a
// widget sees it only through the state of the node.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fp_di/fp_di.dart';
import 'package:fp_di_flutter/fp_di_flutter.dart';

const _source = DiKey<int>(name: 'source');
const _good = DiKey<String>(name: 'good');
const _bad = DiKey<String>(name: 'bad');
const _absent = DiKey<String>(name: 'absent');

Module _parentModule() =>
    Module(components: [Component<int>.value(value: 1, key: _source)]);

Module _childModule() => Module(
  components: [
    Component<String>(
      dependency: Dependency1<int, String>(
        key1: _source,
        create: (source) => 'good:$source',
      ),
      key: _good,
    ),
    Component<String>(
      dependency: Dependency1<int, String>(
        key1: _source,
        create: (source) => throw StateError('no data'),
      ),
      key: _bad,
    ),
  ],
);

/// A text of the node state, as a widget would switch on it.
String _describe(ComponentNode<String>? node) => switch (node?.state.phase) {
  null => 'none',
  NodePhase.active => 'value ${node!.value}',
  NodePhase.activationFailed => 'failed ${node!.activationException!.cause}',
  _ => 'pending',
};

void main() {
  testWidgets('a watcher of a node follows waiting, active, and failed', (
    tester,
  ) async {
    final parent = Scope(module: _parentModule());
    final child = parent.child(module: _childModule());
    await child.initialize();
    final builds = <DiKey<String>, int>{_good: 0, _bad: 0, _absent: 0};
    var plainBuilds = 0;

    Widget watcher(DiKey<String> key) => Builder(
      builder: (context) {
        builds[key] = builds[key]! + 1;
        final node = context.watchMaybeDiNode<String>(key: key);
        return Text('${key.name}: ${_describe(node)}');
      },
    );

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ScopeProvider.fixed(
          scope: child,
          child: Column(
            children: [
              watcher(_good),
              watcher(_bad),
              watcher(_absent),
              Builder(
                builder: (context) {
                  plainBuilds++;
                  final node = context.maybeDiNode<String>(key: _bad);
                  return Text('plain: ${_describe(node)}');
                },
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('good: pending'), findsOneWidget);
    expect(find.text('bad: pending'), findsOneWidget);
    expect(find.text('absent: none'), findsOneWidget);
    expect(find.text('plain: pending'), findsOneWidget);

    // The failure of the dependent goes to no caller: this call succeeds.
    await parent.initialize();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('good: value good:1'), findsOneWidget);
    expect(find.text('bad: failed Bad state: no data'), findsOneWidget);
    expect(find.text('absent: none'), findsOneWidget);
    // The non-listening read keeps what it read.
    expect(find.text('plain: pending'), findsOneWidget);
    expect(plainBuilds, 1);
    expect(builds[_good], 2);
    expect(builds[_bad], 2);
    expect(builds[_absent], 1);

    await tester.pumpWidget(const SizedBox());
    await parent.dispose();
  });

  testWidgets('a watcher of a node follows the replacement scope', (
    tester,
  ) async {
    final a = Scope(module: _parentModule());
    final b = Scope(
      module: Module(
        components: [Component<String>.value(value: 'b', key: _good)],
      ),
    );
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
              final node = context.watchMaybeDiNode<String>(key: _good);
              return Text('good: ${_describe(node)}');
            },
          ),
        ),
      ),
    );
    expect(find.text('good: none'), findsOneWidget);

    current.value = b;
    await a.dispose();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('good: value b'), findsOneWidget);
    expect(builds, 2);

    // The disposal of the published scope rebuilds no watcher of a node.
    await b.dispose();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(builds, 2);

    await tester.pumpWidget(const SizedBox());
    current.dispose();
  });

  testWidgets('a watcher of a node reads activating and deactivating', (
    tester,
  ) async {
    final createGate = Completer<void>();
    final disposeGate = Completer<void>();
    final scope = Scope(
      module: Module(
        components: [
          Component<String>(
            key: _good,
            dependency: Dependency(
              create: () async {
                await createGate.future;
                return 'ready';
              },
              dispose: (_) => disposeGate.future,
            ),
          ),
        ],
      ),
    );
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ScopeProvider.fixed(
          scope: scope,
          child: Column(
            children: [
              Builder(
                builder: (context) {
                  final node = context.watchMaybeDiNode<String>(key: _good);
                  return Text('phase: ${node?.state.phase.name}');
                },
              ),
              Builder(
                builder: (context) {
                  final value = context.watchMaybeDi<String>(key: _good);
                  return Text('value: $value');
                },
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('phase: null'), findsOneWidget);
    expect(find.text('value: null'), findsOneWidget);

    // The create function waits: the node activates, and it has no value.
    final initialized = scope.initialize();
    await tester.pump();
    await tester.pump();
    expect(find.text('phase: activating'), findsOneWidget);
    expect(find.text('value: null'), findsOneWidget);

    createGate.complete();
    await initialized;
    await tester.pump();
    expect(find.text('phase: active'), findsOneWidget);
    expect(find.text('value: ready'), findsOneWidget);

    // The dispose function waits: the key is withdrawn at the start.
    final disposed = scope.nodes.single.dispose();
    await tester.pump();
    await tester.pump();
    expect(find.text('phase: deactivating'), findsOneWidget);
    expect(find.text('value: null'), findsOneWidget);

    disposeGate.complete();
    await disposed;
    await tester.pump();
    // A member that was disposed alone has no node.
    expect(find.text('phase: null'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await scope.dispose();
  });
}
