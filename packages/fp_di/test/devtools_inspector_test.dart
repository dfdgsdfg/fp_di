// The DevTools inspector of the core package (specs/tooling/devtools).
// V-T-TL-DT-001 covers the registration in a debug build only,
// V-T-TL-DT-002 the query answers, V-T-TL-DT-003 the events, and
// V-T-TL-DT-004 the values on request.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:fp_di/fp_di.dart';
import 'package:fp_di/tooling.dart';
import 'package:test/test.dart';

import 'support/devtools_fixture.dart';

const _names = [
  'ext.fp_di.roots',
  'ext.fp_di.state',
  'ext.fp_di.node',
  'ext.fp_di.shape',
  'ext.fp_di.listen',
];

late InspectorRecorder recorder;
final List<Scope> _roots = <Scope>[];

/// A root that the test disposes in `tearDown`.
Scope _root({
  Module? module,
  SlowMutationListener? onSlowMutation,
  Duration slowMutationThreshold = const Duration(seconds: 2),
}) {
  final root = Scope(
    module: module,
    onSlowMutation: onSlowMutation,
    slowMutationThreshold: slowMutationThreshold,
  );
  _roots.add(root);
  return root;
}

Future<DevtoolsFixture> _fixture({
  SlowMutationListener? onSlowMutation,
  Duration slowMutationThreshold = const Duration(seconds: 2),
}) async {
  final fixture = await DevtoolsFixture.create(
    onSlowMutation: onSlowMutation,
    slowMutationThreshold: slowMutationThreshold,
  );
  _roots.add(fixture.root);
  return fixture;
}

Future<Map<String, Object?>> _state(int root, {bool values = false}) =>
    recorder.call('state', {'root': '$root', if (values) 'values': 'true'});

Future<int> _onlyRootId() async {
  final answer = await recorder.call('roots');
  return ((answer['roots']! as List).single as Map)['id']! as int;
}

Map<String, Object?> _scopeOf(Map<String, Object?> answer) =>
    answer['scope']! as Map<String, Object?>;

List<Map<String, Object?>> _list(Object? value) =>
    (value! as List).cast<Map<String, Object?>>();

