// Environments without a profile concept: three axes and a two-stage boot.
//
// An "environment" mixes three different things. Each one has its own form:
//
// - Platform (mobile, web): a different implementation. Only the few adapters
//   at the platform boundary vary, so they get their own small module.
// - Flavor (dev, stag, prod): mostly configuration. The flavor is a value
//   under `DiKey<Flavor>`, and a component reads it like any other key. A
//   flavor-only member, such as a debug menu, is a Dart `if` in the module.
// - Test: a replacement, not a flavor. The fakes live in test code and replace
//   members with `overriddenBy`. The production modules never contain them.
//
// The application chooses members with plain Dart. Every variant is a value,
// so a test can check each one before anything runs. `requires` lists what no
// member publishes. A key that two members publish is not in `requires`, and
// `Module` does not reject it: only `initialize` throws `DuplicateKeyError`.
// The check therefore also counts the members that publish each key.
import 'package:fp_di/fp_di.dart';

void log(String message) => print('  $message');

enum Flavor { dev, stag, prod }

enum Platform { mobile, web }

// --- Stage 1: boot ---------------------------------------------------------
//
// The flavor is known only at runtime, for example from a remote config. The
// boot scope resolves it before the application module is chosen. With a
// compile-time flavor, such as `String.fromEnvironment('FLAVOR')`, the boot
// module is only `Component<Flavor>.value(...)`.

final class RemoteConfig {
  Future<Flavor> flavor() async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return Flavor.stag;
  }
}

final bootModule = Module(
  components: [
    Component<RemoteConfig>(
      dependency: Dependency<RemoteConfig>(create: RemoteConfig.new),
    ),
    Component<Flavor>(
      dependency: Dependency1<RemoteConfig, Flavor>(
        create: (config) => config.flavor(),
      ),
    ),
  ],
  debugLabel: 'boot',
);

// --- Flavor: configuration -------------------------------------------------

final class ApiConfig {
  const ApiConfig(this.baseUrl);

  factory ApiConfig.of(Flavor flavor) => switch (flavor) {
    Flavor.prod => const ApiConfig('https://api.example.com'),
    Flavor.stag => const ApiConfig('https://stag.api.example.com'),
    Flavor.dev => const ApiConfig('http://localhost:8080'),
  };

  final String baseUrl;
}

final class HttpClient {
  HttpClient(this.config);
  final ApiConfig config;
  Future<String> get(String path) async => 'GET ${config.baseUrl}$path';
}

final class DebugMenu {
  DebugMenu(this.flavor);
  final Flavor flavor;
}

// --- Platform: implementation ----------------------------------------------

abstract interface class ScreenshotGuard {
  String get name;
}

final class NativeScreenshotGuard implements ScreenshotGuard {
  @override
  String get name => 'native FLAG_SECURE';
}

final class WebScreenshotGuard implements ScreenshotGuard {
  @override
  String get name => 'web no-op';
}

// --- Feature: the same in every environment --------------------------------

final class Clock {
  DateTime now() => DateTime.now();
}

final class GreetingUseCase {
  GreetingUseCase(this.http, this.clock, this.guard);
  final HttpClient http;
  final Clock clock;
  final ScreenshotGuard guard;

  Future<String> call() async =>
      '${await http.get('/hello')} at ${clock.now().year} (${guard.name})';
}

// --- Production modules ----------------------------------------------------

/// The members that every environment runs. It reads `DiKey<Flavor>` from
/// the boot scope and `ScreenshotGuard` from the platform module.
final coreModule = Module(
  components: [
    Component<ApiConfig>(
      dependency: Dependency1<Flavor, ApiConfig>(create: ApiConfig.of),
    ),
    Component<HttpClient>(
      dependency: Dependency1<ApiConfig, HttpClient>(create: HttpClient.new),
    ),
    Component<Clock>(dependency: Dependency<Clock>(create: Clock.new)),
    Component<GreetingUseCase>(
      dependency:
          Dependency3<HttpClient, Clock, ScreenshotGuard, GreetingUseCase>(
            create: GreetingUseCase.new,
          ),
    ),
  ],
  debugLabel: 'core',
);

/// Only the adapters at the platform boundary vary.
Module platformModule(Platform platform) => Module(
  components: [
    switch (platform) {
      Platform.mobile => Component<ScreenshotGuard>(
        dependency: Dependency<ScreenshotGuard>(
          create: NativeScreenshotGuard.new,
        ),
      ),
      Platform.web => Component<ScreenshotGuard>(
        dependency: Dependency<ScreenshotGuard>(create: WebScreenshotGuard.new),
      ),
    },
  ],
  debugLabel: 'platform.${platform.name}',
);

