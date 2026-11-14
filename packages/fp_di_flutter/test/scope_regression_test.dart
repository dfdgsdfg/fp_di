// The replacement of the scope of a fixed ScopeProvider (R-UC-AR-UI-001).
//
// A parent that rebuilds the provider with another scope replaces the scope
// at that frame. The provider never disposes a scope that the caller owns.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fp_di/fp_di.dart';
import 'package:fp_di_flutter/fp_di_flutter.dart';

const _count = DiKey<int>(name: 'count');

void main() {
  testWidgets('a rebuild with another scope moves every listening lookup', (
    tester,
  ) async {
    final a = Scope(
      module: Module(components: [Component.value(value: 1, key: _count)]),
    );
    final b = Scope(
      module: Module(components: [Component.value(value: 2, key: _count)]),
    );
    await a.initialize();
    await b.initialize();
    final seen = <Scope>[];
    var plainBuilds = 0;

    // One child object for both trees, so only the provider rebuilds a
    // widget below it.
    final child = Column(
      children: [
        Builder(
          builder: (context) {
            seen.add(ScopeProvider.of(context, listenToScope: true));
            return const SizedBox();
          },
        ),
        Builder(
          builder: (context) =>
              Text('watch:${context.watchDi<int>(key: _count)}'),
        ),
        Builder(
          builder: (context) {
            plainBuilds++;
            return Text('plain:${context.di<int>(key: _count)}');
          },
        ),
      ],
    );
    Widget tree(Scope scope) => Directionality(
      textDirection: TextDirection.ltr,
      child: ScopeProvider.fixed(scope: scope, child: child),
    );

    await tester.pumpWidget(tree(a));
    expect(seen, [a]);
    expect(find.text('watch:1'), findsOneWidget);
    expect(find.text('plain:1'), findsOneWidget);

    await tester.pumpWidget(tree(b));
    expect(seen, [a, b]);
    expect(find.text('watch:2'), findsOneWidget);
    // A non-listening read keeps what it read.
    expect(plainBuilds, 1);
    expect(find.text('plain:1'), findsOneWidget);

    // The provider is gone, and both scopes still answer.
    await tester.pumpWidget(const SizedBox());
    expect(a.get<int>(key: _count), 1);
    expect(b.get<int>(key: _count), 2);
    await a.dispose();
    await b.dispose();
  });
}