void main() {
  var asserts = false;
  assert(asserts = true);

  setUp(() {
    recorder = InspectorRecorder()..install();
  });

  tearDown(() async {
    if (recorder.handlers.containsKey('ext.fp_di.listen')) {
      await recorder.call('listen', {'enabled': 'false'});
    }
    for (final root in _roots) {
      await root.dispose();
    }
    _roots.clear();
    recorder.uninstall();
  });

  test('the test run has assertions enabled', () {
    expect(asserts, isTrue, reason: 'run the tests with assertions');
  });

  // The extension app serves these files in its tests (V-T-TL-DT-005). A
  // change of the protocol must record them again.
  test('the recorded fixtures equal the answers of the inspector', () async {
    final config = await Isolate.packageConfig;
    final library = await Isolate.resolvePackageUri(
      Uri.parse('package:fp_di/fp_di.dart'),
    );
    if (config == null || library == null) {
      fail('The package configuration of the test run is not available.');
    }
    final support = library.resolve('../test/support/');
    final out = await Directory.systemTemp.createTemp('fp_di_fixtures');
    addTearDown(() => out.delete(recursive: true));
    final result = await Process.run(Platform.resolvedExecutable, [
      '--packages=${config.toFilePath()}',
      '--enable-asserts',
      support.resolve('dump_devtools_fixtures.dart').toFilePath(),
      '--out=${out.path}',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final recorded = Directory.fromUri(support.resolve('devtools_fixtures/'));
    String names(Directory directory) =>
        (directory.listSync().map((file) => file.uri.pathSegments.last).toList()
              ..sort())
            .join(', ');
    expect(names(out), names(recorded));
    for (final file in recorded.listSync().whereType<File>()) {
      final name = file.uri.pathSegments.last;
      expect(
        File('${out.path}/$name').readAsStringSync(),
        file.readAsStringSync(),
        reason: '$name differs; run dump_devtools_fixtures.dart again',
      );
    }
  });

  group('registration (V-T-TL-DT-001)', () {
    test(
      'registers each service extension once and lists the live root',
      () async {
        final first = _root(
          module: Module(debugLabel: 'first', components: []),
        );
        expect(recorder.registrations, _names);
        final second = _root(
          module: Module(debugLabel: 'second', components: []),
        );
        expect(recorder.registrations, _names, reason: 'a second root');
        await first.initialize();
        await second.initialize();

        var roots = _list((await recorder.call('roots'))['roots']);
        expect([for (final root in roots) root['label']], ['first', 'second']);
        expect(roots[0]['id'], isNot(roots[1]['id']));
        expect(roots[0]['revision'], first.revision);

        await first.dispose();
        roots = _list((await recorder.call('roots'))['roots']);
        expect([for (final root in roots) root['label']], ['second']);
        expect(recorder.registrations, _names, reason: 'a disposal');

        _root(); // a third root joins without a new registration
        expect(recorder.registrations, _names);
        expect(_list((await recorder.call('roots'))['roots']), hasLength(2));
      },
    );

    test('the registry costs the same for each root, also with many '
        'roots', () async {
      // A walk of the registry at each creation or disposal took 19 s for
      // these roots; one lookup takes well under one.
      const count = 40000;
      final watch = Stopwatch()..start();
      final roots = [
        for (var i = 0; i < count; i++)
          Scope(
            module: Module(debugLabel: 'many', components: []),
          ),
      ];
      for (final root in roots) {
        await root.dispose();
      }
      watch.stop();
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(_list((await recorder.call('roots'))['roots']), isEmpty);
    });

    test('the answers of a dispose in progress do not throw', () async {
      final gate = Completer<void>();
      final root = _root(
        module: Module(
          components: [
            Component<int>.effect(
              debugLabel: 'slow release',
              dependency: Dependency<int>(
                create: () => 1,
                dispose: (_) => gate.future,
              ),
            ),
          ],
        ),
      );
      await root.initialize();
      final id = await _onlyRootId();
      final disposal = root.dispose();
      await settle();
      expect(root.state.phase, ScopePhase.disposing);
      final answer = await _state(id);
      expect(_scopeOf(answer)['phase'], 'disposing');
      gate.complete();
      await disposal;
      expect((await _state(id))['error'], contains('root'));
    });

    test('with assertions off the hooks record nothing; with them on, one '
        'registration', () async {
      final withAsserts = await _probe(enableAsserts: true);
      final without = await _probe(enableAsserts: false);

      expect(withAsserts['asserts'], isTrue);
      expect(withAsserts['registered'], _names);
      expect(withAsserts['registeredFlag'], isTrue);
      expect(
        ((withAsserts['roots']! as Map)['roots']! as List).length,
        1,
        reason: 'one root was disposed, one is live',
      );
      expect(withAsserts['events'], isNotEmpty);

      expect(without['asserts'], isFalse, reason: 'the run has no assertions');
      expect(without['registered'], isEmpty);
      expect(without['registeredFlag'], isFalse);
      expect(without['events'], isEmpty);
      expect(without['roots'], isNull);
      // The traffic was real, so the empty record means something.
      expect(without['errors'], greaterThan(0));
      expect(without['slowReports'], greaterThan(0));
      expect(withAsserts['slowReports'], greaterThan(0));
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  group('queries (V-T-TL-DT-002)', () {
    test(
      'roots and state match the runtime, and the calls change nothing',
      () async {
        final fixture = await _fixture();
        final revision = fixture.root.revision;
        final roots = _list((await recorder.call('roots'))['roots']);
        expect(roots.single, {
          'id': roots.single['id'],
          'label': 'app',
          'revision': revision,
        });

        final answer = await _state(roots.single['id']! as int);
        expect(answer['format'], 'fp_di.devtools');
        expect(answer['version'], 1);
        final ids = <int>{};
        _expectMatches(
          _scopeOf(answer),
          fixture.root,
          fixture.root.state,
          ids,
          children: [fixture.session, fixture.spare],
        );
        expect(fixture.root.revision, revision);

        final tree = _scopeOf(answer);
        expect(tree['module'], 'app');
        expect(_list(tree['children']).map((c) => c['module']), [
          'session',
          null,
        ]);
        final spare = _list(tree['children'])[1];
        expect(spare['phase'], 'declared');
        expect(spare['nodes'], isEmpty);
        final session = scopeByModule(tree, 'session')!;
        expect(session['phase'], 'initialized');
        final byLabel = {
          for (final scope in [tree, session])
            for (final node in _list(scope['nodes'])) node['label']: node,
        };
        expect(byLabel['login']!['phase'], 'activationFailed');
        expect(byLabel['login']!['failure'], {
          'type': 'StateError',
          'message': 'Bad state: boom',
        });
        expect(byLabel['profile']!['phase'], 'waiting');
        expect(byLabel['profile']!['missing'], ['DiKey<int>(token)']);
        expect(byLabel['doomed']!['phase'], 'disposed');
        expect(byLabel['orphan']!['phase'], 'waiting');
        expect(byLabel['config']!['phase'], 'active');
        expect(byLabel['config']!['key'], 'DiKey<String>(config)');
        expect(byLabel['pluginA']!['key'], isNull);
        expect(byLabel['pluginA']!['origin'], 'app');
        expect(byLabel['config']!.containsKey('value'), isFalse);
      },
    );

    test(
      'state lists the open holds of a waiting disposal (V-T-TL-DT-006)',
      () async {
        final root = _root(
          module: Module(debugLabel: 'app', components: []),
        );
        final child = root.child(
          module: Module(debugLabel: 'page', components: []),
        );
        await root.initialize();
        await child.initialize();
        final rootId = await _onlyRootId();

        final labeled = child.disposeHold(debugLabel: 'dialog');
        final unlabeled = child.disposeHold();
        var ended = false;
        final disposal = child.dispose().then((_) => ended = true);
        await settle();
        expect(ended, isFalse, reason: 'the holds delay the disposal');

        final tree = _scopeOf(await _state(rootId));
        final page = scopeByModule(tree, 'page')!;
        expect(page['phase'], 'disposeRequested');
        expect(page['holds'], ['dialog', 'hold']);
        expect(tree['holds'], isEmpty);

        labeled.close();
        expect(
          _list(_scopeOf(await _state(rootId))['children']).single['holds'],
          ['hold'],
          reason: 'a closed hold leaves the list',
        );

        unlabeled.close();
        await disposal;
        expect(ended, isTrue);
        final after = _scopeOf(await _state(rootId));
        expect(after['children'], isEmpty);
        expect(after['holds'], isEmpty);
      },
    );

    test('node details: reads, readers, failure, and cause steps', () async {
      final fixture = await _fixture();
      final revision = fixture.root.revision;
      final root = await _onlyRootId();
      final tree = _scopeOf(await _state(root));
      int id(String label) => nodeIdByLabel(tree, label)!;
      Future<Map<String, Object?>> node(String label) =>
          recorder.call('node', {'root': '$root', 'node': '${id(label)}'});

      // A node that reads a published key.
      final greeter = await node('greeter');
      expect(greeter['format'], 'fp_di.devtools');
      expect(greeter['reads'], [
        {
          'key': 'DiKey<String>(config)',
          'kind': 'require',
          'resolves': true,
          'publisher': id('config'),
        },
      ]);
      expect(greeter['readers'], isEmpty);
      expect(greeter['failure'], isNull);
      expect(greeter['cause'], isNull, reason: 'the key has a value');
      expect((await node('config'))['readers'], [id('greeter')]);

      // A collection reader: no single publisher; its members resolve.
      final registry = await node('registry');
      final read = _list(registry['reads']).single;
      expect(read['kind'], 'collection');
      expect(read['resolves'], isTrue);
      expect(read['publisher'], isNull);
      expect(
        [for (final member in _list(read['members'])) member['publisher']],
        [id('pluginA'), id('pluginB')],
      );

      // The failed activation: cause and stack trace as the runtime holds them.
      final login = await node('login');
      final failure = fixture.session.nodes[0].state.activationException!;
      expect(login['failure'], {
        'cause': '${failure.cause}',
        'stackTrace': syntheticStack,
      });
      expect(failure.stackTrace.toString(), syntheticStack);
      expect(login['reads'], [
        {
          'key': 'DiKey<int>(base)',
          'kind': 'require',
          'resolves': true,
          'publisher': id('base'),
        },
      ]);
      expect(login['cause'], [
        {
          'node': id('login'),
          'phase': 'activationFailed',
          'waitsFor': <String>[],
        },
      ]);

      // The waiting node: its steps equal the search of `get`.
      final profile = await node('profile');
      expect(profile['reads'], [
        {
          'key': 'DiKey<int>(token)',
          'kind': 'require',
          'resolves': false,
          // Without a value, the node that publishes the key: the failed one.
          'publisher': id('login'),
        },
      ]);
      expect(profile['cause'], [
        {
          'node': id('profile'),
          'phase': 'waiting',
          'waitsFor': ['DiKey<int>(token)'],
        },
        {
          'node': id('login'),
          'phase': 'activationFailed',
          'waitsFor': <String>[],
        },
      ]);
      Object? thrown;
      try {
        fixture.session.get<String>(key: const DiKey<String>(name: 'profile'));
      } on UnavailableKeyException catch (error) {
        thrown = error;
      }
      final exception = thrown! as UnavailableKeyException;
      expect(
        [
          for (final step in _list(profile['cause']))
            if (step['phase'] == 'activationFailed') step['node'],
        ],
        [for (final failed in exception.failedNodeStates) failed.id],
      );

      // The node that was disposed alone, and its reader.
      final doomed = await node('doomed');
      expect(doomed['readers'], isEmpty);
      expect(doomed['cause'], [
        {'node': id('doomed'), 'phase': 'disposed', 'waitsFor': <String>[]},
      ]);
      final orphan = await node('orphan');
      expect(orphan['cause'], [
        {
          'node': id('orphan'),
          'phase': 'waiting',
          'waitsFor': ['DiKey<int>(doomed)'],
        },
      ]);
      expect(fixture.root.revision, revision, reason: 'a query is no mutation');
    });

    test('the shape of a scope has the modules of its ancestors', () async {
      final fixture = await _fixture();
      final root = await _onlyRootId();
      final tree = _scopeOf(await _state(root));
      final session = scopeByModule(tree, 'session')!;
      final answer = await recorder.call('shape', {
        'scope': '${session['id']}',
      });
      expect(answer['format'], 'fp_di.devtools');
      expect(answer['version'], 1);
      final expected = ShapeGraph.of(
        fixture.session.module,
        ancestorModules: [fixture.root.module],
      ).toJsonObject();
      expect(answer['shape'], jsonDecode(jsonEncode(expected)));
      expect(((answer['shape']! as Map)['ancestors']! as Map)['labels'], [
        'app',
      ]);
      final scopeIds = <Object?>{
        tree['id'],
        for (final child in _list(tree['children'])) child['id'],
      };
      expect(scopeIds, hasLength(3), reason: 'ids are unique');
    });

    test(
      'an unknown id gives an error answer that names the argument',
      () async {
        final fixture = await _fixture();
        final revision = fixture.root.revision;
        final root = await _onlyRootId();
        final tree = _scopeOf(await _state(root));
        final node = nodeIdByLabel(tree, 'config')!;

        Future<void> expectError(
          String name,
          Map<String, String> parameters,
          String argument,
        ) async {
          final answer = await recorder.call(name, parameters);
          expect(
            answer['format'],
            'fp_di.devtools',
            reason: '$name $parameters',
          );
          expect(answer['version'], 1);
          expect(answer['error'], isA<String>());
          expect(answer['error'], contains('$argument:'));
          expect(answer.keys, unorderedEquals(['format', 'version', 'error']));
        }

        await expectError('state', {'root': '999'}, 'root');
        await expectError('state', {}, 'root');
        await expectError('state', {'root': 'x'}, 'root');
        await expectError('node', {'root': '999', 'node': '$node'}, 'root');
        await expectError('node', {'root': '$root', 'node': '999'}, 'node');
        await expectError('node', {'root': '$root'}, 'node');
        await expectError('shape', {'scope': '999'}, 'scope');
        await expectError('shape', {}, 'scope');
        await expectError('listen', {}, 'enabled');
        await expectError('listen', {'enabled': 'maybe'}, 'enabled');
        await expectError('state', {
          'root': '$root',
          'values': 'yes',
        }, 'values');
        expect(fixture.root.revision, revision);
        expect(recorder.events, isEmpty);

        // A node id belongs to one root.
        final other = _root(
          module: Module(
            components: [Component<int>.value(value: 1, key: baseKey)],
          ),
        );
        await other.initialize();
        final roots = _list((await recorder.call('roots'))['roots']);
        final otherId = roots.last['id']! as int;
        expect(otherId, isNot(root));
        final otherTree = _scopeOf(await _state(otherId));
        final otherNode = nodeIdByLabel(otherTree, 'DiKey<int>(base)')!;
        final inOther = await recorder.call('node', {
          'root': '$otherId',
          'node': '$otherNode',
        });
        expect(inOther['reads'], isEmpty);

        // A disposed root answers as unknown.
        await fixture.root.dispose();
        await expectError('state', {'root': '$root'}, 'root');
        await expectError('node', {'root': '$root', 'node': '$node'}, 'root');
        await expectError('shape', {'scope': '${tree['id']}'}, 'scope');
      },
    );

    test('a wrapped handler does not throw into the app', () async {
      _root();
      final handler = recorder.handlers['ext.fp_di.state']!;
      final answer = await handler('ext.fp_di.state', {'root': '1', 'x': 'y'});
      expect(answer['format'], 'fp_di.devtools');
    });
  });

  group('events (V-T-TL-DT-003)', () {
    test('nothing is posted before listen, and the hook sees the first '
        'event after it', () async {
      final fixture = await _fixture();
      await settle();
      expect(recorder.events, isEmpty);

      final id = await _onlyRootId();
      expect(
        (await recorder.call('listen', {'enabled': 'true'}))['listening'],
        isTrue,
      );
      expect(recorder.events, isEmpty, reason: 'listen posts nothing');
      fixture.root.child();
      await settle();
      expect(recorder.of('fp_di:transition'), hasLength(1));
      expect(recorder.of('fp_di:transition').single['root'], id);
    });

    test('the transitions of one turn are one event, and a later turn gives '
        'another', () async {
      final root = _root();
      await settle();
      final id = await _onlyRootId();
      await recorder.call('listen', {'enabled': 'true'});

      // Four transitions in one synchronous turn.
      root
        ..child()
        ..child();
      root.child();
      root.child();
      expect(
        recorder.events,
        isEmpty,
        reason: 'the flush runs in a later turn',
      );
      await settle();
      var transitions = recorder.of('fp_di:transition');
      expect(transitions, hasLength(1));
      expect(transitions.single['root'], id);
      expect(transitions.single['revision'], root.revision);
      expect(transitions.single['format'], 'fp_di.devtools');
      expect(transitions.single['version'], 1);
      expect(transitions.single['changed'], isEmpty, reason: 'no node');
      expect(transitions.single['omitted'], 0);
      expect(transitions.single.containsKey('truncated'), isFalse);

      root.child();
      await settle();
      transitions = recorder.of('fp_di:transition');
      expect(transitions, hasLength(2), reason: 'a second turn');
      expect(transitions.last['revision'], root.revision);
      await settle();
      expect(recorder.of('fp_di:transition'), hasLength(2), reason: 'idle');
    });

    test('one event for each root that changed', () async {
      final first = _root();
      final second = _root();
      await settle();
      await recorder.call('listen', {'enabled': 'true'});
      first.child();
      second.child();
      await settle();
      final transitions = recorder.of('fp_di:transition');
      expect(transitions.map((event) => event['root']).toSet(), hasLength(2));
      expect(transitions, hasLength(2));
    });

    test('changed lists the node states with their earlier state', () async {
      final fixture = DevtoolsFixture.declare();
      _roots.add(fixture.root);
      await fixture.session.initialize();
      await recorder.call('listen', {'enabled': 'true'});
      await fixture.root.initialize();
      await settle();
      final transitions = recorder.of('fp_di:transition');
      // The awaited `initialize` runs its microtasks in one turn.
      expect(transitions, hasLength(1));
      // The union of the changes ends in the state of the runtime.
      final last = <int, Map<String, Object?>>{};
      for (final event in transitions) {
        for (final change in _list(event['changed'])) {
          last[change['node']! as int] =
              (change['after'] as Map?)?.cast<String, Object?>() ?? {};
        }
      }
      final tree = _scopeOf(await _state(await _onlyRootId()));
      for (final node in [
        ..._list(tree['nodes']),
        ..._list(scopeByModule(tree, 'session')!['nodes']),
      ]) {
        final seen = last[node['id']];
        if (seen == null) continue;
        expect(seen['phase'], node['phase'], reason: '${node['label']}');
        expect(seen['commits'], node['commits']);
      }
      final login = last[nodeIdByLabel(tree, 'login')!]!;
      expect(login['phase'], 'activationFailed');
      expect(login['failure'], isNotNull);
      final created = [
        for (final event in transitions)
          for (final change in _list(event['changed']))
            if (change['before'] == null) change,
      ];
      expect(
        created,
        isNotEmpty,
        reason: 'a created node has no earlier state',
      );
    });

    test('an error report is posted with a cut stack trace', () async {
      final fixture = DevtoolsFixture.declare();
      _roots.add(fixture.root);
      await fixture.session.initialize();
      await recorder.call('listen', {'enabled': 'true'});
      await fixture.root.initialize();
      await settle();
      final errors = recorder.of('fp_di:error');
      expect(errors, isNotEmpty);
      final error = errors.first;
      expect(error['root'], await _onlyRootId());
      expect(error['type'], 'ActivationException');
      expect(error['message'], contains('boom'));
      expect(error['stackTrace'], syntheticStack);
      expect(error.containsKey('truncated'), isFalse);
    });

    test('a stack trace over the bound is cut and marked', () async {
      final long = 'frame\n' * 2000; // 12000 characters
      final root = _root(
        module: Module(
          components: [Component<int>.value(value: 1, key: baseKey)],
        ),
      );
      final child = root.child(
        module: Module(
          components: [
            Component<int>.effect(
              debugLabel: 'deep',
              dependency: Dependency.require<int>(key: baseKey).map<int>(
                (_) => Error.throwWithStackTrace(
                  StateError('deep'),
                  StackTrace.fromString(long),
                ),
              ),
            ),
          ],
        ),
      );
      await child.initialize();
      await recorder.call('listen', {'enabled': 'true'});
      await root.initialize();
      await settle();
      final error = recorder.of('fp_di:error').first;
      expect(error['stackTrace'], long.substring(0, 4096));
      expect(error['truncated'], isTrue);

      // The node answer cuts the same text and marks it.
      final id = await _onlyRootId();
      final tree = _scopeOf(await _state(id));
      final answer = await recorder.call('node', {
        'root': '$id',
        'node': '${nodeIdByLabel(tree, 'deep')}',
      });
      final failure = answer['failure']! as Map<String, Object?>;
      expect(failure['stackTrace'], long.substring(0, 4096));
      expect(failure['truncated'], isTrue);
    });

    test('a slow mutation is posted, and the listener of the caller still '
        'runs', () async {
      final gate = Completer<void>();
      final reports = <SlowMutation>[];
      final root = _root(
        onSlowMutation: reports.add,
        slowMutationThreshold: const Duration(milliseconds: 30),
        module: Module(
          components: [
            Component<int>.effect(
              debugLabel: 'slow',
              dependency: Dependency<int>(
                create: () async {
                  await gate.future;
                  return 1;
                },
              ),
            ),
          ],
        ),
      );
      final id = await _onlyRootId();
      await recorder.call('listen', {'enabled': 'true'});
      final setup = root.initialize();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      gate.complete();
      await setup;
      expect(reports, isNotEmpty);
      final posted = recorder.of('fp_di:slowMutation');
      expect(posted.length, reports.length);
      final event = posted.first;
      expect(event['root'], id);
      expect(event['operation'], 'initialize');
      expect(event['elapsedMs'], greaterThanOrEqualTo(30));
      expect(event['running'], ['slow']);
      expect(event['ignoringCancellation'], isEmpty);
      expect(event['disposing'], isEmpty);
      expect(event['queued'], 0);
    });

    test('a root without onSlowMutation posts no slow event and starts no '
        'timer', () async {
      var timers = 0;
      final gate = Completer<void>();
      late final Scope root;
      late final Future<Scope> setup;
      runZoned(
        () {
          root = _root(
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
          );
          setup = root.initialize();
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            timers++;
            return parent.createTimer(zone, duration, callback);
          },
          createPeriodicTimer: (self, parent, zone, period, callback) {
            timers++;
            return parent.createPeriodicTimer(zone, period, callback);
          },
        ),
      );
      await recorder.call('listen', {'enabled': 'true'});
      await Future<void>.delayed(const Duration(milliseconds: 60));
      gate.complete();
      await setup;
      expect(timers, 0);
      expect(recorder.of('fp_di:slowMutation'), isEmpty);
    });

    test('listen with enabled false stops the events', () async {
      final root = _root();
      await recorder.call('listen', {'enabled': 'true'});
      root.child();
      await settle();
      expect(recorder.of('fp_di:transition'), hasLength(1));

      final answer = await recorder.call('listen', {'enabled': 'false'});
      expect(answer['listening'], isFalse);
      root.child();
      await settle();
      expect(recorder.of('fp_di:transition'), hasLength(1));

      // A transition that was pending when listen stopped posts nothing.
      await recorder.call('listen', {'enabled': 'true'});
      root.child();
      await recorder.call('listen', {'enabled': 'false'});
      await settle();
      expect(recorder.of('fp_di:transition'), hasLength(1));

      // The error stream has no subscription any more.
      final fixture = DevtoolsFixture.declare();
      _roots.add(fixture.root);
      await fixture.session.initialize();
      await fixture.root.initialize();
      await settle();
      expect(recorder.of('fp_di:error'), isEmpty);
      expect(recorder.of('fp_di:slowMutation'), isEmpty);
    });

    test('a root that is created while listening posts too', () async {
      final earlier = _root(); // registers the service extensions
      await recorder.call('listen', {'enabled': 'true'});
      final root = _root();
      final roots = _list((await recorder.call('roots'))['roots']);
      final id = roots.last['id'];
      expect(id, isNot(roots.first['id']));
      root.child();
      await settle();
      expect(recorder.of('fp_di:transition').single['root'], id);
      earlier.child();
      await settle();
      expect(recorder.of('fp_di:transition'), hasLength(2));
    });

    test(
      'a listening root can be disposed, and the disposal is posted',
      () async {
        final fixture = await _fixture();
        await recorder.call('listen', {'enabled': 'true'});
        await fixture.root.dispose();
        await settle();
        final transitions = recorder.of('fp_di:transition');
        expect(transitions, isNotEmpty);
        final finals = [
          for (final event in transitions)
            for (final change in _list(event['changed']))
              if (change['after'] == null) change,
        ];
        expect(finals, isNotEmpty, reason: 'nodes left with the disposal');
        final roots = _list((await recorder.call('roots'))['roots']);
        expect(roots, isEmpty);
      },
    );

    test(
      'an event lists at most 500 changed nodes and counts the rest',
      () async {
        final root = _root(
          module: Module(
            components: [
              for (var i = 0; i < 600; i++)
                Component<int>.effect(
                  debugLabel: 'n$i',
                  dependency: Dependency<int>(create: () => i),
                ),
            ],
          ),
        );
        await recorder.call('listen', {'enabled': 'true'});
        await root.initialize();
        await settle();
        final transitions = recorder.of('fp_di:transition');
        for (final event in transitions) {
          expect(_list(event['changed']).length, lessThanOrEqualTo(500));
        }
        final cut = transitions.where((event) => event['truncated'] == true);
        expect(cut, isNotEmpty);
        for (final event in cut) {
          expect(_list(event['changed']), hasLength(500));
          expect(event['omitted'], greaterThan(0));
        }
      },
    );
  });

  group('values (V-T-TL-DT-004)', () {
    Future<Scope> valuesRoot({
      bool listenFirst = false,
      bool values = false,
    }) async {
      final root = _root(
        module: Module(
          components: [
            Component<_Secret>.value(value: _Secret(), debugLabel: 'secret'),
            Component<_Long>.value(value: _Long(), debugLabel: 'long'),
            Component<_Thrower>.value(value: _Thrower(), debugLabel: 'thrower'),
            Component<_Emoji>.value(value: _Emoji(), debugLabel: 'emoji'),
          ],
        ),
      );
      if (listenFirst) {
        await recorder.call('listen', {
          'enabled': 'true',
          if (values) 'values': 'true',
        });
      }
      await root.initialize();
      await settle();
      return root;
    }

    test('no value text appears without the request', () async {
      final root = await valuesRoot(listenFirst: true);
      final id = await _onlyRootId();
      final raw = StringBuffer();
      final state = await _state(id);
      raw.write(jsonEncode(state));
      for (final node in _list(_scopeOf(state)['nodes'])) {
        expect(node.containsKey('value'), isFalse, reason: '${node['label']}');
        raw.write(
          jsonEncode(
            await recorder.call('node', {
              'root': '$id',
              'node': '${node['id']}',
            }),
          ),
        );
      }
      await root.nodes[0].dispose();
      await settle();
      expect(recorder.of('fp_di:transition'), isNotEmpty);
      for (final event in recorder.events) {
        raw.write(jsonEncode(event.data));
      }
      final text = raw.toString();
      expect(text, contains('secret'), reason: 'the label is not a value');
      expect(text, isNot(contains('hunter2')));
      expect(text, isNot(contains('xxxxxxxx')));
      expect(text, isNot(contains('toString threw')));
    });

    test('the state answer shows values on request, cut and guarded', () async {
      await valuesRoot();
      final id = await _onlyRootId();
      final nodes = {
        for (final node in _list(
          _scopeOf(await _state(id, values: true))['nodes'],
        ))
          node['label']: node,
      };
      expect(nodes['secret']!['value'], 'hunter2');
      expect(nodes['secret']!.containsKey('truncated'), isFalse);
      final long = nodes['long']!['value']! as String;
      expect(long, 'x' * 4096);
      expect(nodes['long']!['truncated'], isTrue);
      expect(nodes['thrower']!['value'], '<toString threw>');
      expect(nodes['thrower']!.containsKey('truncated'), isFalse);
      // A cut never splits a surrogate pair.
      final emoji = nodes['emoji']!['value']! as String;
      expect(emoji, hasLength(4095));
      expect(nodes['emoji']!['truncated'], isTrue);
    });

    test('a node without a value has a null text', () async {
      await _fixture();
      final id = await _onlyRootId();
      final tree = _scopeOf(await _state(id, values: true));
      final session = scopeByModule(tree, 'session')!;
      final nodes = {
        for (final node in [
          ..._list(tree['nodes']),
          ..._list(session['nodes']),
        ])
          node['label']: node,
      };
      expect(nodes['config']!['value'], 'prod');
      expect(nodes['login']!['value'], isNull, reason: 'activation failed');
      expect(nodes['profile']!['value'], isNull, reason: 'waiting');
      expect(nodes['doomed']!['value'], isNull, reason: 'disposed');
    });

    test('the node answer shows values on request', () async {
      await valuesRoot();
      final id = await _onlyRootId();
      final tree = _scopeOf(await _state(id));
      Future<Map<String, Object?>> node(String label, {required bool values}) =>
          recorder.call('node', {
            'root': '$id',
            'node': '${nodeIdByLabel(tree, label)}',
            if (values) 'values': 'true',
          });
      expect(
        (await node('secret', values: false)).containsKey('value'),
        isFalse,
      );
      expect((await node('secret', values: true))['value'], 'hunter2');
      final long = await node('long', values: true);
      expect(long['value'], 'x' * 4096);
      expect(long['truncated'], isTrue);
      expect(
        (await node('thrower', values: true))['value'],
        '<toString threw>',
      );
    });

    test('listen with values puts the value text in an event', () async {
      await valuesRoot(listenFirst: true, values: true);
      final shown = <Object?, Object?>{};
      for (final event in recorder.of('fp_di:transition')) {
        for (final change in _list(event['changed'])) {
          final after = change['after'] as Map<String, Object?>?;
          if (after == null) continue;
          expect(after.containsKey('value'), isTrue);
          shown[after['label']] = after['value'];
        }
      }
      expect(shown['secret'], 'hunter2');
      expect(shown['long'], 'x' * 4096);
      expect(shown['thrower'], '<toString threw>');
    });
  });
}

class _Secret {
  @override
  String toString() => 'hunter2';
}

class _Long {
  @override
  String toString() => 'x' * 10000;
}

class _Thrower {
  @override
  String toString() => throw StateError('secret in the message');
}

class _Emoji {
  // Each U+1F600 is a surrogate pair, so the cut at 4096 falls between the
  // two halves of the pair that starts at 4095.
  @override
  String toString() => 'a${'\u{1F600}' * 3000}';
}

/// Checks that [json] is the tree of [scope] and [state], and that each node
/// id is new. [children] are the child scopes of [scope], in creation order;
/// the children of those have none in the fixture.
void _expectMatches(
  Map<String, Object?> json,
  Scope scope,
  ScopeState state,
  Set<int> ids, {
  List<Scope> children = const [],
  List<String> holds = const [],
}) {
  expect(json['phase'], state.phase.name);
  expect(json['module'], scope.module.debugLabel);
  expect(json['holds'], holds, reason: 'the open holds of the scope');
  final nodes = _list(json['nodes']);
  expect(nodes, hasLength(state.nodeStates.length));
  for (var i = 0; i < nodes.length; i++) {
    final node = state.nodeStates[i];
    expect(nodes[i]['id'], node.id);
    expect(ids.add(node.id), isTrue, reason: 'one id for each node');
    expect(nodes[i]['label'], node.label);
    expect(nodes[i]['key'], node.key?.toString());
    expect(nodes[i]['phase'], node.phase.name);
    expect(nodes[i]['missing'], [for (final key in node.missing) '$key']);
    expect(nodes[i]['commits'], node.commits);
    expect(nodes[i]['failure'] == null, node.activationException == null);
    expect(
      nodes[i]['origin'],
      scope.module.origins[i],
      reason: 'the origin of the component at the position',
    );
  }
  final childJson = _list(json['children']);
  expect(childJson, hasLength(state.childStates.length));
  expect(childJson, hasLength(children.length));
  for (var i = 0; i < childJson.length; i++) {
    _expectMatches(childJson[i], children[i], state.childStates[i], ids);
  }
}

/// Runs `devtools_inspector_probe.dart` in a new process, with or without
/// assertions, and returns the JSON line that it prints.
Future<Map<String, Object?>> _probe({required bool enableAsserts}) async {
  final config = await Isolate.packageConfig;
  final library = await Isolate.resolvePackageUri(
    Uri.parse('package:fp_di/fp_di.dart'),
  );
  if (config == null || library == null) {
    fail('The package configuration of the test run is not available.');
  }
  final script = library.resolve(
    '../test/support/devtools_inspector_probe.dart',
  );
  final result = await Process.run(Platform.resolvedExecutable, [
    '--packages=${config.toFilePath()}',
    if (enableAsserts) '--enable-asserts',
    script.toFilePath(),
  ]);
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  final line = (result.stdout as String).trim().split('\n').last;
  return (jsonDecode(line) as Map).cast<String, Object?>();
}
