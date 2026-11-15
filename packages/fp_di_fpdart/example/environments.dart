// Environments without a profile concept: three axes and a two-stage boot.
//
// An "environment" mixes three different things. Each one has its own form:
//
// - Platform (mobile, web): a different implementation. Only the few adapters
//   at the platform boundary vary, so they get their own small list.
// - Flavor (dev, stag, prod): mostly configuration. The flavor is a value
//   under `DiKey<Flavor>`, and a component reads it like any other key. A
//   flavor-only component, such as a debug menu, is a Dart `if` in the list.
// - Test: a replacement, not a flavor. The fakes live in test code and replace
//   components with `overriddenBy`. The production lists never contain them.
//
// The application chooses components with plain Dart. Every variant is a
// value, so a test can check each variant before anything runs. `requires`
// lists the keys that no component of the list publishes. `requires` does not
// find a key that two components publish. Only `run` finds it, as a
// `Fail(DuplicateKeyFailure)`. The run also reports every undeclared key
// together, joined with `Both`.
//
// Differences from the fp_di version:
//
// - A `Module` becomes a plain list of components. Spread joins the lists:
//   `[...core, ...platform]`.
// - `overriddenBy` returns an `Exit`. A fake whose key no single component
//   publishes is a `Fail(UnmatchedOverrideFailure)`, so a renamed key fails
//   instead of adding a component.
// - The duplicate check is `run()`, not a count of the members.
// - `scope.get` returns an `Either`, and `getOption` returns an `Option`.
//
// Run: dart run packages/fp_di_fpdart/example/environments.dart
import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';

void log(String message) => print('  $message');

String indent(String text) =>
    text.split('\n').map((line) => '    $line').join('\n');

enum Flavor { dev, stag, prod }

enum Platform { mobile, web }

// --- Stage 1: boot ---------------------------------------------------------
//
// The flavor is known only at runtime, for example from a remote config. The
// boot scope resolves it before the application list is chosen. With a
// compile-time flavor, such as `String.fromEnvironment('FLAVOR')`, the boot
// list is only `Component<Flavor>.value(...)`.

final class RemoteConfig {
  Future<Flavor> flavor() async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return Flavor.stag;
  }
}

final bootComponents = <Component<Object?>>[
  Component<RemoteConfig>(
    dependency: Dependency<RemoteConfig>(create: RemoteConfig.new),
  ),
  Component<Flavor>(
    dependency: Dependency.require<RemoteConfig>().mapTask<Flavor>(
      (config) => Task(config.flavor),
    ),
  ),
];

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

// --- Production lists ------------------------------------------------------

/// The components that every environment runs. They read `DiKey<Flavor>` from
/// the boot scope and `ScreenshotGuard` from the platform list.
final coreComponents = <Component<Object?>>[
  Component<ApiConfig>(
    dependency: Dependency.require<Flavor>().map<ApiConfig>(ApiConfig.of),
  ),
  Component<HttpClient>(
    dependency: Dependency.require<ApiConfig>().map<HttpClient>(HttpClient.new),
  ),
  Component<Clock>(dependency: Dependency<Clock>(create: Clock.new)),
  Component<GreetingUseCase>(
    dependency: (
      Dependency.require<HttpClient>(),
      Dependency.require<Clock>(),
      Dependency.require<ScreenshotGuard>(),
    ).zip.mapN<GreetingUseCase>(GreetingUseCase.new),
  ),
];

/// Only the adapters at the platform boundary vary.
List<Component<Object?>> platformComponents(Platform platform) => [
  switch (platform) {
    Platform.mobile => Component<ScreenshotGuard>(
      debugLabel: 'platform.mobile',
      dependency: Dependency<ScreenshotGuard>(
        create: NativeScreenshotGuard.new,
      ),
    ),
    Platform.web => Component<ScreenshotGuard>(
      debugLabel: 'platform.web',
      dependency: Dependency<ScreenshotGuard>(create: WebScreenshotGuard.new),
    ),
  },
];

/// Components that only some flavors run.
final debugComponents = <Component<Object?>>[
  Component<DebugMenu>(
    dependency: Dependency.require<Flavor>().map<DebugMenu>(DebugMenu.new),
  ),
];

/// The application list of one variant: plain Dart chooses the components.
List<Component<Object?>> appComponents({
  required Flavor flavor,
  required Platform platform,
}) => [
  ...coreComponents,
  ...platformComponents(platform),
  if (flavor != Flavor.prod) ...debugComponents,
];

/// A root without a boot stage, for a compile-time flavor and for tests.
///
/// One argument gives both the `DiKey<Flavor>` value and the choice of
/// components, so the two cannot disagree.
List<Component<Object?>> appRoot({
  required Flavor flavor,
  required Platform platform,
}) => [
  Component<Flavor>.value(value: flavor),
  ...appComponents(flavor: flavor, platform: platform),
];

// --- Test code -------------------------------------------------------------
//
// In an application this section lives under `test/`, or in a
// `lib/testing.dart` library that only test code imports. The production
// lists above do not refer to it.

final class FixedClock implements Clock {
  @override
  DateTime now() => DateTime(2000);
}

/// Each fake replaces the component that publishes the same key.
final testFakes = <Component<Object?>>[
  Component<Clock>(dependency: Dependency<Clock>(create: FixedClock.new)),
];

