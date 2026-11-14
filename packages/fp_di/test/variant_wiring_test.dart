// Wiring checks of application variants, without starting a runtime.
//
// A module is a value with a derived shape, so a test can check every
// variant (flavor, platform, an optional feature) before anything is
// created. Production needs no such check: `initialize` rejects an
// undeclared or a duplicate key by itself. The check catches a variant that
// only a rarely run combination would expose, and it holds only if it
// agrees with `initialize`, which this test also asserts for every variant.
import 'package:fp_di/fp_di.dart';
import 'package:test/test.dart';

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
Module _boot(_Flavor flavor) => Module(
  components: [
    Component<_Config>.value(key: DiKey<_Config>(), value: _Config(flavor)),
  ],
);

final _core = Module(
  components: [
    Component<_Api>(
      key: DiKey<_Api>(),
      dependency: Dependency1(create: _Api.new),
    ),
    Component<_Repository>(
      key: DiKey<_Repository>(),
      dependency: Dependency2(create: _Repository.new),
    ),
  ],
);

Module _platform(_Platform platform) => Module(
  components: [
    switch (platform) {
      _Platform.mobile => Component<_Storage>(
        key: DiKey<_Storage>(),
        dependency: Dependency(create: _FileStorage.new),
      ),
      _Platform.web => Component<_Storage>(
        key: DiKey<_Storage>(),
        dependency: Dependency(create: _WebStorage.new),
      ),
    },
  ],
);

final _debug = Module(
  components: [
    Component<_DebugPanel>(
      key: DiKey<_DebugPanel>(),
      dependency: Dependency1(create: _DebugPanel.new),
    ),
  ],
);

/// The application of one variant, chosen with plain Dart.
Module _app(_Flavor flavor, _Platform platform) => Module.all(
  modules: [_core, _platform(platform), if (flavor == _Flavor.dev) _debug],
);

/// The problems that the module values show, without a runtime.
({Set<DiKeyBase> missing, Set<DiKeyBase> duplicates}) _check(
  Module app, {
  required Module parent,
}) {
  final seen = <DiKeyBase>{};
  return (
    missing: app.requires.difference(parent.publishes),
    duplicates: {
      for (final member in app.components)
        if (member.key case final key? when !seen.add(key)) key,
    },
  );
}

/// What `initialize` says about the same variant: null when it succeeds.
Future<Object?> _initialize(Module app, {required Module parent}) async {
  final root = await Scope(module: parent).initialize();
  try {
    await root.child(module: app).initialize();
    return null;
  } on Object catch (error) {
    return error;
  } finally {
    await root.dispose();
  }
}

void main() {
  group('every variant is complete', () {
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
          expect(await _initialize(app, parent: parent), isNull);
        });
      }
    }
  });

  group('a broken variant is reported before it runs, as initialize does', () {
    test('a missing platform module', () async {
      final parent = _boot(_Flavor.prod);
      final problems = _check(_core, parent: parent);
      expect(problems.missing, {DiKey<_Storage>()});
      expect(
        await _initialize(_core, parent: parent),
        isA<UndeclaredKeyError>(),
      );
    });

    test('two platform modules', () async {
      final parent = _boot(_Flavor.prod);
      final twice =
          _core + _platform(_Platform.mobile) + _platform(_Platform.web);
      final problems = _check(twice, parent: parent);
      // A key with two publishers is not in requires; only the count shows it.
      expect(problems.missing, isEmpty);
      expect(problems.duplicates, {DiKey<_Storage>()});
      expect(
        await _initialize(twice, parent: parent),
        isA<DuplicateKeyError>(),
      );
    });

    test('a parent that does not publish the configuration', () async {
      final parent = Module(components: const []);
      final app = _app(_Flavor.prod, _Platform.web);
      expect(_check(app, parent: parent).missing, {DiKey<_Config>()});
      expect(await _initialize(app, parent: parent), isA<UndeclaredKeyError>());
    });
  });

  test('fakes replace members of every variant', () {
    final fakes = Module(
      components: [
        Component<_Storage>(
          key: DiKey<_Storage>(),
          dependency: Dependency(create: _WebStorage.new),
        ),
      ],
    );
    for (final flavor in _Flavor.values) {
      for (final platform in _Platform.values) {
        final app = _app(flavor, platform).overriddenBy(fakes);
        expect(_check(app, parent: _boot(flavor)).duplicates, isEmpty);
      }
    }
  });
}
