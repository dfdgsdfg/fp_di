// Independent members of a scope activate and release concurrently.
//
// Independence is read off the shapes: no member reads a key that another
// member publishes. The three slow connections below therefore acquire at the
// same time, so the initialize call takes about as long as the slowest one,
// not the sum. They close at the same time too: a member releases after the
// members that read it, and these read nothing of each other.
import 'package:fp_di/fp_di.dart';

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

  /// Waits for half of the cost, then reports that the connection is released.
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

Component<T> connection<T extends Connection>(
  T Function() make,
  String label,
) => Component<T>(
  dependency: Dependency<T>(
    create: () async {
      final connection = make();
      await connection.open();
      return connection;
    },
    dispose: (connection) => connection.close(),
  ),
  debugLabel: label,
);

/// Three independent connections. Their costs differ, so the ready lines show
/// the order of completion, not the declaration order.
final infrastructure = Module(
  components: [
    connection(Database.new, 'database'),
    connection(Cache.new, 'cache'),
    connection(Search.new, 'search'),
  ],
  debugLabel: 'infrastructure',
);

Future<void> main() async {
  final app = Scope(module: infrastructure);

  final started = DateTime.now();
  await app.initialize();
  final elapsed = DateTime.now().difference(started);

  // 200ms + 100ms + 150ms in roughly 200ms, not 450ms.
  final values = [for (final member in app.nodes) member.value];
  print('elapsed: ${elapsed.inMilliseconds}ms for $values');

  // 100ms + 50ms + 75ms of closing in roughly 100ms, not 225ms.
  final closing = DateTime.now();
  await app.dispose();
  print('closed in ${DateTime.now().difference(closing).inMilliseconds}ms');
}
