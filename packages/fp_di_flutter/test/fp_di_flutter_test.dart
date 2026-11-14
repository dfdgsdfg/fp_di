import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fp_di/fp_di.dart';
import 'package:fp_di_flutter/fp_di_flutter.dart';

const _count = DiKey<int>(name: 'count');

void main() {
  testWidgets('di is non-listening and watchDi observes publisher identity', (
    tester,
  ) async {
    // Every scope is declared up front. The later ones initialize after the
    // widgets build, so their publications arrive as late changes.
    final root = Scope(
      module: Module(
        components: [
          Component.value(value: 1, key: DiKey<int>(name: 'count')),
        ],
      ),
    );
    final local = root.child(
      module: Module(
        components: [
          Component.value(value: 2, key: DiKey<int>(name: 'count')),
        ],
      ),
    );
    final unrelated = local.child(
      module: Module(
        components: [
          Component.value(
            value: 'unrelated',
            key: DiKey<String>(name: 'text'),
          ),
        ],
      ),
    );
    final child = unrelated.child();
    final sibling = root.child(
      module: Module(
        components: [
          Component.value(value: 99, key: DiKey<int>(name: 'count')),
        ],
      ),
    );
    await root.initialize();
    await child.initialize();
    var plainBuilds = 0;
    var watchedBuilds = 0;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ScopeProvider.fixed(
          scope: child,
          child: Row(
            children: [
              Builder(
                builder: (context) {
                  plainBuilds++;
                  final count = context.di<int>(key: _count);
                  return Text('plain:$count');
                },
              ),
              Builder(
                builder: (context) {
                  watchedBuilds++;
                  final count = context.watchDi<int>(key: _count);
                  return Text('watch:$count');
                },
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('plain:1'), findsOneWidget);
    expect(find.text('watch:1'), findsOneWidget);

    await local.initialize();
    await tester.pump();
    expect(plainBuilds, 1);
    expect(watchedBuilds, 2);
    expect(find.text('plain:1'), findsOneWidget);
    expect(find.text('watch:2'), findsOneWidget);

    await unrelated.initialize();
    await sibling.initialize();
    await tester.pump();
    expect(plainBuilds, 1);
    expect(watchedBuilds, 2);

    await root.dispose();
  });
}
