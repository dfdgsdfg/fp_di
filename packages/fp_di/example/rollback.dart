// A failed initialize rolls back what it already created, and can retry.
//
// One chain owns two steps and then fails in a third. The runtime releases
// the second and the first step, in that order, publishes nothing, and leaves
// the scope uninitialized. The third step fails only once, so a second
// initialize succeeds.
import 'package:fp_di/fp_di.dart';

var attempts = 0;

/// A fake resource. Its constructor and `release` stand for real I/O.
final class Part {
  Part(this.name) {
    print('  $name created');
  }

  final String name;

  void release() => print('  $name released');

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
  dependency: Dependency.require<Seed>()
      .map((_) => Part('first'), dispose: (part) => part.release())
      .map((_) => Part('second'), dispose: (part) => part.release())
      .map((_) {
        if (++attempts == 1) throw StateError('third failed');
        return Part('third');
      }, dispose: (part) => part.release()),
);

Future<void> main() async {
  final app = Scope(module: Module(components: [seed, chain]));

  print('initialize');
  try {
    await app.initialize();
  } on ActivationException catch (error) {
    print('  failed: ${error.cause}');
  }
  print('  published: ${app.maybeGet<Part>()}');
  print('  initialized: ${app.isInitialized}');

  // The declaration is unchanged, so the same call can retry.
  print('retry');
  await app.initialize();
  print('  published: ${app.get<Part>()}');

  print('dispose');
  await app.dispose();
}
