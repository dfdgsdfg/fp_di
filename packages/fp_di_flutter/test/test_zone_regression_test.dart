// A later call does not depend on the zone of an earlier, finished call
// (R-UC-RT-LC-027). The body of `testWidgets` runs in a fake-async zone. The
// binding drains the microtasks of that zone only while the body runs. A
// `setUp` and a `tearDown` run in the real zone.
import 'package:flutter_test/flutter_test.dart';
import 'package:fp_di/fp_di.dart';

final class Repo {
  Repo(this.id);
  final int id;
}

final class Session {
  Session(this.id);
  final int id;
}

const _bodyTimeout = Timeout(Duration(seconds: 20));

Scope _newScope(List<String> events) => Scope(
  module: Module(
    components: [
      Component<Repo>(
        dependency: Dependency<Repo>(
          create: () => Repo(1),
          dispose: (_) => events.add('release'),
        ),
      ),
    ],
  ),
);

void main() {
  group('a scope that the real zone creates and the body uses', () {
    late Scope scope;
    late List<String> events;

    setUp(() {
      events = <String>[];
      scope = _newScope(events);
    });

    tearDown(() async {
      await scope.dispose().timeout(const Duration(seconds: 5));
      expect(events, ['release']);
    });

    testWidgets('initialize in the body, dispose in tearDown', (tester) async {
      await scope.initialize();
      expect(scope.get<Repo>().id, 1);
    }, timeout: _bodyTimeout);

    testWidgets('a child scope in the body, dispose in tearDown', (
      tester,
    ) async {
      await scope.initialize();
      final child = scope.child(
        module: Module(
          components: [
            Component<Session>(
              dependency: Dependency.require<Repo>().map(
                (repo) => Session(repo.id),
              ),
            ),
          ],
        ),
      );
      await child.initialize();
      expect(child.get<Session>().id, 1);
    }, timeout: _bodyTimeout);

    testWidgets('dispose in the body, dispose again in tearDown', (
      tester,
    ) async {
      await scope.initialize();
      await scope.dispose();
    }, timeout: _bodyTimeout);
  });

  group('a scope that the body creates and the real zone disposes', () {
    late Scope scope;
    late List<String> events;

    setUp(() {
      events = <String>[];
    });

    tearDown(() async {
      await scope.dispose().timeout(const Duration(seconds: 5));
      expect(events, ['release']);
    });

    testWidgets('initialize in the body, dispose in tearDown', (tester) async {
      scope = _newScope(events);
      await scope.initialize();
      expect(scope.get<Repo>().id, 1);
    }, timeout: _bodyTimeout);

    testWidgets('a child scope in the body, dispose in tearDown', (
      tester,
    ) async {
      scope = _newScope(events);
      await scope.initialize();
      final child = scope.child(
        module: Module(
          components: [
            Component<Session>(
              dependency: Dependency.require<Repo>().map(
                (repo) => Session(repo.id),
              ),
            ),
          ],
        ),
      );
      await child.initialize();
      expect(child.get<Session>().id, 1);
    }, timeout: _bodyTimeout);
  });
}
