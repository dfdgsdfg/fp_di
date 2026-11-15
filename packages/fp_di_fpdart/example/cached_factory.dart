// A cached factory: one value per id, released with the scope.
//
// A plain factory returns a new value on each call, and the caller owns it.
// A cached factory keeps its values, so the cache needs an owner. Here a
// component owns the cache and publishes only its lookup function. The scope
// releases the cache when the scope disposes. The cache then releases each
// view that it holds.
//
// Differences from the fp_di version:
//
// - The cache lives as long as the scope. The example does not show a cache
//   that a new publisher replaces. Such a cache would release and build again,
//   like the greeter of `reactive.dart`.
// - The lookup of a released cache returns `None`. The fp_di version throws a
//   `StateError`.
// - `Dependency.require<Database>().map(..., dispose: ...)` replaces
//   `Dependency1`.
//
// Run: dart run packages/fp_di_fpdart/example/cached_factory.dart
import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';

final class Database {
  const Database(this.name);

  final String name;
}

final class RowView {
  RowView(this.database, this.id) {
    print('  row $id on ${database.name}');
  }

  final Database database;
  final String id;

  void close() => print('  row $id on ${database.name} released');
}

/// The views of one scope, by id.
final class RowViewCache {
  RowViewCache(this._database);

  final Database _database;
  final _views = <String, RowView>{};
  var _closed = false;

  /// The view of [id]: the cached one, or a new one on the first call.
  ///
  /// A reader that kept the function after the scope ended gets `None`. It
  /// must not fill a cache that nothing releases.
  Option<RowView> view(String id) => _closed
      ? const None()
      : Some(_views.putIfAbsent(id, () => RowView(_database, id)));

  void close() {
    _closed = true;
    for (final view in _views.values) {
      view.close();
    }
    _views.clear();
  }
}

/// The published type states a factory, not a cache.
typedef RowViewFactory = Option<RowView> Function(String id);

Component<Database> database(String name) =>
    Component<Database>.value(value: Database(name));

/// The first step owns the cache. The second step publishes its lookup.
final rowViewFactory = Component<RowViewFactory>(
  dependency: Dependency.require<Database>()
      .map<RowViewCache>(RowViewCache.new, dispose: (cache) => cache.close())
      .map<RowViewFactory>((cache) => cache.view),
);

Future<void> main() async {
  final app = Scope(components: [database('main')]);
  // A nearer scope that publishes another database. `child` is a `Left` only
  // for a scope that is disposing or disposed.
  final scopes = app
      .child(components: [database('replica')])
      .flatMap(
        (replica) => replica
            .child(components: [rowViewFactory])
            .map((feature) => (replica, feature)),
      );
  switch (scopes) {
    case Left(value: final failure):
      print('child failed: $failure');
    case Right(value: (final replica, final feature)):
      await demo(app, replica, feature);
  }
}

Future<void> demo(Scope app, Scope replica, Scope feature) async {
  print('run');
  final started = await TaskEither<Cause<DiFailure>, Scope>(app.run)
      .flatMap((_) => TaskEither<Cause<DiFailure>, Scope>(replica.run))
      .flatMap((_) => TaskEither<Cause<DiFailure>, Scope>(feature.run))
      .run();
  switch (started) {
    case Left(value: final cause):
      print(cause.prettyPrint());
      return;
    case Right():
      break;
  }

  // Keep the lookup function after the scope ends.
  final Option<RowViewFactory> kept = feature.getOption<RowViewFactory>();
  if (kept case Some(value: final view)) {
    final first = view('42').toNullable();
    print(
      '  same id, same value: ${identical(first, view('42').toNullable())}',
    );
    print(
      '  other id, other value: ${!identical(first, view('7').toNullable())}',
    );

    print('dispose the feature scope');
    final stopped = await feature.dispose();
    stopped.match((cause) => print(cause.prettyPrint()), (_) {});
    print('  the old factory is released: ${view('42').isNone()}');
    print(
      '  the scope publishes nothing: ${feature.getOption<RowViewFactory>()}',
    );
  }

  print('dispose');
  final stopped = await app.dispose();
  stopped.match((cause) => print(cause.prettyPrint()), (_) {});
}
