import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fp_di_devtools/src/app.dart';
import 'package:fp_di_devtools/src/model.dart';

import 'support/fake_client.dart';

/// Pumps the app on a wide surface, as DevTools gives it.
Future<FakeInspectorClient> pumpApp(
  WidgetTester tester, {
  FakeInspectorClient? client,
}) async {
  tester.view.physicalSize = const Size(1800, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fake = client ?? FakeInspectorClient();
  addTearDown(fake.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: FpDiInspector(client: fake)),
    ),
  );
  await tester.pumpAndSettle();
  return fake;
}

Future<void> selectScope(WidgetTester tester, int id) async {
  await tester.tap(find.byKey(Key('scope-$id')));
  await tester.pumpAndSettle();
}

Future<void> selectNode(WidgetTester tester, int id) async {
  await tester.tap(find.byKey(Key('node-$id')));
  await tester.pumpAndSettle();
}

Future<void> openTab(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(Key('tab-$name')));
  await tester.pumpAndSettle();
}

void main() {
  group('start', () {
    testWidgets('calls roots first, then listen, then state', (tester) async {
      final fake = await pumpApp(tester);
      final names = [for (final call in fake.calls) call.method];
      expect(names.take(3), [
        'ext.fp_di.roots',
        'ext.fp_di.listen',
        'ext.fp_di.state',
      ]);
      expect(fake.callsTo('listen').single.args, {'enabled': 'true'});
      expect(fake.callsTo('state').single.args, {'root': '1'});
    });

    testWidgets('shows the roots and the scope tree with phases', (
      tester,
    ) async {
      await pumpApp(tester);
      expect(find.byKey(const Key('root-1')), findsOneWidget);
      expect(find.text('app'), findsWidgets);
      expect(find.text('slow app'), findsOneWidget);
      expect(find.text('rev 30'), findsOneWidget);
      // The three scopes of root 1, with the phase of each.
      expect(find.byKey(const Key('scope-1')), findsOneWidget);
      expect(find.byKey(const Key('scope-2')), findsOneWidget);
      expect(find.byKey(const Key('scope-3')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('scope-2')),
          matching: find.text('session'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('scope-3')),
          matching: find.text('scope 3'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('scope-3')),
          matching: find.text('declared'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('scope-1')),
          matching: find.text('initialized'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('selecting another root loads its state', (tester) async {
      final fake = await pumpApp(tester);
      await tester.tap(find.byKey(const Key('root-2')));
      await tester.pumpAndSettle();
      expect(fake.callsTo('state').last.args, {'root': '2'});
      expect(find.byKey(const Key('scope-10')), findsOneWidget);
      expect(find.byKey(const Key('scope-2')), findsNothing);
    });
  });

  group('nodes', () {
    testWidgets('list the nodes of the selected scope', (tester) async {
      await pumpApp(tester);
      // The root scope is selected at the start.
      for (final label in [
        'config',
        'base',
        'greeter',
        'pluginA',
        'pluginB',
        'registry',
        'doomed',
        'orphan',
      ]) {
        expect(find.text(label), findsWidgets, reason: label);
      }
      expect(find.text('DiKey<String>(config)'), findsOneWidget);
      // The key of `doomed` and the missing key of `orphan`.
      expect(find.text('DiKey<int>(doomed)'), findsNWidgets(2));
      // A missing key of the waiting node.
      expect(
        find.descendant(
          of: find.byKey(const Key('node-9')),
          matching: find.text('DiKey<int>(doomed)'),
        ),
        findsOneWidget,
      );

      await selectScope(tester, 2);
      final login = find.byKey(const Key('node-0'));
      expect(find.byKey(const Key('node-1')), findsOneWidget);
      expect(
        find.descendant(of: login, matching: find.text('login')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: login, matching: find.text('activationFailed')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('node-1')),
          matching: find.text('DiKey<int>(token)'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('node-1')),
          matching: find.text('waiting'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('node-2')), findsNothing);
    });

    testWidgets('the phase filter narrows the nodes', (tester) async {
      await pumpApp(tester);
      expect(find.byKey(const Key('node-8')), findsOneWidget);
      expect(find.byKey(const Key('node-9')), findsOneWidget);
      expect(find.byKey(const Key('node-2')), findsOneWidget);

      await tester.tap(find.byKey(const Key('phase-waiting')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('node-9')), findsOneWidget);
      expect(find.byKey(const Key('node-2')), findsNothing);
      expect(find.byKey(const Key('node-8')), findsNothing);

      await tester.tap(find.byKey(const Key('phase-disposed')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('node-8')), findsOneWidget);
      expect(find.byKey(const Key('node-9')), findsNothing);

      await tester.tap(find.byKey(const Key('phase-all')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('node-2')), findsOneWidget);
      expect(find.byKey(const Key('node-9')), findsOneWidget);
    });

    testWidgets('the key search narrows the nodes', (tester) async {
      await pumpApp(tester);
      await tester.enterText(find.byKey(const Key('key-search')), 'GREETING');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('node-4')), findsOneWidget);
      expect(find.byKey(const Key('node-2')), findsNothing);
      expect(find.byKey(const Key('node-9')), findsNothing);

      await tester.enterText(find.byKey(const Key('key-search')), 'nothing');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('no-nodes')), findsOneWidget);

      await tester.enterText(find.byKey(const Key('key-search')), '');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('node-2')), findsOneWidget);
    });

    testWidgets('the phase filter and the search combine', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.byKey(const Key('phase-active')));
      await tester.enterText(find.byKey(const Key('key-search')), 'int>');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('node-3')), findsOneWidget);
      expect(find.byKey(const Key('node-2')), findsNothing);
      expect(find.byKey(const Key('node-9')), findsNothing);
    });
  });

  group('details', () {
    testWidgets('show the failure of a node with its stack trace', (
      tester,
    ) async {
      final fake = await pumpApp(tester);
      await selectScope(tester, 2);
      await selectNode(tester, 0);
      expect(fake.callsTo('node').last.args, {'root': '1', 'node': '0'});
      expect(find.byKey(const Key('details-label')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('details')),
          matching: find.text('StateError: Bad state: boom'),
        ),
        findsOneWidget,
      );
      expect(find.text('cause: Bad state: boom'), findsOneWidget);
      expect(
        find.textContaining(
          'Login.start (package:shop/session/login.dart:41:7)',
        ),
        findsOneWidget,
      );
      // The read of the key that the app published, with its publisher.
      expect(find.text('require'), findsOneWidget);
      expect(find.byKey(const Key('publisher-3')), findsOneWidget);
      // The search of an unavailable key has one step.
      expect(find.text('Cause of the unavailable key'), findsOneWidget);
    });

    testWidgets('show the waiting node with its cause steps', (tester) async {
      await pumpApp(tester);
      await selectScope(tester, 2);
      await selectNode(tester, 1);
      final details = find.byKey(const Key('details'));
      expect(
        find.descendant(
          of: details,
          matching: find.text('waits for DiKey<int>(token)'),
        ),
        findsOneWidget,
      );
      expect(find.text('unresolved'), findsOneWidget);
      expect(find.byKey(const Key('cause-node-1')), findsOneWidget);
      expect(find.byKey(const Key('cause-node-0')), findsOneWidget);
      expect(
        find.descendant(of: details, matching: find.text('activationFailed')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('no-readers')), findsOneWidget);
    });

    testWidgets('show a collection read with its members', (tester) async {
      await pumpApp(tester);
      await selectNode(tester, 7);
      expect(find.text('collection'), findsOneWidget);
      expect(find.text('DiSetKey<String>(plugins)'), findsOneWidget);
      expect(find.text('member'), findsNWidgets(2));
      expect(find.byKey(const Key('publisher-5')), findsOneWidget);
      expect(find.byKey(const Key('publisher-6')), findsOneWidget);
    });

    testWidgets('show the readers of a node', (tester) async {
      await pumpApp(tester);
      await selectNode(tester, 2);
      expect(find.byKey(const Key('reader-4')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('reader-4')),
          matching: find.text('greeter'),
        ),
        findsOneWidget,
      );
      // A value stays hidden until the author asks for it.
      expect(find.byKey(const Key('details-value')), findsNothing);
    });

    testWidgets('following a reader selects its node', (tester) async {
      final fake = await pumpApp(tester);
      await selectNode(tester, 2);
      await tester.tap(find.byKey(const Key('reader-4')));
      await tester.pumpAndSettle();
      expect(fake.callsTo('node').last.args, {'root': '1', 'node': '4'});
      expect(
        tester.widget<Text>(find.byKey(const Key('details-label'))).data,
        'greeter',
      );
    });

    testWidgets('following a key selects its publisher', (tester) async {
      final fake = await pumpApp(tester);
      await selectScope(tester, 2);
      await selectNode(tester, 0);
      expect(find.text('login'), findsWidgets);

      // `login` reads `base`, which node 3 of the other scope publishes.
      await tester.tap(find.byKey(const Key('publisher-3')));
      await tester.pumpAndSettle();
      expect(fake.callsTo('node').last.args, {'root': '1', 'node': '3'});
      expect(
        tester.widget<Text>(find.byKey(const Key('details-label'))).data,
        'base',
      );
      // The selection moved to the scope of the publisher.
      expect(find.byKey(const Key('node-3')), findsOneWidget);
      expect(find.byKey(const Key('node-0')), findsNothing);
    });

    testWidgets('following a member selects the publisher of the member', (
      tester,
    ) async {
      await pumpApp(tester);
      await selectNode(tester, 7);
      await tester.tap(find.byKey(const Key('publisher-6')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('details-label'))).data,
        'pluginB',
      );
    });

    testWidgets('following a cause step selects its node', (tester) async {
      await pumpApp(tester);
      await selectScope(tester, 2);
      await selectNode(tester, 1);
      await tester.tap(find.byKey(const Key('cause-node-0')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('details-label'))).data,
        'login',
      );
    });
  });

  group('values', () {
    testWidgets('the toggle asks for values and shows them', (tester) async {
      final fake = await pumpApp(tester);
      await selectNode(tester, 2);
      expect(find.text('prod'), findsNothing);

      await tester.tap(find.byKey(const Key('values-toggle')));
      await tester.pumpAndSettle();
      expect(fake.callsTo('listen').last.args, {
        'enabled': 'true',
        'values': 'true',
      });
      expect(fake.callsTo('state').last.args, {'root': '1', 'values': 'true'});
      expect(fake.callsTo('node').last.args, {
        'root': '1',
        'node': '2',
        'values': 'true',
      });
      expect(find.text('hello prod'), findsOneWidget);
      expect(find.text('[a, b]'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('details-value'))).data,
        'prod',
      );

      await tester.tap(find.byKey(const Key('values-toggle')));
      await tester.pumpAndSettle();
      expect(fake.callsTo('listen').last.args, {'enabled': 'true'});
      expect(find.text('hello prod'), findsNothing);
    });
  });

  group('graph', () {
    testWidgets('shows the members in depth order with their phases', (
      tester,
    ) async {
      final fake = await pumpApp(tester);
      await selectScope(tester, 2);
      expect(fake.callsTo('shape').last.args, {'scope': '2'});
      await openTab(tester, 'graph');

      expect(find.text('Shape of session'), findsOneWidget);
      expect(find.text('Ancestor modules: app'), findsOneWidget);
      final depthOne = tester.getTopLeft(find.text('Depth 1'));
      final depthTwo = tester.getTopLeft(find.text('Depth 2'));
      expect(depthOne.dy, lessThan(depthTwo.dy));

      final login = find.byKey(const Key('member-0'));
      final profile = find.byKey(const Key('member-1'));
      expect(
        find.descendant(of: login, matching: find.text('activationFailed')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: profile, matching: find.text('waiting')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: login,
          matching: find.text('publishes DiKey<int>(token)'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: profile,
          matching: find.text('waits for DiKey<int>(token)'),
        ),
        findsOneWidget,
      );
      // The color of the card follows the phase.
      final decoration =
          tester.widget<Container>(login).decoration! as BoxDecoration;
      expect((decoration.border! as Border).top.color, Colors.red.shade600);
      expect(find.byKey(const Key('longest-chain')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('longest-chain'))).data,
        'login → profile',
      );
      expect(find.byKey(const Key('no-cycles')), findsOneWidget);
      expect(find.byKey(const Key('undeclared')), findsOneWidget);
      expect(find.byKey(const Key('duplicates')), findsOneWidget);
    });

    testWidgets('lists cycles, undeclared keys, and duplicate keys', (
      tester,
    ) async {
      // The recorded shape with a cycle, an undeclared key, and a duplicate.
      final graph = Map<String, Object?>.from(fixture('shape')['shape']! as Map)
        ..['cycles'] = [
          [0, 1],
        ]
        ..['undeclared'] = ['DiKey<int>(missing)']
        ..['duplicates'] = ['DiKey<int>(twice)'];
      final fake = FakeInspectorClient()..shapeOverride = graph;
      await pumpApp(tester, client: fake);
      await selectScope(tester, 2);
      await openTab(tester, 'graph');

      expect(find.byKey(const Key('no-cycles')), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const Key('cycle'))).data,
        'login → profile → login',
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('undeclared')),
          matching: find.text('DiKey<int>(missing)'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('duplicates')),
          matching: find.text('DiKey<int>(twice)'),
        ),
        findsOneWidget,
      );
    });
  });

  group('timeline', () {
    testWidgets('is empty before an event', (tester) async {
      await pumpApp(tester);
      await openTab(tester, 'timeline');
      expect(find.byKey(const Key('empty-timeline')), findsOneWidget);
    });

    testWidgets('a transition reloads the state and appears in the timeline', (
      tester,
    ) async {
      final fake = await pumpApp(tester);
      expect(fake.callsTo('state'), hasLength(1));

      fake.emit(EventKinds.transition, fixture('event_transition'));
      await tester.pumpAndSettle();
      expect(fake.callsTo('state'), hasLength(2));
      expect(fake.callsTo('state').last.args, {'root': '1'});

      await openTab(tester, 'timeline');
      expect(find.byKey(const Key('timeline-0')), findsOneWidget);
      expect(
        find.textContaining('transition · root 1 · revision 30 · 9 nodes'),
        findsOneWidget,
      );
      expect(
        find.textContaining('login: waiting → activationFailed'),
        findsOneWidget,
      );
      expect(find.textContaining('config: new → active'), findsOneWidget);
    });

    testWidgets('a transition of another root does not reload the state', (
      tester,
    ) async {
      final fake = await pumpApp(tester);
      final event = fixture('event_transition')..['root'] = 2;
      fake.emit(EventKinds.transition, event);
      await tester.pumpAndSettle();
      expect(fake.callsTo('state'), hasLength(1));
      await openTab(tester, 'timeline');
      expect(find.textContaining('transition · root 2'), findsOneWidget);
    });

    testWidgets('errors and slow mutations come in order, newest last', (
      tester,
    ) async {
      final fake = await pumpApp(tester);
      fake
        ..emit(EventKinds.transition, fixture('event_transition'))
        ..emit(EventKinds.error, fixture('event_error'))
        ..emit(EventKinds.slowMutation, fixture('event_slow_mutation'));
      await tester.pumpAndSettle();
      await openTab(tester, 'timeline');

      expect(
        find.textContaining('error · root 1 · ActivationException'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Component activation failed: Bad state: boom'),
        findsOneWidget,
      );
      expect(
        find.textContaining('slow mutation · root 2 · initialize · 20 ms'),
        findsOneWidget,
      );
      expect(find.textContaining('running: warm cache'), findsOneWidget);

      final transition = tester.getTopLeft(find.byKey(const Key('timeline-0')));
      final error = tester.getTopLeft(find.byKey(const Key('timeline-1')));
      final slow = tester.getTopLeft(find.byKey(const Key('timeline-2')));
      expect(transition.dy, lessThan(error.dy));
      expect(error.dy, lessThan(slow.dy));
    });

    testWidgets('an event of an unknown root reloads the roots', (
      tester,
    ) async {
      final fake = await pumpApp(tester);
      expect(fake.callsTo('roots'), hasLength(1));
      fake.emit(EventKinds.error, fixture('event_error')..['root'] = 77);
      await tester.pumpAndSettle();
      expect(fake.callsTo('roots'), hasLength(2));
    });
  });

  group('connection', () {
    testWidgets('without an app, states that the extension needs one', (
      tester,
    ) async {
      final fake = await pumpApp(
        tester,
        client: FakeInspectorClient(connected: false),
      );
      expect(find.byKey(const Key('no-connection')), findsOneWidget);
      expect(find.textContaining('needs a connected app'), findsOneWidget);
      expect(fake.calls, isEmpty);
      expect(find.byKey(const Key('values-toggle')), findsNothing);

      // The app connects later.
      fake.setConnected(true);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('no-connection')), findsNothing);
      expect(find.byKey(const Key('root-1')), findsOneWidget);

      fake.setConnected(false);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('no-connection')), findsOneWidget);
    });

    testWidgets('another version shows both versions and nothing else', (
      tester,
    ) async {
      final fake = await pumpApp(
        tester,
        client: FakeInspectorClient(version: 2),
      );
      expect(find.byKey(const Key('version-mismatch')), findsOneWidget);
      expect(
        find.textContaining('reads version $protocolVersion'),
        findsOneWidget,
      );
      expect(find.textContaining('serves version 2'), findsOneWidget);
      expect(find.byKey(const Key('values-toggle')), findsNothing);
      expect(find.byKey(const Key('root-1')), findsNothing);
      expect(find.byType(TabBar), findsNothing);
      // The app asked for nothing after the first answer.
      expect(fake.calls, hasLength(1));
    });

    testWidgets('an event of another version shows the version message', (
      tester,
    ) async {
      final fake = await pumpApp(tester);
      fake.emit(
        EventKinds.transition,
        fixture('event_transition')..['version'] = 3,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('version-mismatch')), findsOneWidget);
      expect(find.textContaining('serves version 3'), findsOneWidget);
    });

    testWidgets('an error answer shows its message and keeps the views', (
      tester,
    ) async {
      final fake = await pumpApp(tester);
      // The inspector answers the next `state` with an error, as it does
      // for a root that was disposed.
      fake.failing.add('state');
      fake.emit(EventKinds.transition, fixture('event_transition'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('error-banner'))).data,
        'root: unknown id 999',
      );
      expect(find.byKey(const Key('root-1')), findsOneWidget);
      expect(find.byKey(const Key('node-2')), findsOneWidget);

      // The next successful reload removes the message.
      fake.failing.clear();
      fake.emit(EventKinds.transition, fixture('event_transition'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('error-banner')), findsNothing);
    });

    testWidgets('listens again and reloads after the app restarts', (
      tester,
    ) async {
      final fake = await pumpApp(tester);
      expect(fake.callsTo('listen'), hasLength(1));
      await selectScope(tester, 2);
      await selectNode(tester, 0);

      fake.restart();
      await tester.pumpAndSettle();
      expect(fake.callsTo('roots'), hasLength(2));
      expect(fake.callsTo('listen'), hasLength(2));
      expect(fake.callsTo('listen').last.args, {'enabled': 'true'});
      expect(fake.callsTo('state'), hasLength(2));
      // The ids of the restarted app start again, so the selection is gone.
      expect(find.byKey(const Key('no-selected-node')), findsOneWidget);
    });
  });
}
