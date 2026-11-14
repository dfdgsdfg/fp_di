// A change of publisher reaches only the components that read it.
//
// The theme of the app comes from the root. A nearer scope that initializes
// later shadows it, so the greeter releases and activates again with the new
// theme, while the clock, which does not read the theme, stays as it is.
// Withdrawing the nearer theme, one member of that scope, returns the greeter
// to the root theme. An optional read follows the same rule. An extension
// type over `String` names each key once and tells apart two strings. A
// listener on the root scope prints each component that activates or
// deactivates.
import 'package:fp_di/fp_di.dart';

/// Returns a listener that prints each component that activates or
/// deactivates. It compares `scope.state` with the value of its last call.
void Function() trace(Scope scope) {
  var last = scope.state;
  return () {
    final now = scope.state;
    for (final (earlier, later) in now.changedSince(last)) {
      if (later != null && later.commits > (earlier?.commits ?? 0)) {
        print('  + ${later.label}');
      }
      if (earlier != null &&
          earlier.phase == NodePhase.deactivating &&
          later?.phase != NodePhase.deactivating) {
        print('  - ${earlier.label}');
      }
    }
    last = now;
  };
}

/// An extension type names the key of each `String` once.
extension type const Theme(String value) implements String {
  static const key = DiKey<Theme>(name: 'Theme');
}

extension type const Locale(String value) implements String {
  static const key = DiKey<Locale>(name: 'Locale');
}

/// The time at which the clock started.
extension type const StartedAt(DateTime value) implements DateTime {
  static const key = DiKey<StartedAt>(name: 'StartedAt');
}

final class Analytics {
  const Analytics(this.name);

  final String name;
}

final class Greeter {
  Greeter(this.theme, this.locale, this.analytics) {
    print('  greeter on $theme/$locale, analytics: ${analytics?.name}');
  }

  final String theme;
  final String locale;
  final Analytics? analytics;
}

Component<T> value<T>(DiKey<T> key, T text) =>
    Component<T>.value(key: key, value: text);

/// Reads two named strings and an optional `Analytics`.
final greeter = Component<Greeter>(
  dependency: (
    Dependency.require<Theme>(key: Theme.key),
    Dependency.require<Locale>(key: Locale.key),
    Dependency.maybe<Analytics>(),
  ).zip.mapN(Greeter.new),
);

/// Reads nothing that changes, so it stays active through every change.
final clock = Component<StartedAt>(
  key: StartedAt.key,
  dependency: Dependency<StartedAt>(create: () => StartedAt(DateTime.now())),
);

Future<void> main() async {
  final app = Scope(
    module: Module(
      components: [
        value(Theme.key, Theme('light')),
        value(Locale.key, Locale('en')),
      ],
    ),
  );
  app.addListener(trace(app));
  // Declared up front, initialized later: a dark theme and analytics.
  final override = app.child(
    module: Module(
      components: [
        value(Theme.key, Theme('dark')),
        Component<Analytics>.value(value: const Analytics('beta')),
      ],
    ),
  );
  final screen = override.child(module: Module(components: [greeter, clock]));

  print('initialize');
  await app.initialize();
  await screen.initialize();

  print('the override initializes');
  await override.initialize();

  print('the dark theme is withdrawn');
  await override.node(key: Theme.key).dispose();

  print('dispose');
  await app.dispose();
}
