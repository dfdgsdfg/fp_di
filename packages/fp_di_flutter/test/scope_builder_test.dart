// `ScopeBuilder` creates, initializes, publishes, and disposes a scope, and
// builds from its state (R-UC-AR-UI-006, V-T-AR-UI-013).

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fp_di/fp_di.dart';
import 'package:fp_di_flutter/fp_di_flutter.dart';

const _name = DiKey<String>(name: 'name');
const _greeting = DiKey<String>(name: 'greeting');
const _slow = DiKey<String>(name: 'slow');

Module _appModule(String name) => Module(
  components: [Component<String>.value(value: name, key: _name)],
);

/// A child module whose member reads the name of the parent.
Module _greetingModule() => Module(
  components: [
    Component<String>(
      dependency: Dependency1<String, String>(
        key1: _name,
        create: (name) => 'hello $name',
      ),
      key: _greeting,
    ),
  ],
);

/// A text of the snapshot, as a builder would switch on it.
String _describe(ScopeSnapshot snapshot) => switch (snapshot) {
  ScopeSnapshot(:final error?) => 'error ${_causeOf(error)}',
  ScopeSnapshot(phase: ScopePhase.initialized) => 'ready',
  ScopeSnapshot(:final phase) => phase.name,
};

Object _causeOf(Object error) =>
    error is ActivationException ? error.cause : error;

Widget _host(Scope parent, Widget child) => Directionality(
  textDirection: TextDirection.ltr,
  child: ScopeProvider.fixed(scope: parent, child: child),
);

/// Watches [key] with a context below the builder.
Widget _reader(DiKey<String> key) => Builder(
  builder: (context) =>
      Text(context.watchMaybeDi<String>(key: key) ?? 'absent'),
);

