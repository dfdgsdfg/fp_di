// Several steps in one component: a Dependency chain.
//
// `Dependency1` to `Dependency8` cover one step. A chain adds steps: each
// `map` reads the previous value, a `map` with `dispose` owns its value, and
// the owned steps release in reverse order. A record `zip` mixes a required
// and an optional read.
import 'package:fp_di/fp_di.dart';

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
  final Cache? cache;
}

final config = Component<Config>.value(value: const Config('postgres://local'));

/// Three steps in one node. The pool and the repository are owned, so they
/// release in reverse order: the repository, then the pool.
final repository = Component<Repository>(
  dependency: Dependency.require<Config>()
      .map((config) => config.url) // a plain step
      .map(Pool.new, dispose: (pool) => pool.close()) // owned
      .map(Repository.new, dispose: (repo) => repo.close()), // owned
);

/// A required read and an optional read in one record. No component
/// publishes a `Cache`, so the optional read is `null`.
final search = Component<Search>(
  dependency: (
    Dependency.require<Repository>(),
    Dependency.maybe<Cache>(),
  ).zip.mapN(Search.new),
);

Future<void> main() async {
  final app = Scope(module: Module(components: [config, repository, search]));

  print('initialize');
  await app.initialize();
  final value = app.get<Search>();
  print('  search on ${value.repository.pool.url}, cache: ${value.cache}');

  print('dispose');
  await app.dispose();
}
