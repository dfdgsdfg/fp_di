// A scope that lives as long as one page.
//
// The package has no widget that creates a scope. The `State` of the page
// owns the scope here: it creates a child of the ambient scope, calls
// `initialize`, and calls `dispose` when the page goes away. The future of
// `initialize` is the loading state and the error state of the page, so an
// ordinary `FutureBuilder` shows them.
//
// The child scope reads `Account` from the app scope. Only the widgets below
// the page read `DraftStore`.
//
// A member can become inactive after `initialize`, when a key of the parent
// is withdrawn. This example does not handle that case; `node_state.dart`
// shows how a widget follows the state of a node.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fp_di/fp_di.dart';
import 'package:fp_di_flutter/fp_di_flutter.dart';

final class Account {
  const Account(this.userId);
  final String userId;
}

/// A store that opens and closes asynchronously.
final class DraftStore {
  DraftStore._(this.owner);

  final String owner;
  bool isOpen = true;

  static Future<DraftStore> open(Account account) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return DraftStore._(account.userId);
  }

  Future<void> close() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    isOpen = false;
  }
}

final appModule = Module(
  components: [Component<Account>.value(value: const Account('ada'))],
  debugLabel: 'app',
);

/// What the editor page owns.
final editorModule = Module(
  components: [
    Component<DraftStore>(
      dependency: Dependency1<Account, DraftStore>(
        create: DraftStore.open,
        dispose: (store) => store.close(),
      ),
    ),
  ],
  debugLabel: 'editor',
);

Future<void> main() async {
  final app = await Scope(module: appModule).initialize();
  runApp(PageScopeApp(scope: app));
}

final class PageScopeApp extends StatelessWidget {
  const PageScopeApp({required this.scope, super.key});

  final Scope scope;

  @override
  Widget build(BuildContext context) {
    return ScopeProvider.fixed(
      scope: scope,
      child: const MaterialApp(home: DocumentsPage()),
    );
  }
}

final class DocumentsPage extends StatefulWidget {
  const DocumentsPage({super.key});

  @override
  State<DocumentsPage> createState() => _DocumentsPageState();
}

final class _DocumentsPageState extends State<DocumentsPage> {
  bool _editing = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              onPressed: () => setState(() => _editing = !_editing),
              child: Text(_editing ? 'Close editor' : 'Open editor'),
            ),
            if (_editing) const EditorPage(),
          ],
        ),
      ),
    );
  }
}

/// Owns the scope of the editor.
final class EditorPage extends StatefulWidget {
  const EditorPage({super.key});

  @override
  State<EditorPage> createState() => _EditorPageState();
}

final class _EditorPageState extends State<EditorPage> {
  Scope? _parent;
  Scope? _scope;
  Future<Scope>? _ready;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A listening lookup. When the host replaces the ambient scope, this
    // method runs again, and the page scope starts again below the new one.
    final parent = ScopeProvider.of(context, listenToScope: true);
    if (identical(parent, _parent)) return;
    _parent = parent;
    _close();
    final scope = parent.child(module: editorModule);
    _scope = scope;
    // `ignore` keeps a failure that nothing listens to from becoming an
    // uncaught error. The FutureBuilder still receives the failure.
    _ready = scope.initialize()..ignore();
  }

  /// Disposes the page scope. A disposal during `initialize` cancels it.
  void _close() {
    final scope = _scope;
    if (scope == null) return;
    _scope = null;
    unawaited(
      scope.dispose().catchError((Object error, StackTrace stackTrace) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            context: ErrorDescription('while disposing the editor scope'),
          ),
        );
      }),
    );
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Scope>(
      future: _ready,
      builder: (context, snapshot) {
        // A FutureBuilder keeps the data of its last future while a new one
        // runs, so check the connection state first.
        if (snapshot.connectionState != ConnectionState.done) {
          return const Text('opening the drafts');
        }
        if (snapshot.hasError) {
          return Text('the drafts did not open: ${snapshot.error}');
        }
        return ScopeProvider.fixed(
          scope: snapshot.requireData,
          child: const Editor(),
        );
      },
    );
  }
}

/// Renders only below an initialized page scope.
final class Editor extends StatelessWidget {
  const Editor({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.di<DraftStore>();
    return Text('drafts of ${store.owner}');
  }
}
