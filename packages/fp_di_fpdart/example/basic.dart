// The smallest application: two components in one scope.
//
// A component states the type that it publishes. The type is also its key.
// Its dependency states how the runtime creates the value. The repository
// reads the database, so the runtime creates the database first and releases
// it last. The declaration order does not matter.
//
// Differences from the fp_di version:
//
// - `Dependency.require<Database>().map(...)` replaces `Dependency1`.
// - `scope.use` replaces `try` and `finally`. It runs the scope, runs the
//   program, and always disposes the scope.
// - `scope.get` returns an `Either`. Nothing throws.
//
// Run: dart run packages/fp_di_fpdart/example/basic.dart
import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';

final class Database {
  Database(this.url) {
    print('  database opened');
  }

  final String url;

  void close() => print('  database closed');
}

final class UserRepository {
  UserRepository(this.database);

  final Database database;
}

/// No input: the scope creates it when it runs and closes it at the end.
final database = Component<Database>(
  dependency: Dependency<Database>(
    create: () => Database('postgres://local'),
    dispose: (db) => db.close(),
  ),
);

/// One input: the value needs no dispose.
final repository = Component<UserRepository>(
  dependency: Dependency.require<Database>().map<UserRepository>(
    UserRepository.new,
  ),
);

/// The program that runs while the scope is active. It reads a value and
/// returns the database url, or the failure of the read.
final ReaderTaskEither<Scope, DiFailure, String> program =
    ReaderTaskEither<Scope, DiFailure, String>(
      (scope) async => scope.get<UserRepository>().map((repo) {
        print('  repository reads ${repo.database.url}');
        return repo.database.url;
      }),
    );

Future<void> main() async {
  // The list has no order. Nothing exists yet.
  final app = Scope(components: [repository, database]);

  print('use: run, program, dispose');
  final result = await app.use(program).run();

  // The scope closed the database before `use` returned.
  result.match(
    (cause) => print('failed:\n${cause.prettyPrint()}'),
    (url) => print('done: $url'),
  );
  print('phase: ${app.phase.name}');
}
