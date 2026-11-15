// Seeing why a scope failed, and what a scope can still tell you.
//
// This package has no `describe`, no `missing`, and no `whenActive`. A scope
// runs once, and it checks its components before it creates any value. The
// check reports a problem as a `Cause`, so a forgotten key cannot leave a
// reader waiting. This example shows five tools:
//
// 1. The check accumulates every duplicate key and every undeclared key. The
//    cause joins them with `Both`.
// 2. A cycle is a `Fail(DependencyCycleFailure)`. The check for a cycle runs
//    only when the other checks pass.
// 3. `prettyPrint()` shows the tree. `failures` lists the typed failures, and
//    a `switch` over the sealed `DiFailure` reads each one.
// 4. `get` and `getOption` say why a value is not there:
//    `UnavailableKeyFailure` or `ScopePhaseFailure`.
// 5. `phase` shows where a scope is in its life.
//
// Run: dart run packages/fp_di_fpdart/example/diagnostics.dart
import 'package:fp_di_fpdart/fp_di_fpdart.dart';

class Database {}

final class PgDatabase extends Database {}

final class UserRepository {
  UserRepository(this.database);

  final Database database;
}

final class Mailer {}

final class Auth {}

final class Billing {}

final database = Component<Database>(
  debugLabel: 'database',
  dependency: Dependency<Database>(create: Database.new),
);

final repository = Component<UserRepository>(
  dependency: Dependency.require<Database>().map<UserRepository>(
    UserRepository.new,
  ),
);

String indent(String text) =>
    text.split('\n').map((line) => '    $line').join('\n');

/// Reads one typed failure as a line of text.
String describe(DiFailure failure) => switch (failure) {
  DuplicateKeyFailure(:final key, :final labels) =>
    'duplicate: $key from ${labels.join(' and ')}',
  UndeclaredKeyFailure(:final key, :final owner) =>
    'undeclared: $owner reads $key',
  DependencyCycleFailure(:final path) => 'cycle: ${path.join(' -> ')}',
  ActivationFailure(:final owner, :final error) =>
    'activation: $owner failed with $error',
  UnmatchedOverrideFailure(:final key, :final owner) =>
    'unmatched override: $owner names $key',
  UnavailableKeyFailure(:final key) => 'unavailable: $key',
  ScopePhaseFailure(:final operation, :final phase) =>
    'phase: $operation in ${phase.name}',
  InactiveAncestorFailure(:final phase) => 'parent is ${phase.name}',
};

/// Runs [scope] and prints the cause of the failure, if any.
Future<void> tryRun(String label, Scope scope) async {
  final started = await scope.run();
  started.match((cause) {
    print('  $label fails, phase ${scope.phase.name}:');
    print(indent(cause.prettyPrint()));
    print('    typed failures:');
    for (final failure in cause.failures) {
      print('      ${describe(failure)}');
    }
  }, (_) => print('  $label runs, phase ${scope.phase.name}'));
}

Future<void> main() async {
  print('1. the check accumulates');
  // Two components publish `Database`, and two components read `Auth`, which
  // no component publishes. One run reports all three problems in one cause:
  // every duplicate key first, then every undeclared key.
  await tryRun(
    'a broken list',
    Scope(
      components: [
        database,
        Component<Database>(
          debugLabel: 'second database',
          dependency: Dependency<Database>(create: Database.new),
        ),
        repository,
        Component<Mailer>(
          dependency: Dependency.require<Auth>().map<Mailer>((_) => Mailer()),
        ),
        Component<Billing>(
          dependency: Dependency.require<Auth>().map<Billing>((_) => Billing()),
        ),
      ],
    ),
  );

  print('2. a cycle');
  // Auth reads Mailer, and Mailer reads Auth. Every key has a publisher, so
  // the first two checks pass and the check for a cycle runs.
  await tryRun(
    'a cycle',
    Scope(
      components: [
        Component<Auth>(
          dependency: Dependency.require<Mailer>().map<Auth>((_) => Auth()),
        ),
        Component<Mailer>(
          dependency: Dependency.require<Auth>().map<Mailer>((_) => Mailer()),
        ),
      ],
    ),
  );

  print('3. a forgotten type argument');
  // Without `<Database>`, Dart infers `PgDatabase` from the create function.
  // The component publishes `DiKey<PgDatabase>`, and the repository still
  // reads `DiKey<Database>`. The run reports the gap. Nothing waits.
  await tryRun(
    'the forgotten argument',
    Scope(
      components: [
        Component<PgDatabase>(
          dependency: Dependency<PgDatabase>(create: PgDatabase.new),
        ),
        repository,
      ],
    ),
  );

  print('4. what a scope says about a missing value');
  final app = Scope(components: [database]);
  print('  before run, phase ${app.phase.name}');
  print('  get: ${app.get<Database>()}');
  print('  getOption: ${app.getOption<Database>()}');

  await tryRun('the app', app);
  print('  get a published key: ${app.get<Database>().isRight()}');
  print('  get an unpublished key: ${app.get<UserRepository>()}');
  print('  getOption: ${app.getOption<UserRepository>()}');

  // A scope runs once.
  final again = await app.run();
  again.match(
    (cause) => print('  run again: ${cause.failures.map(describe).toList()}'),
    (_) => print('  run again: started'),
  );

  // A child runs only after its parent is active.
  final late = Scope(components: [database]);
  final feature = late.child(components: [repository]);
  await tryRun('a child before its parent', feature);
  await tryRun('the parent', late);

  print('5. the phase after the end');
  for (final scope in [app, late, feature]) {
    final stopped = await scope.dispose();
    stopped.match(
      (cause) => print(indent(cause.prettyPrint())),
      (_) => print('  disposed, phase ${scope.phase.name}'),
    );
  }
  print('  get: ${app.get<Database>()}');
}
