// Seeing why a scope failed, and what a scope can still tell you.
//
// A scope checks its components before it creates any node. The check reports
// a problem as a `Cause`, so a forgotten key cannot leave a reader waiting for
// a key that nobody declares. A key that a component declares but does not
// publish yet makes a reader wait, and the node says what it waits for. This
// example shows five tools:
//
// 1. The check accumulates every duplicate key and every undeclared key. The
//    cause joins them with `Both`. A failed check changes nothing, so the
//    scope stays `declared`.
// 2. Two components that read each other wait. The run succeeds, and each node
//    names the key that it waits for in `missing`.
// 3. `prettyPrint()` shows the tree. `failures` lists the typed failures, and
//    a `switch` over the sealed `DiFailure` reads each one.
// 4. `get` and `getOption` say why a value is not there:
//    `UnavailableKeyFailure` or `DisposedScopeFailure`. A child that runs
//    before its parent waits, and `state` shows the phase of each node.
// 5. `phase` shows where a scope is in its life.
//
// Run: dart run packages/fp_di_fpdart/example/diagnostics.dart
import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';

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
  DisposedScopeFailure(:final operation) => 'disposed: $operation',
  ReentrantMutationFailure(:final operation) => 'reentrant: $operation',
  InactiveNodeFailure(:final missing) => 'inactive node, missing $missing',
  ListenerFailure(:final error) => 'listener threw $error',
  DisposedLazyFailure() => 'lazy value after the disposal of its owner',
  UnsettledFailure(:final labels, :final passes) =>
    'unsettled: ${labels.join(', ')} after $passes passes',
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
  // the check passes. Neither value can exist before the other one, so both
  // nodes wait. The run succeeds, and `missing` names the keys.
  final cycle = Scope(
    components: [
      Component<Auth>(
        dependency: Dependency.require<Mailer>().map<Auth>((_) => Auth()),
      ),
      Component<Mailer>(
        dependency: Dependency.require<Auth>().map<Mailer>((_) => Mailer()),
      ),
    ],
  );
  await tryRun('a cycle', cycle);
  for (final node in cycle.nodes) {
    print('  ${node.label}: ${node.state.phase.name}, missing ${node.missing}');
  }
  await cycle.dispose();

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

  // A scope that succeeded cannot run again.
  final again = await app.run();
  again.match(
    (cause) => print('  run again: ${cause.failures.map(describe).toList()}'),
    (_) => print('  run again: started'),
  );

  // A child can run before its parent. Its node waits for the key of the
  // parent, and the run of the parent wakes the node. `child` is a `Left` only
  // for a scope that is disposing or disposed.
  final late = Scope(components: [database]);
  final feature = late.child(components: [repository]);
  switch (feature) {
    case Left(value: final failure):
      print('  child failed: $failure');
    case Right(value: final child):
      await tryRun('a child before its parent', child);
      final waiting = child.nodes.single;
      print(
        '  the child waits: ${waiting.state.phase.name}, ${waiting.missing}',
      );
      await tryRun('the parent', late);
      print('  the child woke: ${waiting.state.phase.name}');
  }

  print('5. the phase after the end');
  for (final scope in [
    app,
    late,
    ...feature.match((_) => <Scope>[], (scope) => [scope]),
  ]) {
    final stopped = await scope.dispose();
    stopped.match(
      (cause) => print(indent(cause.prettyPrint())),
      (_) => print('  disposed, phase ${scope.phase.name}'),
    );
  }
  print('  get: ${app.get<Database>()}');
}