/// A fake for a key that the application does not publish.
final strayFakes = <Component<Object?>>[
  Component<RemoteConfig>(
    dependency: Dependency<RemoteConfig>(create: RemoteConfig.new),
  ),
];

// --- Checks ----------------------------------------------------------------

/// Disposes a scope and prints the cause of a failure.
Future<void> close(Scope scope) async {
  final stopped = await scope.dispose();
  stopped.match((cause) => print(indent(cause.prettyPrint())), (_) {});
}

/// Runs [components] in a new scope and disposes the scope. The result is
/// the cause of the failure, or `None`.
Future<Option<Cause<DiFailure>>> tryRun(
  List<Component<Object?>> components,
) async {
  final scope = Scope(components: components);
  final started = await scope.run();
  await close(scope);
  return started.match(Some.new, (_) => const None());
}

/// Checks one variant: it needs only keys that the boot scope publishes, and
/// it runs.
Future<Option<String>> checkVariant(Flavor flavor, Platform platform) async {
  final name = '${flavor.name}/${platform.name}';
  final missing = appComponents(
    flavor: flavor,
    platform: platform,
  ).requires.difference(bootComponents.publishes);
  if (missing.isNotEmpty) return Some('$name misses $missing');
  final failure = await tryRun(appRoot(flavor: flavor, platform: platform));
  return failure.map((cause) => '$name fails:\n${indent(cause.prettyPrint())}');
}

/// The check that a test runs for every variant.
Future<void> checkEveryVariant() async {
  final problems = <String>[];
  for (final flavor in Flavor.values) {
    for (final platform in Platform.values) {
      if (await checkVariant(flavor, platform) case Some(value: final text)) {
        problems.add(text);
      }
    }
  }
  if (problems.isEmpty) log('every flavor and platform is complete');
  problems.forEach(log);

  // A variant that forgets the platform list reports the gap before it runs.
  log(
    'core alone misses '
    '${coreComponents.requires.difference(bootComponents.publishes)}',
  );

  // A variant that adds the platform list twice passes the `requires` check.
  // Only the run reports the duplicate key.
  final twice = [
    ...coreComponents,
    ...platformComponents(Platform.mobile),
    ...platformComponents(Platform.web),
  ];
  log(
    'two platforms: misses '
    '${twice.requires.difference(bootComponents.publishes)}',
  );
  final duplicate = await tryRun([
    Component<Flavor>.value(value: Flavor.dev),
    ...twice,
  ]);
  duplicate.match(
    () => log('two platforms: no failure'),
    (cause) => log('two platforms fail:\n${indent(cause.prettyPrint())}'),
  );

  // A variant that has no flavor and no platform reports both gaps together.
  final bare = await tryRun(coreComponents);
  bare.match(
    () => log('core alone: no failure'),
    (cause) => log('core alone fails:\n${indent(cause.prettyPrint())}'),
  );
}

// --- Stages ----------------------------------------------------------------

/// Reads the greeting use case of [scope] and calls it.
Future<String> greet(Scope scope) async =>
    switch (scope.get<GreetingUseCase>()) {
      Left(value: final failure) => 'unavailable: $failure',
      Right(value: final useCase) => await useCase(),
    };

/// Stage 2: the application of the flavor that the boot scope published.
Future<void> startApp(Scope boot, Flavor flavor) async {
  print('stage 2: the application of that flavor');
  // Choose the components from the flavor that the boot scope publishes. A
  // second source of the flavor could disagree with the value that
  // components read.
  final child = boot.child(
    components: appComponents(flavor: flavor, platform: Platform.mobile),
  );
  // `child` is a `Left` only for a scope that is disposing or disposed.
  final Scope app;
  switch (child) {
    case Left(value: final failure):
      print(indent('child failed: $failure'));
      return;
    case Right(value: final scope):
      app = scope;
  }
  switch (await app.run()) {
    case Left(value: final cause):
      print(indent(cause.prettyPrint()));
      return;
    case Right():
      break;
  }
  log(await greet(app));
  log('debug menu: ${app.getOption<DebugMenu>().isSome()}');
}

/// The same graph with fakes, in a scope of its own.
Future<void> runTest() async {
  print('test: the same graph with fakes');
  final root = appRoot(flavor: Flavor.dev, platform: Platform.web);
  log('stray fake:');
  switch (root.overriddenBy(strayFakes)) {
    case Left(value: final cause):
      print(indent(cause.prettyPrint()));
    case Right():
      log('unexpected: the stray fake replaced nothing');
  }
  switch (root.overriddenBy(testFakes)) {
    case Left(value: final cause):
      print(indent(cause.prettyPrint()));
    case Right(value: final components):
      final test = Scope(components: components);
      switch (await test.run()) {
        case Left(value: final cause):
          print(indent(cause.prettyPrint()));
        case Right():
          log(await greet(test));
      }
      await close(test);
  }
}

Future<void> main() async {
  print('check the variants');
  await checkEveryVariant();

  print('stage 1: resolve the flavor');
  final boot = Scope(components: bootComponents);
  switch (await boot.run()) {
    case Left(value: final cause):
      print(indent(cause.prettyPrint()));
      return;
    case Right():
      break;
  }
  switch (boot.get<Flavor>()) {
    case Left(value: final failure):
      log('no flavor: $failure');
    case Right(value: final flavor):
      log('flavor: ${flavor.name}');
      await startApp(boot, flavor);
  }

  await runTest();

  print('dispose the boot scope: the application scope goes first');
  await close(boot);
}
