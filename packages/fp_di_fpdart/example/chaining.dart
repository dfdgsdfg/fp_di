// Several steps in one component: a dependency chain.
//
// One component can have many steps. Each `map` reads the value of the step
// before it. A step with `dispose` owns its value. The scope releases the
// owned values in reverse order. A record `zip` joins a required read and an
// optional read.
//
// Differences from the fp_di version:
//
// - `Dependency.require<A>().map(...)` replaces `Dependency1` to
//   `Dependency8`.
// - `Dependency.option<Cache>()` replaces `Dependency.maybe`. The value is an
//   `Option<Cache>`, not a nullable `Cache`.
// - `scope.use` runs the scope, runs the program, and disposes the scope.
//
// Run: dart run packages/fp_di_fpdart/example/chaining.dart
import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';

final class Config {
  const Config(this.url);

  final String url;
}

final class Pool {
  Pool(this.url) {
    print('  pool opened on $url');
  }

  final String url;

  void close() => print('  pool closed');
}

final class Repository {
  Repository(this.pool) {
    print('  repository started');
  }

  final Pool pool;

  void close() => print('  repository stopped');
}

final class Cache {}

final class Search {
  Search(this.repository, this.cache);

  final Repository repository;
  final Option<Cache> cache;
}

final config = Component<Config>.value(value: const Config('postgres://local'));

/// Three steps in one component. The pool and the repository are owned, so
/// they release in reverse order: the repository, then the pool.
final repository = Component<Repository>(
  dependency: Dependency.require<Config>()
      .map<String>((config) => config.url) // a plain step
      .map<Pool>(Pool.new, dispose: (pool) => pool.close()) // owned
      .map<Repository>(
        Repository.new,
        dispose: (repo) => repo.close(),
      ), // owned
);

/// A required read and an optional read in one record. No component
/// publishes a `Cache`, so the optional read is `None`.
final search = Component<Search>(
  dependency: (
    Dependency.require<Repository>(),
    Dependency.option<Cache>(),
  ).zip.mapN<Search>(Search.new),
);

/// The program reads the search service while the scope is active.
final ReaderTaskEither<Scope, DiFailure, String> program =
    ReaderTaskEither<Scope, DiFailure, String>(
      (scope) async => scope.get<Search>().map(
        (value) =>
            'search on ${value.repository.pool.url}, cache: ${value.cache}',
      ),
    );

Future<void> main() async {
  final app = Scope(components: [config, repository, search]);

  print('use: run, program, dispose');
  final result = await app.use(program).run();
  result.match(
    (cause) => print('failed:\n${cause.prettyPrint()}'),
    (line) => print('done: $line'),
  );
}