void main() {
  testWidgets('creates a child, shows each phase, and publishes the child', (
    tester,
  ) async {
    final app = await Scope(module: _appModule('ada')).initialize();
    final open = Completer<String>();
    Scope? created;
    final seen = <String>[];

    await tester.pumpWidget(
      _host(
        app,
        ScopeBuilder(
          create: (parent) {
            expect(parent, same(app));
            return created = parent.child(
              module: Module(
                components: [
                  Component<String>(
                    dependency: Dependency<String>(create: () => open.future),
                    key: _slow,
                  ),
                ],
              ),
            );
          },
          builder: (context, snapshot, child) {
            seen.add(_describe(snapshot));
            expect(snapshot.scope, same(created));
            // The builder context is below the published child, so a key of
            // the parent answers from the first build.
            return Column(
              children: [
                Text('name ${context.di<String>(key: _name)}'),
                if (snapshot.phase == ScopePhase.initialized) child!,
              ],
            );
          },
          child: _reader(_slow),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('name ada'), findsOneWidget);
    expect(seen.last, 'initializing');

    open.complete('opened');
    await tester.pump();
    await tester.pump();
    expect(seen.last, 'ready');
    expect(find.text('opened'), findsOneWidget);

    await tester.pumpWidget(_host(app, const SizedBox()));
    await tester.pump();
    expect(created!.isDisposed, isTrue);
    expect(app.isDisposed, isFalse);
    expect(tester.takeException(), isNull);
    await app.dispose();
  });

  testWidgets('shows the failure of initialize', (tester) async {
    final app = await Scope(module: _appModule('ada')).initialize();
    late ScopeSnapshot last;

    await tester.pumpWidget(
      _host(
        app,
        ScopeBuilder(
          create: (parent) => parent.child(
            module: Module(
              components: [
                Component<String>(
                  dependency: Dependency<String>(
                    create: () => throw StateError('no store'),
                  ),
                  key: _slow,
                ),
              ],
            ),
          ),
          builder: (context, snapshot, child) {
            last = snapshot;
            return Text(_describe(snapshot));
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('error Bad state: no store'), findsOneWidget);
    expect(last.hasError, isTrue);
    expect(last.error, isA<ActivationException>());
    expect(last.stackTrace, isNotNull);
    // The rollback returns the scope to declared, so only the snapshot keeps
    // the failure.
    expect(last.phase, ScopePhase.declared);
    expect(tester.takeException(), isNull);
    await app.dispose();
  });

  testWidgets('an unmount during initialize cancels it and reports the '
      'failures of the rollback', (tester) async {
    final app = await Scope(module: _appModule('ada')).initialize();
    final slow = Completer<String>();
    Scope? created;

    await tester.pumpWidget(
      _host(
        app,
        ScopeBuilder(
          create: (parent) => created = parent.child(
            module: Module(
              components: [
                Component<String>(
                  dependency: Dependency<String>(
                    create: () => 'fast',
                    dispose: (_) => throw StateError('close failed'),
                  ),
                  key: _greeting,
                ),
                Component<String>(
                  dependency: Dependency<String>(create: () => slow.future),
                  key: _slow,
                ),
              ],
            ),
          ),
          builder: (context, snapshot, child) => Text(_describe(snapshot)),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('initializing'), findsOneWidget);

    await tester.pumpWidget(_host(app, const SizedBox()));
    expect(created!.isDisposed, isTrue);
    // The disposal cancels the activation, and the rollback runs when the
    // slow work ends.
    slow.complete('late');
    await tester.pump();
    await tester.pump();

    final reported = tester.takeException();
    expect(reported, isA<ActivationCanceledException>());
    expect(
      (reported as ActivationCanceledException).rollbackFailures,
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
    await app.dispose();
  });

  testWidgets('a canceled initialize without a failed rollback is not '
      'reported', (tester) async {
    final app = await Scope(module: _appModule('ada')).initialize();
    final slow = Completer<String>();

    await tester.pumpWidget(
      _host(
        app,
        ScopeBuilder(
          create: (parent) => parent.child(
            module: Module(
              components: [
                Component<String>(
                  dependency: Dependency<String>(create: () => slow.future),
                  key: _slow,
                ),
              ],
            ),
          ),
          builder: (context, snapshot, child) => Text(_describe(snapshot)),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(_host(app, const SizedBox()));
    slow.complete('late');
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    await app.dispose();
  });

  testWidgets('the failure of a disposal is reported', (tester) async {
    final app = await Scope(module: _appModule('ada')).initialize();

    await tester.pumpWidget(
      _host(
        app,
        ScopeBuilder(
          create: (parent) => parent.child(
            module: Module(
              components: [
                Component<String>(
                  dependency: Dependency<String>(
                    create: () => 'store',
                    dispose: (_) => throw StateError('close failed'),
                  ),
                  key: _slow,
                ),
              ],
            ),
          ),
          builder: (context, snapshot, child) => Text(_describe(snapshot)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('ready'), findsOneWidget);

    await tester.pumpWidget(_host(app, const SizedBox()));
    await tester.pump();

    expect(tester.takeException(), isA<DisposeException>());
    await app.dispose();
  });

  testWidgets('a replacement of the scope above makes a new child and '
      'disposes the old one', (tester) async {
    final ada = await Scope(module: _appModule('ada')).initialize();
    final bob = await Scope(module: _appModule('bob')).initialize();
    final current = ValueNotifier<Scope>(ada);
    final created = <Scope>[];

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ScopeProvider.listenable(
          scope: current,
          child: ScopeBuilder(
            create: (parent) {
              final child = parent.child(module: _greetingModule());
              created.add(child);
              return child;
            },
            builder: (context, snapshot, child) => child!,
            child: _reader(_greeting),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('hello ada'), findsOneWidget);

    current.value = bob;
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(created, hasLength(2));
    expect(created.first.isDisposed, isTrue);
    expect(created.last.isDisposed, isFalse);
    expect(find.text('hello bob'), findsOneWidget);

    // A rebuild with the same scope above makes no new child.
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ScopeProvider.listenable(
          scope: current,
          child: ScopeBuilder(
            create: (parent) => fail('create runs only for a new parent'),
            builder: (context, snapshot, child) => child!,
            child: _reader(_greeting),
          ),
        ),
      ),
    );
    expect(created, hasLength(2));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await ada.dispose();
    await bob.dispose();
  });

  testWidgets('builds again for a transition of its own nodes from '
      'State.dispose, and not for a child scope', (tester) async {
    final app = await Scope(module: _appModule('ada')).initialize();
    var builds = 0;
    final showWithdrawer = ValueNotifier<bool>(true);
    Scope? created;
    Scope? grandchild;

    await tester.pumpWidget(
      _host(
        app,
        Column(
          children: [
            ScopeBuilder(
              create: (parent) =>
                  created = parent.child(module: _greetingModule()),
              builder: (context, snapshot, child) {
                builds++;
                final nodes = snapshot.nodeStates;
                final phase = nodes.isEmpty ? 'none' : nodes.single.phase.name;
                return Text('greeting $phase');
              },
            ),
            ValueListenableBuilder<bool>(
              valueListenable: showWithdrawer,
              builder: (context, show, _) => show
                  ? _OnDispose(() {
                      // Both calls run while the framework has locked the
                      // tree. The disposal of a child notifies the listeners
                      // inside the call; the withdrawal notifies them later.
                      unawaited(grandchild!.dispose());
                      unawaited(app.node<String>(key: _name).dispose());
                    })
                  : const SizedBox(),
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('greeting active'), findsOneWidget);

    // A child scope that initializes and leaves builds nothing.
    var before = builds;
    final other = await created!.child(module: _greetingModule()).initialize();
    await other.dispose();
    grandchild = await created!.child().initialize();
    await tester.pump();
    await tester.pump();
    expect(builds, before);

    showWithdrawer.value = false;
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('greeting active'), findsNothing);
    expect(builds, greaterThan(before));

    await tester.pumpWidget(const SizedBox());
    await app.dispose();
  });

  testWidgets('calls no builder while its scope is disposed, also for a '
      'rebuild from above', (tester) async {
    final app = await Scope(module: _appModule('ada')).initialize();
    var builds = 0;
    Scope? created;

    Widget tree() => _host(
      app,
      ScopeBuilder(
        create: (parent) => created = parent.child(module: _greetingModule()),
        builder: (context, snapshot, child) {
          builds++;
          // A lookup of a disposed scope throws, so this read shows any build
          // after the disposal.
          return Text('greeting ${context.maybeDi<String>(key: _greeting)}');
        },
      ),
    );

    await tester.pumpWidget(tree());
    await tester.pump();
    await tester.pump();
    expect(find.text('greeting hello ada'), findsOneWidget);

    final before = builds;
    await created!.dispose();
    await tester.pump();
    await tester.pump();
    await tester.pumpWidget(tree());
    await tester.pump();
    expect(builds, before);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await app.dispose();
  });

  for (final whileInitializing in [false, true]) {
    testWidgets('a logout that replaces the scope above and disposes it in '
        'one turn${whileInitializing ? ' during initialize' : ''}', (
      tester,
    ) async {
      final ada = await Scope(module: _appModule('ada')).initialize();
      final bob = await Scope(module: _appModule('bob')).initialize();
      final current = ValueNotifier<Scope>(ada);
      final gate = Completer<void>();
      final created = <Scope>[];
      final seen = <ScopeSnapshot>[];

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ScopeProvider.listenable(
            scope: current,
            child: ScopeBuilder(
              create: (parent) {
                final child = parent.child(
                  module:
                      _greetingModule() +
                      Module(
                        components: [
                          Component<String>(
                            dependency: Dependency<String>(
                              create: () async {
                                // Only the scope of ada waits.
                                if (identical(parent, ada) &&
                                    whileInitializing) {
                                  await gate.future;
                                }
                                return 'opened';
                              },
                            ),
                            key: _slow,
                          ),
                        ],
                      ),
                );
                created.add(child);
                return child;
              },
              builder: (context, snapshot, child) {
                seen.add(snapshot);
                return snapshot.phase == ScopePhase.initialized
                    ? child!
                    : Text(_describe(snapshot));
              },
              child: _reader(_greeting),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(
        whileInitializing ? find.text('initializing') : find.text('hello ada'),
        findsOneWidget,
      );

      // The host rule: change the value first, then dispose in the same turn.
      current.value = bob;
      final disposal = ada.dispose();
      gate.complete();
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await disposal;
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(created, hasLength(2));
      expect(created.first.isDisposed, isTrue);
      expect(find.text('hello bob'), findsOneWidget);
      expect(seen.last.scope, same(created.last));
      expect(seen.last.error, isNull);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await bob.dispose();
    });
  }

  testWidgets('the value constructor publishes a caller-owned scope and '
      'follows its state', (tester) async {
    final app = await Scope(module: _appModule('ada')).initialize();
    final first = app.child(module: _greetingModule());
    final second = app.child(module: _greetingModule());

    Widget build(Scope scope) => Directionality(
      textDirection: TextDirection.ltr,
      child: ScopeBuilder.value(
        scope: scope,
        builder: (context, snapshot, child) =>
            Column(children: [Text(_describe(snapshot)), child!]),
        child: _reader(_greeting),
      ),
    );

    await tester.pumpWidget(build(first));
    await tester.pump();
    // The widget calls no initialize.
    expect(find.text('declared'), findsOneWidget);
    expect(find.text('absent'), findsOneWidget);

    await first.initialize();
    await tester.pump();
    await tester.pump();
    expect(find.text('ready'), findsOneWidget);
    expect(find.text('hello ada'), findsOneWidget);

    await tester.pumpWidget(build(second));
    expect(find.text('declared'), findsOneWidget);
    expect(find.text('absent'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(first.isDisposed, isFalse);
    expect(second.isDisposed, isFalse);
    expect(tester.takeException(), isNull);
    await app.dispose();
  });

  testWidgets('create needs a provider above', (tester) async {
    await tester.pumpWidget(
      ScopeBuilder(
        create: (parent) => fail('no parent'),
        builder: (context, snapshot, child) => const SizedBox(),
      ),
    );
    expect(tester.takeException(), isA<FlutterError>());
  });
}

/// Runs [onDispose] in `State.dispose`.
class _OnDispose extends StatefulWidget {
  const _OnDispose(this.onDispose);

  final void Function() onDispose;

  @override
  State<_OnDispose> createState() => _OnDisposeState();
}

class _OnDisposeState extends State<_OnDispose> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}
