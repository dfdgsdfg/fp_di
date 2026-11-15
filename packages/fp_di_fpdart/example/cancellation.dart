// Cancellation: stopping work whose owner goes away.
//
// Scene 4 calls the same login outside the runtime, as a unit test does,
// with CancellationToken.none and a CancellationController.
//
// Each activation has a CancellationToken. `Dependency.cancellation()` reads
// it, so a long step can stop cooperatively. The runtime cancels the token
// when the disposal of the owner is requested, when a node whose value the
// activation reads is disposed, when an active activation starts to
// deactivate, and when a step fails. It checks the token before every step,
// so a canceled activation never commits, and the steps that completed are
// disposed in reverse order.
//
// Differences from the fp_di version:
//
// - `whenCanceled` is a `Task`, so the login takes `cancel.run()`.
// - A canceled activation is an `Interrupt` in the `Cause` of `run`, and it is
//   never a `Fail`.
// - `run()`, `dispose()`, and `child()` return an `Exit` or an `Either`.
//
// Run: dart run packages/fp_di_fpdart/example/cancellation.dart
import 'dart:async';

import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';

final class Api {
  /// A login that takes a while. When [cancel] completes first, the login
  /// stops its timer, so it makes no session, and fails with a [StateError].
  ///
  /// `Future.any([work, cancel])` would only stop the wait. The work would
  /// go on, and a resource that it makes after the rollback would leak.
  Future<String> login({required Future<Unit> cancel}) {
    final result = Completer<String>();
    final work = Timer(
      const Duration(milliseconds: 300),
      () => result.complete('session of me'),
    );
    unawaited(
      cancel.then((_) {
        if (result.isCompleted) return;
        work.cancel();
        result.completeError(StateError('login aborted'));
      }),
    );
    return result.future;
  }
}

final api = Component<Api>.value(value: Api());

/// The session that a login returns.
final class UserSession {
  const UserSession(this.name);

  final String name;

  /// Closes the session. A fake session stands for a real one.
  void close() => print('  session closed');

  @override
  String toString() => name;
}

/// The text that the reader builds from the value it reads.
final class Reading {
  const Reading(this.text);

  final String text;

  @override
  String toString() => text;
}

/// The number that the reader waits for.
final class Source {
  const Source(this.number);

  final int number;

  @override
  String toString() => '$number';
}

/// The login step reads the token with the Api, and passes it on.
final session = Component<UserSession>(
  dependency: (Dependency.require<Api>(), Dependency.cancellation()).zip
      .mapTask<UserSession>(
        (pair) => Task(
          () async => UserSession(
            await pair.$1.login(cancel: pair.$2.whenCanceled.run()),
          ),
        ),
        dispose: (session) => session.close(),
      ),
);

/// A child scope of [parent], or a line that names the failure.
Future<void> withChild(
  Scope parent,
  List<Component<Object?>> components,
  Future<void> Function(Scope child) use,
) async => switch (parent.child(components: components)) {
  Left(value: final failure) => print('  child failed: $failure'),
  Right(value: final child) => await use(child),
};

Future<void> logoutDuringLogin() async {
  print('1. logout during login');
  final app = Scope(components: [api]);
  await app.run();
  await withChild(app, [session], (user) async {
    final watch = Stopwatch()..start();
    final login = user.run();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // The token is canceled inside this call, before the disposal waits for
    // the login in the queue.
    final logout = user.dispose();
    switch (await login) {
      case Left(value: final cause) when cause.isInterrupted:
        print('  login canceled after ${watch.elapsedMilliseconds} ms');
        print('  cause: ${cause.failures}');
      case _:
        print('  login was not canceled');
    }
    await logout;
  });
  print('  published: ${app.getOption<UserSession>()}');
  await app.dispose();
}

/// A reader that waits for the token or a slow source.
Component<Reading> reader(List<String> log) => Component<Reading>(
  dependency: (Dependency.require<Source>(), Dependency.cancellation()).zip
      .mapTask<Reading>(
        (pair) => Task(() async {
          final (v, token) = pair;
          log.add('  read $v');
          // Only a wait, so stopping the wait is enough: the delay makes
          // nothing.
          await Future.any([
            Future<void>.delayed(const Duration(milliseconds: 100)),
            token.whenCanceled.run(),
          ]);
          if (token.isCanceled) log.add('  canceled while reading $v');
          return Reading('reader of $v');
        }),
      ),
);

Future<void> withdrawalDuringRead() async {
  print('2. the value being read is disposed');
  final log = <String>[];
  final root = Scope(components: [Component<Source>.value(value: Source(2))]);
  await root.run();
  // A nearer value shadows the root one.
  await withChild(root, [Component<Source>.value(value: Source(1))], (
    mid,
  ) async {
    await mid.run();
    await withChild(mid, [reader(log)], (feature) async {
      final setup = feature.run();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Disposing the nearer value cancels its reader. The reader is not a
      // failure: it waits for the withdrawal, then reads the root value.
      await mid.node<Source>().match(
        (failure) async => print('  no node: $failure'),
        (node) => node.dispose(),
      );
      await setup;
      log.forEach(print);
      print('  now: ${feature.get<Reading>()}');
    });
  });
  await root.dispose();
}

/// A fake worker that stands for real work. It stops when its token cancels.
final class Worker {
  Worker.start(this.token) {
    print('  worker started');
  }

  final CancellationToken token;

  void stop() => print('  worker disposed, canceled: ${token.isCanceled}');
}

Future<void> failureBeforeRollback() async {
  print('3. a failed step cancels the token before the rollback');
  final scope = Scope(
    components: [
      Component<int>.effect(
        dependency: Dependency.cancellation()
            .map<Worker>(Worker.start, dispose: (worker) => worker.stop())
            .map<int>((_) => throw StateError('the second step failed')),
      ),
    ],
  );
  (await scope.run()).match(
    (cause) => print('  run failed: ${cause.failures}'),
    (_) => print('  run succeeded'),
  );
  await scope.dispose();
}

Future<void> outsideTheRuntime() async {
  print('4. the same login outside the runtime, as in a test');
  final watch = Stopwatch()..start();
  // A token that is never canceled: the login runs to the end.
  final none = CancellationToken.none.whenCanceled.run();
  print(
    '  none: ${await Api().login(cancel: none)}'
    ' after ${watch.elapsedMilliseconds} ms',
  );

  // A token that this code cancels, like the runtime does at a logout.
  watch.reset();
  final controller = CancellationController();
  final login = Api().login(cancel: controller.token.whenCanceled.run());
  await Future<void>.delayed(const Duration(milliseconds: 50));
  controller.cancel();
  try {
    await login;
  } on StateError catch (error) {
    print(
      '  controller: ${error.message} after ${watch.elapsedMilliseconds} ms',
    );
  }
}

Future<void> main() async {
  await logoutDuringLogin();
  await withdrawalDuringRead();
  await failureBeforeRollback();
  await outsideTheRuntime();
}
