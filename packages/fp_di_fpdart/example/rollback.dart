// A failure rolls back what a scope already created.
//
// Part 1 is a failed run. One chain owns two steps and then fails in a third
// step. The runtime releases the second step and the first step, in that
// order. It publishes nothing. The cause of the run is a tree: the failure
// of the third step. The scope returns to `declared`, and the retry is a second
// `run` of the same scope.
//
// Part 2 is a failed program inside `use`. The run succeeds, and then the
// program fails. `use` disposes the scope on every path. Three cases show the
// cause: a program that returns a `Left`, a program that throws, and a
// program that returns a `Left` while a dispose function also throws.
//
// Differences from the fp_di version:
//
// - A failed run rolls back, and the scope is `declared` again. A second `run`
//   retries, like the second `initialize` of `fp_di`. A scope that succeeded
//   cannot run again: that `run` is a `ScopePhaseFailure`.
// - The run does not throw. The `Exit` holds a `Cause`, and the example prints
//   it with `prettyPrint()`.
// - The third step fails once, and the retry succeeds. The failing step is a
//   `map`. A `Left` of `mapTaskEither` has the same effect.
//
// Run: dart run packages/fp_di_fpdart/example/rollback.dart
import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';

var attempts = 0;

/// A fake resource. Its constructor and `release` stand for real I/O. A
/// `broken` part fails to release, and `release` throws.
final class Part {
  Part(this.name, {this.broken = false}) {
    print('  $name created');
  }

  final String name;
  final bool broken;

  void release() {
    if (broken) {
      print('  $name fails to release');
      throw StateError('$name did not close');
    }
    print('  $name released');
  }

  @override
  String toString() => name;
}

/// The number that the chain starts from.
final class Seed {
  const Seed(this.number);

  final int number;

  @override
  String toString() => '$number';
}

final seed = Component<Seed>.value(value: const Seed(1));

final chain = Component<Part>(
  debugLabel: 'chain',
  dependency: Dependency.require<Seed>()
      .map<Part>((_) => Part('first'), dispose: (part) => part.release())
      .map<Part>((_) => Part('second'), dispose: (part) => part.release())
      .map<Part>((_) {
        // The third step fails on the first attempt only.
        if (++attempts == 1) throw StateError('third failed');
        return Part('third');
      }, dispose: (part) => part.release()),
);

/// The components of the application. Each scope gets its own copy.
final components = <Component<Object?>>[seed, chain];

Future<void> main() async {
  print('1. a failed run');
  await failedRun();
  print('2. a failed program inside use');
  await failedProgram();
}

/// Part 1: a failed run rolls back, and the retry is a second run.
Future<void> failedRun() async {
  final scope = Scope(components: components);

  print('run');
  final started = await scope.run();
  started.match(
    (cause) => print('  failed:\n${indent(cause.prettyPrint())}'),
    (_) => print('  started'),
  );
  print('  phase: ${scope.phase.name}');
  print('  published: ${scope.getOption<Part>()}');

  // The scope is `declared` again, so the same scope can retry.
  print('retry');
  final retried = await scope.run();
  retried.match(
    (cause) => print('  failed:\n${indent(cause.prettyPrint())}'),
    (_) => print('  published: ${scope.getOption<Part>()}'),
  );

  // A scope that succeeded cannot run again.
  final again = await scope.run();
  again.match(
    (cause) => print('  run again: ${cause.failures.first}'),
    (_) => print('  run again: started'),
  );

  print('dispose');
  final stopped = await scope.dispose();
  stopped.match(
    (cause) => print('  failed:\n${indent(cause.prettyPrint())}'),
    (_) => print('  phase: ${scope.phase.name}'),
  );
}

/// Part 2: the scope that `use` brackets. One owned part, and no failing step.
List<Component<Object?>> tidyComponents({bool broken = false}) => [
  seed,
  Component<Part>(
    debugLabel: 'tidy',
    dependency: Dependency.require<Seed>().map<Part>(
      (_) => Part('tidy', broken: broken),
      dispose: (part) => part.release(),
    ),
  ),
];

Future<void> failedProgram() async {
  print('a program that returns a Left');
  await attempt(
    Scope(components: tidyComponents()),
    ReaderTaskEither<Scope, String, Unit>.left('the program gave up'),
  );

  // `use` catches the throw. It disposes the scope and does not rethrow.
  print('a program that throws');
  await attempt(
    Scope(components: tidyComponents()),
    ReaderTaskEither<Scope, String, Unit>(
      (_) async => throw StateError('a bug in the program'),
    ),
  );

  // The failure of the program comes first, and then the defect of the
  // dispose function: `Then(Fail, Die)`.
  print('a program that returns a Left, and a part that fails to release');
  await attempt(
    Scope(components: tidyComponents(broken: true)),
    ReaderTaskEither<Scope, String, Unit>.left('the program gave up'),
  );
}

/// Runs [program] in [scope] with `use`, and prints the cause.
Future<void> attempt(
  Scope scope,
  ReaderTaskEither<Scope, String, Unit> program,
) async {
  final result = await scope.use(program).run();
  result.match((cause) {
    print('  failed:\n${indent(cause.prettyPrint())}');
    print('  failures: ${cause.failures}');
    print('  defects: ${cause.defects}');
  }, (_) => print('  succeeded'));
  print('  phase: ${scope.phase.name}');
}

String indent(String text) =>
    text.split('\n').map((line) => '    $line').join('\n');
