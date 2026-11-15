// Collection keys: many members contribute, one reader reads them all.
//
// Several features contribute elements of one interface, and one component
// reads them as one value, for example the scopes that the app starts.
//
// - A `DiSetKey<T>` collects anonymous contributions,
//   `Component<T>.into(key: key, ...)`, into a `Set<T>`.
// - A `DiMapKey<T>` collects entries. An entry is an ordinary publication of
//   `map.entryKey(id)`, so another member reads one entry with
//   `Dependency.require`, and a test replaces one entry with `overriddenBy`.
//
// The collection key decides membership, not the type: two collections of
// one interface stay apart, and a component that implements the interface is
// not an element unless it contributes. A reader sees the contributions of
// its scope and its ancestors, ancestors first, in declaration order.
//
// Differences from the fp_di version:
//
// - A group of components is a list. `[...a, ...b]` joins two groups, and
//   `overriddenBy` gives an `Exit` with the new list.
// - `requireSet` and `requireMap` stay. `Dependency.maybeSet` is `optionSet`.
// - `run()`, `dispose()`, and `child()` return an `Exit` or an `Either`.
//
// Run: dart run packages/fp_di_fpdart/example/collections.dart
import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';

void log(String message) => print('  $message');

// --- The element interface and its implementations ------------------------

abstract interface class AppScope {
  String get name;
  void start();
  void stop();
}

base class LoggedScope implements AppScope {
  LoggedScope(this.name);

  @override
  final String name;

  @override
  void start() => log('start $name');

  @override
  void stop() => log('stop $name');
}

final class ConnectivityScope extends LoggedScope {
  ConnectivityScope() : super('connectivity');
}

final class LifecycleScope extends LoggedScope {
  LifecycleScope() : super('lifecycle');
}

final class FakeLifecycleScope extends LoggedScope {
  FakeLifecycleScope() : super('lifecycle (fake)');
}

final class DeepLinkScope extends LoggedScope {
  DeepLinkScope.mobile() : super('deep link (mobile)');
  DeepLinkScope.web() : super('deep link (web)');
}

final class ScreenshotScope extends LoggedScope {
  ScreenshotScope() : super('screenshot');
}

final class AppsFlyerScope extends LoggedScope {
  AppsFlyerScope() : super('appsflyer');
}

final class SessionScope extends LoggedScope {
  SessionScope(String user) : super('session of $user');
}

/// Starts the scopes of one collection in order and stops them in reverse
/// order. It does not know which scopes exist.
///
/// It records each scope that started, so a start that fails part way leaves
/// a record of what to stop. `stop` stops only those scopes. It tries every
/// one of them, and then reports the failures together.
final class ScopeObserver {
  ScopeObserver(this.scopes);

  final List<AppScope> scopes;
  final List<AppScope> _started = [];

  void start() {
    for (final scope in scopes.skip(_started.length)) {
      scope.start();
      _started.add(scope);
    }
  }

  void stop() {
    final failures = <Object>[];
    while (_started.isNotEmpty) {
      try {
        _started.removeLast().stop();
      } on Object catch (error) {
        failures.add(error);
      }
    }
    if (failures.isNotEmpty) {
      throw StateError('scopes failed to stop: $failures');
    }
  }
}

/// Reads the lifecycle entry by its id, with the existing key reads.
final class LifecycleBanner {
  LifecycleBanner(this.lifecycle);
  final AppScope lifecycle;
}

enum Platform { mobile, web }

// --- Collection keys -------------------------------------------------------
//
// Declare each collection key once, as a constant that contributors import.
// The runtime does not detect a contribution to a wrong key.

/// The scopes that start at once. A map, so that one entry can be read and
/// replaced by its id.
const startScopes = DiMapKey<AppScope>(name: 'start');

/// The scopes that start at the first foreground, when an activity exists.
/// The element type is the same as for [startScopes]; the key keeps them
/// apart.
const foregroundScopes = DiSetKey<AppScope>(name: 'foreground');

// --- Feature groups --------------------------------------------------------
//
// In an application each feature package exports its contributions. The
// groups do not refer to the observer, and the observer does not list them.

final deviceComponents = <Component<Object?>>[
  Component<AppScope>(
    key: startScopes.entryKey('connectivity'),
    dependency: Dependency<AppScope>(create: ConnectivityScope.new),
  ),
  Component<AppScope>(
    key: startScopes.entryKey('lifecycle'),
    dependency: Dependency<AppScope>(create: LifecycleScope.new),
  ),
  Component<LifecycleBanner>(
    dependency: Dependency.require<AppScope>(
      key: startScopes.entryKey('lifecycle'),
    ).map<LifecycleBanner>(LifecycleBanner.new),
  ),
];

List<Component<Object?>> engagementComponents(Platform platform) => [
  Component<AppScope>(
    key: startScopes.entryKey('deepLink'),
    dependency: Dependency<AppScope>(
      create: switch (platform) {
        Platform.mobile => DeepLinkScope.mobile,
        Platform.web => DeepLinkScope.web,
      },
    ),
  ),
  if (platform == Platform.mobile) ...[
    Component<AppScope>.into(
      key: foregroundScopes,
      dependency: Dependency<AppScope>(create: ScreenshotScope.new),
    ),
    Component<AppScope>.into(
      key: foregroundScopes,
      dependency: Dependency<AppScope>(create: AppsFlyerScope.new),
    ),
  ],
];

