// `ScopeProvider.maybeOf` returns null when no provider is above
// (R-UC-AR-UI-003). A widget can therefore read a scope that the host holds
// outside the widget tree when no provider publishes one.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fp_di/fp_di.dart';
import 'package:fp_di_flutter/fp_di_flutter.dart';

const _count = DiKey<int>(name: 'count');

Scope _scope(int value) => Scope(
  module: Module(
    components: [Component<int>.value(value: value, key: _count)],
  ),
);

/// Calls [onInit] in `initState`, where a listening lookup is not allowed.
class _InitReader extends StatefulWidget {
  const _InitReader({required this.onInit});

  final void Function(BuildContext context) onInit;

  @override
  State<_InitReader> createState() => _InitReaderState();
}

class _InitReaderState extends State<_InitReader> {
  @override
  void initState() {
    super.initState();
    widget.onInit(context);
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  testWidgets('maybeOf returns null without a provider, and of throws', (
    tester,
  ) async {
    final found = <Scope?>[];
    Object? error;
    Scope? atInit = _scope(0);

    await tester.pumpWidget(
      Column(
        children: [
          Builder(
            builder: (context) {
              found
                ..add(ScopeProvider.maybeOf(context))
                ..add(ScopeProvider.maybeOf(context, key: _count))
                ..add(ScopeProvider.maybeOf(context, nodeKey: _count))
                ..add(ScopeProvider.maybeOf(context, listenToScope: true));
              try {
                ScopeProvider.of(context);
              } on FlutterError catch (e) {
                error = e;
              }
              return const SizedBox();
            },
          ),
          _InitReader(
            onInit: (context) => atInit = ScopeProvider.maybeOf(context),
          ),
        ],
      ),
    );

    expect(found, [null, null, null, null]);
    expect(error, isA<FlutterError>());
    expect(atInit, isNull);
  });

  testWidgets('maybeOf returns the scope that of returns', (tester) async {
    final app = await _scope(1).initialize();
    final found = <Scope?>[];
    Scope? atInit;

    await tester.pumpWidget(
      ScopeProvider.fixed(
        scope: app,
        child: Column(
          children: [
            Builder(
              builder: (context) {
                found
                  ..add(ScopeProvider.maybeOf(context))
                  ..add(ScopeProvider.maybeOf(context, key: _count))
                  ..add(ScopeProvider.maybeOf(context, nodeKey: _count))
                  ..add(ScopeProvider.maybeOf(context, listenToScope: true))
                  ..add(ScopeProvider.of(context));
                return const SizedBox();
              },
            ),
            _InitReader(
              onInit: (context) => atInit = ScopeProvider.maybeOf(context),
            ),
          ],
        ),
      ),
    );

    expect(found, hasLength(5));
    expect(found.every((scope) => identical(scope, app)), isTrue);
    expect(identical(atInit, app), isTrue);

    await tester.pumpWidget(const SizedBox());
    await app.dispose();
  });

  testWidgets('a watching maybeOf follows the key like of', (tester) async {
    final app = await _scope(1).initialize();
    var builds = 0;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ScopeProvider.fixed(
          scope: app,
          child: Builder(
            builder: (context) {
              builds++;
              final scope = ScopeProvider.maybeOf(context, key: _count);
              return Text('count:${scope?.maybeGet<int>(key: _count)}');
            },
          ),
        ),
      ),
    );
    expect(find.text('count:1'), findsOneWidget);

    await app.node<int>(key: _count).dispose();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('count:null'), findsOneWidget);
    expect(builds, 2);

    await tester.pumpWidget(const SizedBox());
    await app.dispose();
  });

  for (final mode in ['key', 'nodeKey', 'listenToScope']) {
    testWidgets('a maybeOf with $mode that found no provider rebuilds when '
        'the widget moves below one', (tester) async {
      final app = await _scope(1).initialize();
      final seen = <Scope?>[];
      // One widget instance with a global key: the framework moves its
      // element and has no other reason to rebuild it.
      final reader = Builder(
        key: GlobalKey(),
        builder: (context) {
          seen.add(switch (mode) {
            'key' => ScopeProvider.maybeOf(context, key: _count),
            'nodeKey' => ScopeProvider.maybeOf(context, nodeKey: _count),
            _ => ScopeProvider.maybeOf(context, listenToScope: true),
          });
          return const SizedBox();
        },
      );

      await tester.pumpWidget(reader);
      expect(seen, [null]);

      await tester.pumpWidget(ScopeProvider.fixed(scope: app, child: reader));
      expect(seen, hasLength(2));
      expect(identical(seen.last, app), isTrue);

      await tester.pumpWidget(const SizedBox());
      await app.dispose();
    });
  }
}
