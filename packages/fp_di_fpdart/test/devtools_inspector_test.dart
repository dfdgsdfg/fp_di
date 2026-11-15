// The DevTools inspector: registration in a debug build only, the query
// answers, the events, and the values on request. The tests mirror the tests
// of the inspector of `fp_di`, and the last group compares the answers with
// the answers that `fp_di` recorded.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fp_di_fpdart/tooling.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';
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
  List<Component<Object?>> components = const [],
  String? debugLabel,
  SlowMutationListener? onSlowMutation,
  Duration slowMutationThreshold = const Duration(seconds: 2),
}) {
  final root = Scope(
    components: components,
    debugLabel: debugLabel,
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
    // from: devtools_inspector_test.dart: the test run has assertions enabled
    expect(asserts, isTrue, reason: 'run the tests with assertions');
  });

  group('registration', () {
    test(
      'registers each service extension once and lists the live root',
      () async {
        // from: devtools_inspector_test.dart: registers each service extension
        // once and lists the live root
        final first = _root(debugLabel: 'first');
        expect(recorder.registrations, _names);
        final second = _root(debugLabel: 'second');
        expect(recorder.registrations, _names, reason: 'a second root');
        rightOf(await first.run());
        rightOf(await second.run());

        var roots = _list((await recorder.call('roots'))['roots']);
        expect([for (final root in roots) root['label']], ['first', 'second']);
        expect(roots[0]['id'], isNot(roots[1]['id']));
        expect(roots[0]['revision'], first.revision);

        rightOf(await first.dispose());
        roots = _list((await recorder.call('roots'))['roots']);
        expect([for (final root in roots) root['label']], ['second']);
        expect(recorder.registrations, _names, reason: 'a disposal');

        _root(); // a third root joins without a new registration
        expect(recorder.registrations, _names);
        expect(_list((await recorder.call('roots'))['roots']), hasLength(2));
      },
    );

    test('a root without a label has the label root and its id', () async {
      final root = _root();
      final id = await _onlyRootId();
      expect(
        _list((await recorder.call('roots'))['roots']).single['label'],
        'root $id',
      );
      expect(root.debugLabel, isNull);
    });

    test(
      'the registry costs the same for each root, also with many roots',
      () async {
        // A walk of the registry at each creation or disposal took 19 s for
        // these roots in fp_di; one lookup takes well under one.
        // from: devtools_inspector_test.dart: the registry costs the same for
        // each root, also with many roots
        const count = 40000;
        final watch = Stopwatch()..start();
        final roots = [
          for (var i = 0; i < count; i++)
            Scope(components: const [], debugLabel: 'many'),
        ];
        for (final root in roots) {
          await root.dispose();
        }
        watch.stop();
        expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
        expect(_list((await recorder.call('roots'))['roots']), isEmpty);
      },
    );

    test('the answers of a dispose in progress do not throw', () async {
      // from: devtools_inspector_test.dart: the answers of a dispose in
      // progress do not throw
      final gate = Completer<void>();
      final root = _root(
        components: [
          Component<int>.effect(
            debugLabel: 'slow release',
            dependency: Dependency<int>(
              create: () => 1,
              dispose: (_) => gate.future,
            ),
          ),
        ],
      );
      rightOf(await root.run());
      final id = await _onlyRootId();
      final disposal = root.dispose();
      await settle();
      expect(root.state.phase, ScopePhase.disposing);
      final answer = await _state(id);
      expect(_scopeOf(answer)['phase'], 'disposing');
      gate.complete();
      rightOf(await disposal);
      expect((await _state(id))['error'], contains('root'));
    });

    test('with assertions off the hooks record nothing; with them on, one '
        'registration', () async {
      // from: devtools_inspector_test.dart: with assertions off the hooks
      // record nothing; with them on, one registration
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

    test('a name that the isolate holds already is skipped, and the root '
        'still works', () async {
      // The real hook registers the names. `fp_di` or an earlier copy of the
      // library can hold a name, and a second registration throws.
      final result = await _probe(
        enableAsserts: true,
        script: 'devtools_collision_probe.dart',
      );
      expect(result['threw'], isFalse);
      expect(result['owned'], [
        'ext.fp_di.roots',
        'ext.fp_di.node',
        'ext.fp_di.shape',
        'ext.fp_di.listen',
      ]);
      expect(result['skipped'], ['ext.fp_di.state']);
      expect(result['phase'], 'initialized');
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  group('queries', () {
    test(
      'roots and state match the runtime, and the calls change nothing',
      () async {
        // from: devtools_inspector_test.dart: roots and state match the
        // runtime, and the calls change nothing
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

    test('state lists the open holds of a waiting disposal', () async {
      // from: devtools_inspector_test.dart: state lists the open holds of a
      // waiting disposal (V-T-TL-DT-006)
      final root = _root(debugLabel: 'app');
      final child = rightOf(root.child(debugLabel: 'page'));
      rightOf(await root.run());
      rightOf(await child.run());
      final rootId = await _onlyRootId();

      final labeled = rightOf(child.disposeHold(debugLabel: 'dialog'));
      final unlabeled = rightOf(child.disposeHold());
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
    });

    test('node details: reads, readers, failure, and cause steps', () async {
      // from: devtools_inspector_test.dart: node details: reads, readers,
      // failure, and cause steps
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
      final failure = fixture.session.nodes[0].activationFailure.toNullable()!;
      expect(login['failure'], {
        'cause': 'Bad state: boom',
        'stackTrace': syntheticStack,
      });
      expect(failure.failures.single, isA<ActivationFailure>());
      expect(
        (failure.failures.single as ActivationFailure).error.toString(),
        'Bad state: boom',
      );
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
      final unavailable = leftOf(
        fixture.session.get<String>(key: const DiKey<String>(name: 'profile')),
      );
      expect(
        [
          for (final step in _list(profile['cause']))
            if (step['phase'] == 'activationFailed') step['node'],
        ],
        [
          for (final failed
              in (unavailable as UnavailableKeyFailure).failedNodeStates)
            failed.id.value,
        ],
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

    test('the shape of a scope has the components of its ancestors', () async {
      // from: devtools_inspector_test.dart: the shape of a scope has the
      // modules of its ancestors
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
        fixture.session.components,
        label: 'session',
        ancestors: [ShapeModule(fixture.root.components, label: 'app')],
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
        // from: devtools_inspector_test.dart: an unknown id gives an error
        // answer that names the argument
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
          components: [Component<int>.value(value: 1, key: baseKey)],
        );
        rightOf(await other.run());
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
        rightOf(await fixture.root.dispose());
        await expectError('state', {'root': '$root'}, 'root');
        await expectError('node', {'root': '$root', 'node': '$node'}, 'root');
        await expectError('shape', {'scope': '${tree['id']}'}, 'scope');
      },
    );

    test('a wrapped handler does not throw into the app', () async {
      // from: devtools_inspector_test.dart: a wrapped handler does not throw
      // into the app
      _root();
      final handler = recorder.handlers['ext.fp_di.state']!;
      final answer = await handler('ext.fp_di.state', {'root': '1', 'x': 'y'});
      expect(answer['format'], 'fp_di.devtools');
    });
  });

  group('events', () {
    test('nothing is posted before listen, and the hook sees the first '
        'event after it', () async {
      // from: devtools_inspector_test.dart: nothing is posted before listen,
      // and the hook sees the first event after it
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
      // from: devtools_inspector_test.dart: the transitions of one turn are
      // one event, and a later turn gives another
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
      // from: devtools_inspector_test.dart: one event for each root that
      // changed
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
      // from: devtools_inspector_test.dart: changed lists the node states with
      // their earlier state
      final fixture = DevtoolsFixture.declare();
      _roots.add(fixture.root);
      rightOf(await fixture.session.run());
      await recorder.call('listen', {'enabled': 'true'});
      rightOf(await fixture.root.run());
      await settle();
      final transitions = recorder.of('fp_di:transition');
      // The awaited `run` runs its microtasks in one turn.
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
      // from: devtools_inspector_test.dart: an error report is posted with a
      // cut stack trace
      final fixture = DevtoolsFixture.declare();
      _roots.add(fixture.root);
      rightOf(await fixture.session.run());
      await recorder.call('listen', {'enabled': 'true'});
      rightOf(await fixture.root.run());
      await settle();
      final errors = recorder.of('fp_di:error');
      expect(errors, isNotEmpty);
      final error = errors.first;
      expect(error['root'], await _onlyRootId());
      expect(error['type'], 'ActivationFailure');
      expect(error['message'], contains('boom'));
      expect(error['stackTrace'], syntheticStack);
      expect(error.containsKey('truncated'), isFalse);
    });

    test('a stack trace over the bound is cut and marked', () async {
      // from: devtools_inspector_test.dart: a stack trace over the bound is cut
      // and marked
      final long = 'frame\n' * 2000; // 12000 characters
      final root = _root(
        components: [Component<int>.value(value: 1, key: baseKey)],
      );
      final child = rightOf(
        root.child(
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
      rightOf(await child.run());
      await recorder.call('listen', {'enabled': 'true'});
      rightOf(await root.run());
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

    test('a slow operation is posted, and the listener of the caller still '
        'runs', () async {
      // from: devtools_inspector_test.dart: a slow mutation is posted, and the
      // listener of the caller still runs
      final gate = Completer<void>();
      final reports = <SlowMutation>[];
      final root = _root(
        onSlowMutation: reports.add,
        slowMutationThreshold: const Duration(milliseconds: 30),
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
      );
      final id = await _onlyRootId();
      await recorder.call('listen', {'enabled': 'true'});
      final setup = root.run();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      gate.complete();
      rightOf(await setup);
      expect(reports, isNotEmpty);
      final posted = recorder.of('fp_di:slowMutation');
      expect(posted.length, reports.length);
      final event = posted.first;
      expect(event['root'], id);
      // The operation of a run is `run` here, where fp_di names it
      // `initialize`.
      expect(event['operation'], 'run');
      expect(event['elapsedMs'], greaterThanOrEqualTo(30));
      expect(event['running'], ['slow']);
      expect(event['ignoringCancellation'], isEmpty);
      expect(event['disposing'], isEmpty);
      expect(event['queued'], 0);
    });

    test('a root without onSlowMutation posts no slow event and starts no '
        'timer', () async {
      // from: devtools_inspector_test.dart: a root without onSlowMutation
      // posts no slow event and starts no timer
      var timers = 0;
      final gate = Completer<void>();
      late final Scope root;
      late final Future<Object?> setup;
      runZoned(
        () {
          root = _root(
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
          );
          setup = root.run();
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
      // from: devtools_inspector_test.dart: listen with enabled false stops
      // the events
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
      rightOf(await fixture.session.run());
      rightOf(await fixture.root.run());
      await settle();
      expect(recorder.of('fp_di:error'), isEmpty);
      expect(recorder.of('fp_di:slowMutation'), isEmpty);
    });

    test('a root that is created while listening posts too', () async {
      // from: devtools_inspector_test.dart: a root that is created while
      // listening posts too
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
        // from: devtools_inspector_test.dart: a listening root can be disposed,
        // and the disposal is posted
        final fixture = await _fixture();
        await recorder.call('listen', {'enabled': 'true'});
        rightOf(await fixture.root.dispose());
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
        // from: devtools_inspector_test.dart: an event lists at most 500
        // changed nodes and counts the rest
        final root = _root(
          components: [
            for (var i = 0; i < 600; i++)
              Component<int>.effect(
                debugLabel: 'n$i',
                dependency: Dependency<int>(create: () => i),
              ),
          ],
        );
        await recorder.call('listen', {'enabled': 'true'});
        rightOf(await root.run());
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

  group('values', () {
    Future<Scope> valuesRoot({
      bool listenFirst = false,
      bool values = false,
    }) async {
      final root = _root(
        components: [
          Component<_Secret>.value(value: _Secret(), debugLabel: 'secret'),
          Component<_Long>.value(value: _Long(), debugLabel: 'long'),
          Component<_Thrower>.value(value: _Thrower(), debugLabel: 'thrower'),
          Component<_Emoji>.value(value: _Emoji(), debugLabel: 'emoji'),
        ],
      );
      if (listenFirst) {
        await recorder.call('listen', {
          'enabled': 'true',
          if (values) 'values': 'true',
        });
      }
      rightOf(await root.run());
      await settle();
      return root;
    }

    test('no value text appears without the request', () async {
      // from: devtools_inspector_test.dart: no value text appears without the
      // request
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
      rightOf(await root.nodes[0].dispose());
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
      // from: devtools_inspector_test.dart: the state answer shows values on
      // request, cut and guarded
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
      // from: devtools_inspector_test.dart: a node without a value has a null
      // text
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
      // from: devtools_inspector_test.dart: the node answer shows values on
      // request
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
      // from: devtools_inspector_test.dart: listen with values puts the value
      // text in an event
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

  group('compatibility with the recorded answers of fp_di', () {
    // The recorded answers of the inspector of fp_di are the contract of the
    // extension app. The same scenario here must give the same keys and the
    // same types, and the same value for each field that holds no id, no
    // revision, and no type name of an error.
    late Directory recorded;
    setUpAll(() async {
      final library = await Isolate.resolvePackageUri(
        Uri.parse('package:fp_di_fpdart/fp_di_fpdart.dart'),
      );
      if (library == null) fail('The package of the test is not available.');
      recorded = Directory.fromUri(
        library.resolve('../../fp_di/test/support/devtools_fixtures/'),
      );
    });
    Map<String, Object?> load(String name) =>
        (jsonDecode(File('${recorded.path}/$name.json').readAsStringSync())
                as Map<String, Object?>)
            .cast<String, Object?>();

    test('the recorded answers are in the workspace', () {
      expect(recorded.existsSync(), isTrue, reason: recorded.path);
    });

    test(
      'state, node, shape, and error answers have the recorded schema',
      () async {
        final fixture = DevtoolsFixture.declare();
        _roots.add(fixture.root);
        rightOf(await fixture.session.run());
        await recorder.call('listen', {'enabled': 'true'});
        rightOf(await fixture.root.run());
        rightOf(await _right(fixture.root.node<int>(key: doomedKey)).dispose());
        await settle();

        final rootId = await _onlyRootId();
        final state = await recorder.call('state', {'root': '$rootId'});
        final tree = _scopeOf(state);
        Future<Map<String, Object?>> node(
          String label, {
          bool values = false,
        }) => recorder.call('node', {
          'root': '$rootId',
          'node': '${nodeIdByLabel(tree, label)}',
          if (values) 'values': 'true',
        });
        final answers = <String, Map<String, Object?>>{
          'state': state,
          'state_values': await recorder.call('state', {
            'root': '$rootId',
            'values': 'true',
          }),
          'node_waiting': await node('profile'),
          'node_failed': await node('login'),
          'node_collection': await node('registry'),
          'node_values': await node('config', values: true),
          'shape': await recorder.call('shape', {
            'scope': '${scopeByModule(tree, 'session')!['id']}',
          }),
          'error_unknown_root': await recorder.call('state', {'root': '999'}),
        };
        for (final MapEntry(:key, :value) in answers.entries) {
          _expectSameSchema(value, load(key), key);
        }
        // The scenario is the scenario that fp_di recorded, so each answer is
        // equal to the recorded answer, but for the `revision` of the runtime.
        for (final MapEntry(:key, :value) in answers.entries) {
          expect(
            _withoutRevision(value),
            _withoutRevision(load(key)),
            reason: key,
          );
        }
      },
    );

    test('transition and error events equal the recorded events', () async {
      final fixture = DevtoolsFixture.declare();
      _roots.add(fixture.root);
      rightOf(await fixture.session.run());
      await recorder.call('listen', {'enabled': 'true'});
      rightOf(await fixture.root.run());
      rightOf(await _right(fixture.root.node<int>(key: doomedKey)).dispose());
      await settle();
      final transitions = recorder.of('fp_di:transition');
      final transition = transitions.firstWhere(
        (event) => _list(event['changed']).any(
          (change) => (change['after'] as Map?)?['phase'] == 'activationFailed',
        ),
      );
      expect(
        _withoutRevision(transition),
        _withoutRevision(load('event_transition')),
      );
      final error = recorder.of('fp_di:error').first;
      final recordedError = load('event_error');
      _expectSameSchema(error, recordedError, 'error');
      // The type and the message name the failure of this package. The other
      // fields, with the stack trace of the failed step, are equal.
      expect(error['type'], 'ActivationFailure');
      expect(error['message'], 'login failed to activate: Bad state: boom');
      expect(
        {...error}
          ..remove('type')
          ..remove('message'),
        {...recordedError}
          ..remove('type')
          ..remove('message'),
      );
    });

    test(
      'the slow event and the roots answer have the recorded schema',
      () async {
        final gate = Completer<void>();
        final fixture = DevtoolsFixture.declare();
        _roots.add(fixture.root);
        final slow = _root(
          debugLabel: 'slow app',
          onSlowMutation: (_) {},
          slowMutationThreshold: const Duration(milliseconds: 20),
          components: [
            Component<int>.effect(
              debugLabel: 'warm cache',
              dependency: Dependency<int>(
                create: () async {
                  await gate.future;
                  return 1;
                },
              ),
            ),
          ],
        );
        await recorder.call('listen', {'enabled': 'true'});
        final setup = slow.run();
        while (recorder.of('fp_di:slowMutation').isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        gate.complete();
        rightOf(await setup);
        final event = {
          ...recorder.of('fp_di:slowMutation').first,
          'elapsedMs': 20,
        };
        _expectSameSchema(event, load('event_slow_mutation'), 'slow');
        expect(event['running'], ['warm cache']);
        _expectSameSchema(await recorder.call('roots'), load('roots'), 'roots');
      },
    );
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
  // Each U+1F600 is a surrogate pair, so the cut at 4096 falls between the two
  // halves of the pair that starts at 4095.
  @override
  String toString() => 'a${'\u{1F600}' * 3000}';
}

T _right<T>(Either<DiFailure, T> either) => rightOf(either);

/// [json] without the `revision` of the runtime, which depends on the number of
/// transitions of the scenario.
Object? _withoutRevision(Object? json) => switch (json) {
  final Map<Object?, Object?> map => {
    for (final MapEntry(:key, :value) in map.entries)
      if (key != 'revision') key: _withoutRevision(value),
  },
  final List<Object?> list => [
    for (final value in list) _withoutRevision(value),
  ],
  _ => json,
};

/// Checks that [actual] has the schema of [recorded]: the same keys, and the
/// same kind of value at each key.
///
/// A recorded `null` accepts any value, and the reverse, because a field such
/// as a failure is `null` or a map by scenario. The elements of a list have
/// the schema of some element on the other side, and an empty list accepts
/// any list, because the number of nodes that a transition lists depends on the
/// timing of the scenario.
void _expectSameSchema(Object? actual, Object? recorded, String where) {
  final problem = _schemaProblem(actual, recorded, where);
  expect(problem, isNull, reason: problem);
}

String? _schemaProblem(Object? actual, Object? recorded, String where) {
  if (recorded == null || actual == null) return null;
  if (recorded is Map<Object?, Object?>) {
    if (actual is! Map<Object?, Object?>) return '$where: no object';
    if (!actual.keys.toSet().containsAll(recorded.keys) ||
        !recorded.keys.toSet().containsAll(actual.keys)) {
      return '$where: the keys differ: ${actual.keys} and ${recorded.keys}';
    }
    for (final key in recorded.keys) {
      final problem = _schemaProblem(actual[key], recorded[key], '$where.$key');
      if (problem != null) return problem;
    }
    return null;
  }
  if (recorded is List<Object?>) {
    if (actual is! List<Object?>) return '$where: no list';
    if (recorded.isEmpty || actual.isEmpty) return null;
    for (final element in actual) {
      if (recorded.every((r) => _schemaProblem(element, r, where) != null)) {
        return '$where: an element has no recorded schema: $element';
      }
    }
    for (final element in recorded) {
      if (actual.every((a) => _schemaProblem(a, element, where) != null)) {
        return '$where: a recorded element is missing: $element';
      }
    }
    return null;
  }
  return actual.runtimeType == recorded.runtimeType
      ? null
      : '$where: ${actual.runtimeType} and ${recorded.runtimeType}';
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
  expect(json['module'], scope.debugLabel);
  expect(json['holds'], holds, reason: 'the open holds of the scope');
  final nodes = _list(json['nodes']);
  expect(nodes, hasLength(state.nodeStates.length));
  for (var i = 0; i < nodes.length; i++) {
    final node = state.nodeStates[i];
    expect(nodes[i]['id'], node.id.value);
    expect(ids.add(node.id.value), isTrue, reason: 'one id for each node');
    expect(nodes[i]['label'], node.label);
    expect(nodes[i]['key'], node.key.map((key) => key.toString()).toNullable());
    expect(nodes[i]['phase'], node.phase.name);
    expect(nodes[i]['missing'], [for (final key in node.missing) '$key']);
    expect(nodes[i]['commits'], node.commits);
    expect(nodes[i]['failure'] == null, node.activationFailure.isNone());
    expect(
      nodes[i]['origin'],
      scope.debugLabel,
      reason: 'the origin of the component is the label of its scope',
    );
  }
  final childJson = _list(json['children']);
  expect(childJson, hasLength(state.childStates.length));
  expect(childJson, hasLength(children.length));
  for (var i = 0; i < childJson.length; i++) {
    _expectMatches(childJson[i], children[i], state.childStates[i], ids);
  }
}

/// Runs a probe script of `test/support/` in a new process, with or without
/// assertions, and returns the JSON line that it prints.
Future<Map<String, Object?>> _probe({
  required bool enableAsserts,
  String script = 'devtools_inspector_probe.dart',
}) async {
  final config = await Isolate.packageConfig;
  final library = await Isolate.resolvePackageUri(
    Uri.parse('package:fp_di_fpdart/fp_di_fpdart.dart'),
  );
  if (config == null || library == null) {
    fail('The package configuration of the test run is not available.');
  }
  final path = library.resolve('../test/support/$script');
  final result = await Process.run(Platform.resolvedExecutable, [
    '--packages=${config.toFilePath()}',
    if (enableAsserts) '--enable-asserts',
    path.toFilePath(),
  ]);
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  final line = (result.stdout as String).trim().split('\n').last;
  return (jsonDecode(line) as Map).cast<String, Object?>();
}