const startObserver = DiKey<ScopeObserver>(name: 'start');
const foregroundObserver = DiKey<ScopeObserver>(name: 'foreground');
const scopeNames = DiKey<List<String>>(name: 'names');

final observerComponents = <Component<Object?>>[
  // Two steps: the first step owns the observer, and the second step starts
  // it. When a start fails, the rollback of the first step stops the scopes
  // that started.
  Component<ScopeObserver>(
    key: startObserver,
    dependency: Dependency.requireMap<AppScope>(key: startScopes)
        .map<ScopeObserver>(
          (scopes) => ScopeObserver(scopes.values.toList()),
          dispose: (observer) => observer.stop(),
        )
        .map<ScopeObserver>((observer) => observer..start()),
  ),
  Component<ScopeObserver>(
    key: foregroundObserver,
    dependency: Dependency.requireSet<AppScope>(key: foregroundScopes)
        .map<ScopeObserver>(
          (scopes) => ScopeObserver(scopes.toList()),
          dispose: (observer) => observer.stop(),
        ),
  ),
];

List<Component<Object?>> appComponents(Platform platform) => [
  ...deviceComponents,
  ...engagementComponents(platform),
  ...observerComponents,
];

// --- Test code -------------------------------------------------------------
//
// In an application this section lives under `test/`. A fake replaces one
// entry by its key, and the entry keeps its position.

final testFakes = <Component<Object?>>[
  Component<AppScope>(
    key: startScopes.entryKey('lifecycle'),
    dependency: Dependency<AppScope>(create: FakeLifecycleScope.new),
  ),
];

/// A scope whose start fails.
final class BrokenScope extends LoggedScope {
  BrokenScope() : super('broken');

  @override
  void start() => throw StateError('broken failed to start');
}

/// Adds an entry after the others whose start fails.
final brokenEntry = <Component<Object?>>[
  Component<AppScope>(
    key: startScopes.entryKey('broken'),
    dependency: Dependency<AppScope>(create: BrokenScope.new),
  ),
];

Future<void> run(String label, List<Component<Object?>> components) async {
  print(label);
  // A collection key is in no `requires`, and `contributes` counts the set
  // contributions of the variant.
  log('requires ${components.requires}, contributes ${components.contributes}');
  final scope = Scope(components: components);
  (await scope.run()).match(
    (cause) => log('run failed: ${cause.failures}'),
    (_) => log('first foreground'),
  );
  scope
      .get<ScopeObserver>(key: foregroundObserver)
      .match(
        (failure) => log('no observer: $failure'),
        (observer) => observer.start(),
      );
  log('dispose');
  await scope.dispose(); // each observer stops before its scopes go
}

Future<void> main() async {
  await run('mobile', appComponents(Platform.mobile));
  await run(
    'web: another deep link, no foreground scope',
    appComponents(Platform.web),
  );
  switch (appComponents(Platform.mobile).overriddenBy(testFakes)) {
    case Left(value: final cause):
      print('the override failed: ${cause.prettyPrint()}');
    case Right(value: final components):
      await run('test: one entry replaced by its key', components);
  }

  print('a scope fails to start: the scopes that started stop');
  final broken = Scope(
    components: [...appComponents(Platform.web), ...brokenEntry],
  );
  (await broken.run()).match(
    (cause) => log('run failed: ${cause.failures}'),
    (_) => log('run succeeded'),
  );
  await broken.dispose();

  await childScope();
}

/// A child scope adds a member; the parent does not see it.
Future<void> childScope() async {
  print('a child scope adds a member; the parent does not see it');
  final app = Scope(components: appComponents(Platform.mobile));
  await app.run();
  final session = app.child(
    components: [
      Component<AppScope>(
        key: startScopes.entryKey('session'),
        dependency: Dependency<AppScope>(create: () => SessionScope('alice')),
      ),
      Component<List<String>>(
        key: scopeNames,
        dependency: Dependency.requireMap<AppScope>(
          key: startScopes,
        ).map<List<String>>((scopes) => scopes.keys.toList()),
      ),
    ],
  );
  switch (session) {
    case Left(value: final failure):
      log('child failed: $failure');
    case Right(value: final child):
      await child.run();
      log('session reads ${child.getOption<List<String>>(key: scopeNames)}');
      final observer = app.get<ScopeObserver>(key: startObserver);
      log('app observer has ${observer.map((o) => o.scopes.length)} scopes');
  }

  print('a member disposed by itself leaves the collection');
  final appsFlyer = app.nodes.where(
    (node) => node.isActive && node.value.toNullable() is AppsFlyerScope,
  );
  for (final node in appsFlyer) {
    await node.dispose();
  }
  final foreground = app.get<ScopeObserver>(key: foregroundObserver);
  log(
    'foreground: '
    '${foreground.map((o) => [for (final scope in o.scopes) scope.name])}',
  );
  await app.dispose();
}
