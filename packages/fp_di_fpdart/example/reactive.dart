// A change of publisher reaches only the components that read it.
//
// The theme of the app comes from the root. A nearer scope that runs later
// shadows it, so the greeter releases and activates again with the new theme,
// while the clock, which does not read the theme, stays as it is. Withdrawing
// the nearer theme, one node of that scope, returns the greeter to the root
// theme. An optional read follows the same rule. An extension type over
// `String` names each key once and tells apart two strings. A listener on the
// root scope prints each component that activates or deactivates.
//
// Differences from the fp_di version:
//
// - `scope.state` has no `changedSince`, so the trace compares the node
//   states of two values of the state itself.
// - `run()` returns an `Exit`, `child` and `node` return an `Either`, and
//   `Dependency.option` gives an `Option`.
//
// Run: dart run packages/fp_di_fpdart/example/reactive.dart
import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';

/// The node states of [state] and of its children, by id.
Map<NodeId, NodeState> nodesOf(ScopeState state) => {
  for (final node in state.nodeStates) node.id: node,
  for (final child in state.childStates) ...nodesOf(child),
};

/// Returns a listener that prints each component that activates or
/// deactivates. It compares `scope.state` with the value of its last call.
void Function() trace(Scope scope) {
  var last = nodesOf(scope.state);
  return () {
    final now = nodesOf(scope.state);
    for (final MapEntry(key: id, value: later) in now.entries) {
      final earlier = last[id];
      if (later.commits > (earlier?.commits ?? 0)) print('  + ${later.label}');
    }
    for (final MapEntry(key: id, value: earlier) in last.entries) {
      final later = now[id];
      if (earlier.phase == NodePhase.deactivating &&
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
    print(
      '  greeter on $theme/$locale, '
      'analytics: ${analytics.map((a) => a.name).toNullable()}',
    );
  }

  final String theme;
  final String locale;
  final Option<Analytics> analytics;
}

Component<T> value<T>(DiKey<T> key, T text) =>
    Component<T>.value(key: key, value: text);

/// Reads two named strings and an optional `Analytics`.
final greeter = Component<Greeter>(
  dependency: (
    Dependency.require<Theme>(key: Theme.key),
    Dependency.require<Locale>(key: Locale.key),
    Dependency.option<Analytics>(),
  ).zip.mapN<Greeter>(Greeter.new),
);

/// Reads nothing that changes, so it stays active through every change.
final clock = Component<StartedAt>(
  key: StartedAt.key,
  dependency: Dependency<StartedAt>(create: () => StartedAt(DateTime.now())),
);

/// A child scope. `child` is a `Left` only for a scope that is disposing or
/// disposed, so the example reads it as a bug.
Scope childOf(Scope parent, List<Component<Object?>> components) => parent
    .child(components: components)
    .getOrElse((failure) => throw StateError('$failure'));

Future<void> main() async {
  final app = Scope(
    components: [
      value(Theme.key, Theme('light')),
      value(Locale.key, Locale('en')),
    ],
  );
  app.addListener(trace(app));
  // Declared up front, run later: a dark theme and analytics.
  final override = childOf(app, [
    value(Theme.key, Theme('dark')),
    Component<Analytics>.value(value: const Analytics('beta')),
  ]);
  final screen = childOf(override, [greeter, clock]);

  print('run');
  await app.run();
  await screen.run();

  print('the override runs');
  await override.run();

  print('the dark theme is withdrawn');
  final dark = override.node<Theme>(key: Theme.key);
  await dark.match((failure) => throw StateError('$failure'), (node) {
    return node.dispose();
  });

  print('dispose');
  await app.dispose();
}
