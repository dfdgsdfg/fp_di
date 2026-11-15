// A lazy value: created on the first force(), released with its owner.
//
// `lazy()` reads the keys at activation, so they stay tracked, and runs the
// steps on the first `force()`. Concurrent first calls share one creation.
// The scope publishes the service that holds the `Lazy`, not the `Lazy`
// itself, so only that service knows that the report is lazy. When a nearer
// scope publishes a new database, the owner activates again: the old report
// is released and the new service builds its report from the new value.
//
// Differences from the fp_di version:
//
// - `force()` is a `TaskEither` of an `Exit`: its `Left` is a `Cause`, so the
//   failure of a step and the dispose failures of its rollback stay together.
// - A force after the release is a `Fail(DisposedLazyFailure)`, not a throw.
//
// Run: dart run packages/fp_di_fpdart/example/lazy.dart
import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';

final class Database {
  const Database(this.name);

  final String name;
}

final class Report {
  Report(this.database) {
    print('  report built on ${database.name}');
  }

  final Database database;

  void close() => print('  report released');
}

/// The service that readers read. It forces the report inside, so a
/// reader never sees whether the report is lazy.
final class Reports {
  Reports(this._report);

  final Lazy<Report> _report;

  bool get built => _report.isCreated;

  Future<Exit<DiFailure, Report>> current() => _report.force().run();
}

Component<Database> database(String name) => Component<Database>(
  dependency: Dependency<Database>(create: () => Database(name)),
);

/// The report is expensive, so it is built only when someone asks for it.
final reports = Component<Reports>(
  dependency: Dependency.require<Database>()
      .map<Report>(Report.new, dispose: (report) => report.close())
      .lazy()
      .map<Reports>(Reports.new),
);

Future<void> main() async {
  final app = Scope(components: [database('main')]);
  // A nearer scope that publishes another database later.
  final scopes = app
      .child(components: [database('replica')])
      .flatMap(
        (replica) => replica
            .child(components: [reports])
            .map((screen) => (replica, screen)),
      );
  switch (scopes) {
    case Left(value: final failure):
      print('child failed: $failure');
    case Right(value: (final replica, final screen)):
      await demo(app, replica, screen);
  }
}

Future<void> demo(Scope app, Scope replica, Scope screen) async {
  print('run');
  await app.run();
  await screen.run();
  final Reports first;
  switch (screen.get<Reports>()) {
    case Left(value: final failure):
      print('  no service: $failure');
      return;
    case Right(value: final reports):
      first = reports;
  }
  print('  built: ${first.built}');

  print('ask twice at once');
  final built = await Future.wait([first.current(), first.current()]);
  print(
    '  same report: ${identical(built[0].toNullable(), built[1].toNullable())}',
  );

  print('a nearer database appears');
  await replica.run();
  switch (await first.current()) {
    case Left(value: final cause):
      print('  the old service is released: ${cause.failures}');
    case Right():
      print('  the old service still answers');
  }
  switch (screen.get<Reports>()) {
    case Left(value: final failure):
      print('  no service: $failure');
    case Right(value: final second):
      print('  new service built: ${second.built}');
      await second.current();
  }

  print('dispose');
  await app.dispose();
}
