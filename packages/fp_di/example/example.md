# Examples

Each file in this folder runs with `dart run`. The first one, `basic.dart`,
declares two components in one scope: a database with a `dispose`, and a
repository that reads it. The scope creates the database first and releases
it last.

```dart
import 'package:fp_di/fp_di.dart';

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

/// No input: created on each activation and closed at teardown.
final database = Component<Database>(
  dependency: Dependency<Database>(
    create: () => Database('postgres://local'),
    dispose: (db) => db.close(),
  ),
);

/// One input: the value needs no dispose.
final repository = Component<UserRepository>(
  dependency: Dependency1<Database, UserRepository>(create: UserRepository.new),
);

Future<void> main() async {
  // Declared in any order. Nothing is created yet.
  final app = Scope(module: Module(components: [repository, database]));

  // Dispose in `finally`, so a failure after `initialize` still releases
  // what the scope created.
  try {
    print('initialize');
    await app.initialize();
    print('  repository reads ${app.get<UserRepository>().database.url}');
  } finally {
    // The repository goes first, while the database is still open.
    print('dispose');
    await app.dispose();
  }
}
```

The other examples:

| Example | Shows |
|---|---|
| [`chaining.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/example/chaining.dart) | Several steps in one component |
| [`parallel.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/example/parallel.dart) | Independent members at the same time |
| [`token_key.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/example/token_key.dart) | A token key orders a member after an effect |
| [`session_scope.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/example/session_scope.dart) | A login scope and a logout |
| [`environments.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/example/environments.dart) | Platform, flavor, test fakes, and a two-stage start |
| [`collections.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/example/collections.dart) | Many elements of one interface in one set or map |
| [`shape_export.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/example/shape_export.dart) | The shape of each variant as JSON and Mermaid |
| [`rollback.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/example/rollback.dart) | A failed `initialize` rolls back and tries again |
| [`cancellation.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/example/cancellation.dart) | A logout during a login, a withdrawn value, a failed step |
| [`lazy.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/example/lazy.dart) | A value created on first use |
| [`factory.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/example/factory.dart) | A new value for each call |
| [`cached_factory.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/example/cached_factory.dart) | One value for each id, released with the factory |
| [`diagnostics.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/example/diagnostics.dart) | `describe`, `missing`, `whenActive`, and a forgotten key |
| [`reactive.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/example/reactive.dart) | A nearer publisher reaches only its readers |
