// Wiring checks of application variants, without starting a runtime.
//
// A list of components is a value with a derived shape, so a test can check
// every variant (flavor, platform, an optional feature) before anything is
// created. Production needs no such check: `run` rejects an undeclared or a
// duplicate key by itself. The check catches a variant that only a rarely run
// combination would expose, and it holds only if it agrees with `run`, which
// this test also asserts for every variant.
import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

enum _Flavor { dev, prod }

enum _Platform { mobile, web }

final class _Config {
  const _Config(this.flavor);
  final _Flavor flavor;
}

final class _Api {
  _Api(this.config);
  final _Config config;
}

abstract interface class _Storage {}

final class _FileStorage implements _Storage {}

final class _WebStorage implements _Storage {}

final class _Repository {
  _Repository(this.api, this.storage);
  final _Api api;
  final _Storage storage;
}

final class _DebugPanel {
  _DebugPanel(this.repository);
  final _Repository repository;
}

/// The parent scope that the application runs in. It publishes `_Config`.
List<Component<Object?>> _boot(_Flavor flavor) => [
  Component<_Config>.value(key: DiKey<_Config>(), value: _Config(flavor)),
];

final List<Component<Object?>> _core = [
  Component<_Api>(
    key: DiKey<_Api>(),
    dependency: Dependency.require<_Config>().map<_Api>(_Api.new),
  ),
  Component<_Repository>(
    key: DiKey<_Repository>(),
    dependency: Dependency.require2<_Api, _Storage>().mapN<_Repository>(
      _Repository.new,
    ),
  ),
];

List<Component<Object?>> _platform(_Platform platform) => [
  switch (platform) {
    _Platform.mobile => Component<_Storage>(
      key: DiKey<_Storage>(),
      dependency: Dependency<_Storage>(create: _FileStorage.new),
    ),
    _Platform.web => Component<_Storage>(
      key: DiKey<_Storage>(),
      dependency: Dependency<_Storage>(create: _WebStorage.new),
    ),
  },
];

final List<Component<Object?>> _debug = [
  Component<_DebugPanel>(
    key: DiKey<_DebugPanel>(),
    dependency: Dependency.require<_Repository>().map<_DebugPanel>(
      _DebugPanel.new,
    ),
  ),
];

/// The application of one variant, chosen with plain Dart.
List<Component<Object?>> _app(_Flavor flavor, _Platform platform) => [
  ..._core,
  ..._platform(platform),
  if (flavor == _Flavor.dev) ..._debug,
];

/// The problems that the component values show, without a runtime.
({Set<DiKeyBase> missing, Set<DiKeyBase> duplicates}) _check(
  List<Component<Object?>> app, {
  required List<Component<Object?>> parent,
}) {
  final seen = <DiKeyBase>{};
  return (
    missing: app.requires.difference(parent.publishes),
    duplicates: {
      for (final member in app)
        if (member.hasKey && !seen.add(member.key)) member.key,
    },
  );
}

/// What `run` says about the same variant: null when it succeeds.
Future<DiFailure?> _run(
  List<Component<Object?>> app, {
  required List<Component<Object?>> parent,
}) async {
  final root = Scope(components: parent);
  rightOf(await root.run());
  final DiFailure? failure;
  try {
    final child = root.kid(components: app);
    failure = (await child.run()).match(
      (cause) => cause.failures.first,
      (_) => null,
    );
  } finally {
    await root.dispose();
  }
  return failure;
}

void main() {
  group('every variant is complete', () {
    // from: variant_wiring_test.dart: ${flavor.name}/${platform.name}
    for (final flavor in _Flavor.values) {
      for (final platform in _Platform.values) {
        test('${flavor.name}/${platform.name}', () async {
          final app = _app(flavor, platform);
          final parent = _boot(flavor);
          final problems = _check(app, parent: parent);
          expect(problems.missing, isEmpty);
          expect(problems.duplicates, isEmpty);
          expect(
            app.publishes.contains(DiKey<_DebugPanel>()),
            flavor == _Flavor.dev,
            reason: 'an optional feature is a Dart if',
          );
          // The static check agrees with the runtime.
          expect(await _run(app, parent: parent), isNull);
        });
      }
    }
  });

  group('a broken variant is reported before it runs, as run does', () {
    test('a missing platform module', () async {
      // from: variant_wiring_test.dart: a missing platform module
      final parent = _boot(_Flavor.prod);
      final problems = _check(_core, parent: parent);
      expect(problems.missing, {DiKey<_Storage>()});
      expect(await _run(_core, parent: parent), isA<UndeclaredKeyFailure>());
    });

    test('two platform modules', () async {
      // from: variant_wiring_test.dart: two platform modules
      final parent = _boot(_Flavor.prod);
      final twice = [
        ..._core,
        ..._platform(_Platform.mobile),
        ..._platform(_Platform.web),
      ];
      final problems = _check(twice, parent: parent);
      // A key with two publishers is not in requires; only the count shows it.
      expect(problems.missing, isEmpty);
      expect(problems.duplicates, {DiKey<_Storage>()});
      expect(await _run(twice, parent: parent), isA<DuplicateKeyFailure>());
    });

    test('a parent that does not publish the configuration', () async {
      // from: variant_wiring_test.dart: a parent that does not publish the
      // configuration
      final parent = <Component<Object?>>[];
      final app = _app(_Flavor.prod, _Platform.web);
      expect(_check(app, parent: parent).missing, {DiKey<_Config>()});
      expect(await _run(app, parent: parent), isA<UndeclaredKeyFailure>());
    });
  });

  test('fakes replace components of every variant', () {
    // from: variant_wiring_test.dart: fakes replace members of every variant
    final fakes = <Component<Object?>>[
      Component<_Storage>(
        key: DiKey<_Storage>(),
        dependency: Dependency<_Storage>(create: _WebStorage.new),
      ),
    ];
    for (final flavor in _Flavor.values) {
      for (final platform in _Platform.values) {
        final app = rightOf(_app(flavor, platform).overriddenBy(fakes));
        expect(_check(app, parent: _boot(flavor)).duplicates, isEmpty);
      }
    }
  });
}