/// Members that only some flavors run.
final debugModule = Module(
  components: [
    Component<DebugMenu>(
      dependency: Dependency1<Flavor, DebugMenu>(create: DebugMenu.new),
    ),
  ],
  debugLabel: 'debug',
);

/// The application module of one variant: plain Dart chooses the members.
///
/// `Module.all` keeps the label of each part as the origin of its members,
/// and the result has no label without a `debugLabel` argument. The labels
/// affect `toString` and the shape export; each component keeps its own
/// label in diagnostics.
Module appModule({required Flavor flavor, required Platform platform}) =>
    Module.all(
      modules: [
        coreModule,
        platformModule(platform),
        if (flavor != Flavor.prod) debugModule,
      ],
    );

/// A root without a boot stage, for a compile-time flavor and for tests.
///
/// One argument gives both the `DiKey<Flavor>` value and the choice of
/// members, so the two cannot disagree.
Module appRoot({required Flavor flavor, required Platform platform}) =>
    Module(
      components: [Component<Flavor>.value(value: flavor)],
      debugLabel: 'flavor',
    ) +
    appModule(flavor: flavor, platform: platform);

// --- Test code -------------------------------------------------------------
//
// In an application this section lives under `test/`, or in a
// `lib/testing.dart` library that only test code imports. The production
// modules above do not refer to it.

final class FixedClock implements Clock {
  @override
  DateTime now() => DateTime(2000);
}

/// Each fake replaces the member that publishes the same key. A fake whose
/// key no member publishes throws an `ArgumentError`, so a renamed key fails
/// instead of adding a member.
final testFakes = Module(
  components: [
    Component<Clock>(dependency: Dependency<Clock>(create: FixedClock.new)),
  ],
  debugLabel: 'fakes',
);

/// The keys that more than one member of [module] publishes.
Set<DiKeyBase> duplicatesOf(Module module) {
  final seen = <DiKeyBase>{};
  return {
    for (final member in module.components)
      if (member.key case final key? when !seen.add(key)) key,
  };
}

/// The check that a test runs for every variant. Each key that the
/// application module requires comes from the boot scope, and no key has two
/// publishers.
void checkEveryVariant() {
  for (final flavor in Flavor.values) {
    for (final platform in Platform.values) {
      final module = appModule(flavor: flavor, platform: platform);
      final missing = module.requires.difference(bootModule.publishes);
      final duplicates = duplicatesOf(module);
      if (missing.isNotEmpty || duplicates.isNotEmpty) {
        throw StateError(
          '${flavor.name}/${platform.name}: '
          'misses $missing, publishes twice $duplicates',
        );
      }
    }
  }
  log('every flavor and platform is complete');

  // A variant that forgets the platform module reports the gap before it
  // runs.
  log(
    'core alone misses ${coreModule.requires.difference(bootModule.publishes)}',
  );
  // A variant that adds the platform module twice passes the `requires`
  // check, and only the duplicate check reports it.
  final twice =
      coreModule +
      platformModule(Platform.mobile) +
      platformModule(Platform.web);
  log(
    'two platforms: misses '
    '${twice.requires.difference(bootModule.publishes)}, '
    'publishes twice ${duplicatesOf(twice)}',
  );
}

Future<void> main() async {
  print('check the variants');
  checkEveryVariant();

  print('stage 1: resolve the flavor');
  final boot = await Scope(module: bootModule).initialize();
  final flavor = boot.get<Flavor>();
  log('flavor: ${flavor.name}');

  print('stage 2: the application of that flavor');
  // Choose the members from the flavor that the boot scope publishes. A second
  // source of the flavor could disagree with the value that components read.
  final app = await boot
      .child(
        module: appModule(flavor: flavor, platform: Platform.mobile),
      )
      .initialize();
  log(await app.get<GreetingUseCase>()());
  log('debug menu: ${app.maybeGet<DebugMenu>() != null}');

  print('test: the same graph with fakes');
  final test = await Scope(
    module: appRoot(
      flavor: Flavor.dev,
      platform: Platform.web,
    ).overriddenBy(testFakes),
  ).initialize();
  log(await test.get<GreetingUseCase>()());

  await test.dispose();
  await boot.dispose(); // disposes the application scope first
}
