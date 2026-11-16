// The subprocess of the registration test. It installs the recording hooks,
// creates two roots, disposes one, and prints what the hooks recorded as one
// JSON line. The test starts it with and without `--enable-asserts`.
import 'dart:async';
import 'dart:convert';

import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fp_di_fpdart/src/runtime/inspector_hooks.dart';

import 'devtools_fixture.dart';

Future<void> main() async {
  var asserts = false;
  assert(asserts = true);
  // The inspector is opt-in. The probe opts in, so the run without assertions
  // shows that the assert alone keeps the inspector out.
  Scope.debugInspector = true;

  final recorder = InspectorRecorder()..install();
  final slowReports = <SlowMutation>[];

  // Real traffic: a child that runs before its root, a failed automatic
  // activation that reaches `Scope.errors`, and a slow operation of a root
  // that has `onSlowMutation`.
  final gate = Completer<void>();
  final first = DevtoolsFixture.declare(
    onSlowMutation: slowReports.add,
    slowMutationThreshold: const Duration(milliseconds: 20),
  );
  final second = Scope(
    components: [Component<int>.value(value: 1, key: baseKey)],
  );
  // The first root listens to its errors in the probe, as an app can.
  final errors = <Object>[];
  final subscription = first.root.errors.listen(errors.add);
  if (recorder.handlers.isNotEmpty) {
    await recorder.call('listen', {'enabled': 'true'});
  }
  await first.session.run();
  final slow = first.root.run();
  final child = first.root
      .child(
        components: [
          Component<int>.effect(
            dependency: Dependency<int>(
              create: () async {
                await gate.future;
                return 1;
              },
            ),
          ),
        ],
      )
      .getOrElse((_) => throw StateError('no child'));
  unawaited(child.run());
  await slow;
  await Future<void>.delayed(const Duration(milliseconds: 70));
  gate.complete();
  await settle();
  await second.run();
  await second.dispose();
  await settle();

  Map<String, Object?>? roots;
  if (recorder.handlers.isNotEmpty) roots = await recorder.call('roots');
  final output = <String, Object?>{
    'asserts': asserts,
    'registered': recorder.registrations,
    'registeredFlag': InspectorHooks.registered,
    'events': [
      for (final event in recorder.events) {'kind': event.kind, ...event.data},
    ],
    'roots': roots,
    'errors': errors.length,
    'slowReports': slowReports.length,
  };
  await subscription.cancel();
  await first.dispose();
  // ignore: avoid_print
  print(jsonEncode(output));
}
