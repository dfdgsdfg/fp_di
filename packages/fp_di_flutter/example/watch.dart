// `di` reads once. `watchDi` rebuilds when the key changes.
//
// `context.di<T>()` and `context.maybeDi<T>()` register no rebuild. A widget
// that uses them keeps what it read until something else rebuilds it.
// `context.watchDi<T>()` and `context.watchMaybeDi<T>()` rebuild the widget
// when the member that publishes the key changes, or when the key becomes
// available or unavailable. They do not watch the fields of the value.
//
// Here a promotion ends: the application disposes the member that publishes
// `Promotion`. The watching banner rebuilds and shows nothing. The label that
// read once still shows the old text.
import 'package:flutter/material.dart';
import 'package:fp_di/fp_di.dart';
import 'package:fp_di_flutter/fp_di_flutter.dart';

final class Promotion {
  const Promotion(this.text);
  final String text;
}

final appModule = Module(
  components: [
    Component<Promotion>.value(value: const Promotion('Free shipping')),
  ],
  debugLabel: 'app',
);

Future<void> main() async {
  final app = await Scope(module: appModule).initialize();
  runApp(WatchApp(scope: app));
}

final class WatchApp extends StatelessWidget {
  const WatchApp({required this.scope, super.key});

  final Scope scope;

  @override
  Widget build(BuildContext context) {
    return ScopeProvider.fixed(
      scope: scope,
      child: const MaterialApp(home: ShopPage()),
    );
  }
}

final class ShopPage extends StatelessWidget {
  const ShopPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const WatchingBanner(),
            const ReadOnceLabel(),
            TextButton(
              // Disposes the one member that publishes `Promotion`. The
              // other members of the scope stay.
              onPressed: () => ScopeProvider.of(
                context,
              ).node<Promotion>(key: const DiKey<Promotion>()).dispose(),
              child: const Text('End the promotion'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Rebuilds when `Promotion` becomes unavailable.
final class WatchingBanner extends StatelessWidget {
  const WatchingBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final promotion = context.watchMaybeDi<Promotion>();
    return Text('watch: ${promotion?.text ?? 'no promotion'}');
  }
}

/// Reads once. Nothing rebuilds this widget when the promotion ends.
final class ReadOnceLabel extends StatelessWidget {
  const ReadOnceLabel({super.key});

  @override
  Widget build(BuildContext context) {
    final promotion = context.maybeDi<Promotion>();
    return Text('read once: ${promotion?.text ?? 'no promotion'}');
  }
}
