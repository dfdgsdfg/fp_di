// A scope that lives as long as one page.
//
// `ScopeBuilder` creates a child of the ambient scope, calls `initialize`,
// publishes the scope, and disposes the scope when the page goes away. Its
// snapshot is the loading state and the error state of the page. Flutter
// calls `State.dispose` of the `ScopeBuilder` after the exit transition of a
// route, so an exiting route still reads its scope.
//
// The child scope reads `Account` from the app scope. Only the widgets below
// the page read `DraftStore`.
//
// A member can become inactive after `initialize`, when a key of the parent
// is withdrawn. This example does not handle that case; `node_state.dart`
// shows how a widget follows the state of a node.
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
final class EditorPage extends StatelessWidget {
  const EditorPage({super.key});

  @override
  Widget build(BuildContext context) {
    // `create` runs again when the host replaces the ambient scope, and the
    // page scope starts again below the new one.
    return ScopeBuilder(
      create: (parent) => parent.child(module: editorModule),
      builder: (context, snapshot, child) => switch (snapshot) {
        ScopeSnapshot(:final error?) => Text('the drafts did not open: $error'),
        _ when snapshot.scope.isInitialized => child!,
        _ => const Text('opening the drafts'),
      },
      child: const Editor(),
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
