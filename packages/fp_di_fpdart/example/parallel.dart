// Independent components of a scope activate and release at the same time.
//
// The runtime reads independence from the keys. No component reads a key that
// another component publishes. The three slow connections below read nothing,
// so they start together. The `run` call takes about as long as the
// slowest connection, not the sum. They close together too: a component
// releases after the components that read it, and these read nothing of each
// other.
//
// Differences from the fp_di version:
//
// - `run()` and `dispose()` return an `Exit`. The example handles each one
//   with `match`.
// - `scope.get` is an `Either`, and `scope.nodes` lists the node handles.
//
// Run: dart run packages/fp_di_fpdart/example/parallel.dart
import 'package:fp_di_fpdart/fp_di_fpdart.dart';

/// A connection that has a name and a cost. It stands for real I/O, so it
/// prints when it is ready and when it is released.
abstract base class Connection {
  Connection(this.name, this.cost);

  final String name;
  final Duration cost;

  /// Waits for the whole cost, then reports that the connection is ready.
  Future<void> open() async {
    await Future<void>.delayed(cost);
    print('  $name ready');
  }

  /// Waits for half of the cost, then reports that the connection is
  /// released.
  Future<void> close() async {
    await Future<void>.delayed(cost ~/ 2);
    print('  $name released');
  }

  @override
  String toString() => name;
}

final class Database extends Connection {
  Database() : super('database', const Duration(milliseconds: 200));
}

final class Cache extends Connection {
  Cache() : super('cache', const Duration(milliseconds: 100));
}

final class Search extends Connection {
  Search() : super('search', const Duration(milliseconds: 150));
}

Future<T> openConnection<T extends Connection>(T Function() make) async {
  final connection = make();
  await connection.open();
  return connection;
}

Component<T> connection<T extends Connection>(
  T Function() make,
  String label,
) => Component<T>(
  dependency: Dependency<T>(
    create: () => openConnection<T>(make),
    dispose: (connection) => connection.close(),
  ),
  debugLabel: label,
);

/// Three independent connections. Their costs differ, so the ready lines show
/// the order of completion, not the declaration order.
final infrastructure = <Component<Object?>>[
  connection<Database>(Database.new, 'database'),
  connection<Cache>(Cache.new, 'cache'),
  connection<Search>(Search.new, 'search'),
];

Future<void> main() async {
  final app = Scope(components: infrastructure);

  final starting = Stopwatch()..start();
  final started = await app.run();
  starting.stop();

  started.match((cause) => print('failed:\n${cause.prettyPrint()}'), (scope) {
    // 200 ms + 100 ms + 150 ms in about 200 ms, not 450 ms.
    final values = [
      scope.get<Database>(),
      scope.get<Cache>(),
      scope.get<Search>(),
    ];
    print(
      'run took ${starting.elapsedMilliseconds} ms for '
      '${[for (final value in values) ?value.toNullable()]}',
    );
  });

  // 100 ms + 50 ms + 75 ms of closing in about 100 ms, not 225 ms.
  final closing = Stopwatch()..start();
  final stopped = await app.dispose();
  closing.stop();
  stopped.match(
    (cause) => print('failed:\n${cause.prettyPrint()}'),
    (_) => print('dispose took ${closing.elapsedMilliseconds} ms'),
  );
}
