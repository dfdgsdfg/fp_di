// The subprocess of V-T-TL-DT-001. It installs the recording hooks, creates
// two roots, disposes one, and prints what the hooks recorded as one JSON
// line. The test starts it with and without `--enable-asserts`.
import 'dart:async';
import 'dart:convert';

import 'package:fp_di/fp_di.dart';
import 'package:fp_di/src/runtime/runtime_inspector_hooks.dart';

import 'devtools_fixture.dart';

Future<void> main() async {
  var asserts = false;
  assert(asserts = true);

  final recorder = InspectorRecorder()..install();
  Scope.debugInspector = true;
  final slowReports = <SlowMutation>[];

  // Real traffic: a child that initializes before its root, a failed
  // automatic activation that reaches `Scope.errors`, and a slow mutation of a
  // root that has `onSlowMutation`.
  final gate = Completer<void>();
  final first = DevtoolsFixture.declare(
    onSlowMutation: slowReports.add,
    slowMutationThreshold: const Duration(milliseconds: 20),
  );
  final second = Scope(
    module: Module(components: [Component<int>.value(value: 1, key: baseKey)]),
  );
  // The first root listens to its errors in the probe, as an app can.
  final errors = <DiException>[];
  final subscription = first.root.errors.listen(errors.add);
  if (recorder.handlers.isNotEmpty) {
    await recorder.call('listen', {'enabled': 'true'});
  }
  await first.session.initialize();
  final slow = first.root.initialize();
  unawaited(
    first.root
        .child(
          module: Module(
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
          ),
        )
        .initialize(),
  );
  await slow;
  await Future<void>.delayed(const Duration(milliseconds: 70));
  gate.complete();
  await settle();
  await second.initialize();
  await second.dispose();
  await settle();

  Map<String, Object?>? roots;
  if (recorder.handlers.isNotEmpty) roots = await recorder.call('roots');
  final output = <String, Object?>{
    'asserts': asserts,
    'registered': recorder.registrations,
    'registeredFlag': RuntimeInspectorHooks.registered,
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
