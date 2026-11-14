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
import 'package:fp_di/fp_di.dart';

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

// --- Feature modules -------------------------------------------------------
//
// In an application each feature package exports its contributions. The
// modules do not refer to the observer, and the observer does not list them.

final deviceModule = Module(
  components: [
    Component<AppScope>(
      key: startScopes.entryKey('connectivity'),
      dependency: Dependency<AppScope>(create: ConnectivityScope.new),
    ),
    Component<AppScope>(
      key: startScopes.entryKey('lifecycle'),
      dependency: Dependency<AppScope>(create: LifecycleScope.new),
    ),
    Component<LifecycleBanner>(
      dependency: Dependency1<AppScope, LifecycleBanner>(
        key1: startScopes.entryKey('lifecycle'),
        create: LifecycleBanner.new,
      ),
    ),
  ],
  debugLabel: 'device',
);

Module engagementModule(Platform platform) => Module(
  components: [
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
  ],
  debugLabel: 'engagement',
);

const startObserver = DiKey<ScopeObserver>(name: 'start');
const foregroundObserver = DiKey<ScopeObserver>(name: 'foreground');
const scopeNames = DiKey<List<String>>(name: 'names');

final observerModule = Module(
  components: [
    // Two steps: the first step owns the observer, and the second step starts
    // it. When a start fails, the rollback of the first step stops the scopes
    // that started.
    Component<ScopeObserver>(
      key: startObserver,
      dependency: Dependency.requireMap(key: startScopes)
          .map(
            (scopes) => ScopeObserver(scopes.values.toList()),
            dispose: (observer) => observer.stop(),
          )
          .map((observer) => observer..start()),
    ),
    Component<ScopeObserver>(
      key: foregroundObserver,
      dependency: Dependency.requireSet(key: foregroundScopes).map(
        (scopes) => ScopeObserver(scopes.toList()),
        dispose: (observer) => observer.stop(),
      ),
    ),
  ],
  debugLabel: 'observers',
);

Module appModule(Platform platform) => Module.all(
  modules: [deviceModule, engagementModule(platform), observerModule],
);

// --- Test code -------------------------------------------------------------
//
// In an application this section lives under `test/`. A fake replaces one
// entry by its key, and the entry keeps its position.

final testFakes = Module(
  components: [
    Component<AppScope>(
      key: startScopes.entryKey('lifecycle'),
      dependency: Dependency<AppScope>(create: FakeLifecycleScope.new),
    ),
  ],
);

/// A scope whose start fails.
final class BrokenScope extends LoggedScope {
  BrokenScope() : super('broken');

  @override
  void start() => throw StateError('broken failed to start');
}

/// Adds an entry after the others whose start fails.
final brokenEntry = Module(
  components: [
    Component<AppScope>(
      key: startScopes.entryKey('broken'),
      dependency: Dependency<AppScope>(create: BrokenScope.new),
    ),
  ],
);

Future<void> run(String label, Module module) async {
  print(label);
  // A collection key is in `reads` and never in `requires`, and
  // `contributes` counts the set contributions of the variant.
  log('requires ${module.requires}, contributes ${module.contributes}');
  final scope = await Scope(module: module).initialize();
  log('first foreground');
  scope.get(key: foregroundObserver).start();
  log('dispose');
  await scope.dispose(); // each observer stops before its scopes go
}

Future<void> main() async {
  await run('mobile', appModule(Platform.mobile));
  await run(
    'web: another deep link, no foreground scope',
    appModule(Platform.web),
  );
  await run(
    'test: one entry replaced by its key',
    appModule(Platform.mobile).overriddenBy(testFakes),
  );

  print('a scope fails to start: the scopes that started stop');
  final broken = Scope(module: appModule(Platform.web) + brokenEntry);
  try {
    await broken.initialize();
  } on ActivationException catch (error) {
    log('initialize failed: ${error.cause}');
  } finally {
    await broken.dispose();
  }

  print('a child scope adds a member; the parent does not see it');
  final app = await Scope(module: appModule(Platform.mobile)).initialize();
  final session = await app
      .child(
        module: Module(
          components: [
            Component<AppScope>(
              key: startScopes.entryKey('session'),
              dependency: Dependency<AppScope>(
                create: () => SessionScope('alice'),
              ),
            ),
            Component<List<String>>(
              key: scopeNames,
              dependency: Dependency.requireMap(
                key: startScopes,
              ).map((scopes) => scopes.keys.toList()),
            ),
          ],
        ),
      )
      .initialize();
  final names = session.get(key: scopeNames);
  log('session reads $names');
  log('app observer has ${app.get(key: startObserver).scopes.length} scopes');

  print('a member disposed by itself leaves the collection');
  final appsFlyer = app.nodes.firstWhere(
    (member) => member.isActive && member.value is AppsFlyerScope,
  );
  await appsFlyer.dispose();
  final foreground = app.get(key: foregroundObserver).scopes;
  log('foreground: ${[for (final scope in foreground) scope.name]}');
  await app.dispose();
}
