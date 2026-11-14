// Loading, error, and data from the state of a node.
//
// `context.watchMaybeDiNode<T>()` gives the node that publishes `T` and
// rebuilds the widget when the state of that node changes. The widget decides
// what to show for each state, so the provider needs no loading widget and no
// error widget.
//
// Here the page scope is a child of the backend scope and initializes first.
// Its members wait for `Session`. The backend initializes after `runApp`:
// `Profile` activates, and `Recommendations` fails. That failure goes to no
// caller, because no call asked for the activation. The node keeps it.
//
// The failure of `Scope.initialize` is different: it goes to the caller of
// `initialize`. See `page_scope.dart`.
import 'package:flutter/material.dart';
import 'package:fp_di/fp_di.dart';
import 'package:fp_di_flutter/fp_di_flutter.dart';

final class Session {
  const Session(this.userId);
  final String userId;

  /// Signs in. The request takes a moment.
  static Future<Session> signIn() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return const Session('ada');
  }
}

final class Profile {
  const Profile(this.title);
  final String title;
}

final class Recommendations {
  const Recommendations(this.titles);
  final List<String> titles;

  /// The service is down in this example.
  static Recommendations load(Session session) =>
      throw StateError('the service is down');
}

/// The slow part of the application.
final backendModule = Module(
  components: [
    Component<Session>(dependency: Dependency<Session>(create: Session.signIn)),
  ],
  debugLabel: 'backend',
);

/// What the first page shows. Each member waits for `Session`.
final pageModule = Module(
  components: [
    Component<Profile>(
      dependency: Dependency1<Session, Profile>(
        create: (session) => Profile('profile of ${session.userId}'),
      ),
    ),
    Component<Recommendations>(
      dependency: Dependency1<Session, Recommendations>(
        create: Recommendations.load,
      ),
    ),
  ],
  debugLabel: 'page',
);

Future<void> main() async {
  final backend = Scope(module: backendModule);
  // The page scope initializes at once, and its members wait.
  final page = await backend.child(module: pageModule).initialize();
  runApp(NodeStateApp(scope: page));
  // The members of the page activate when the session exists.
  await backend.initialize();
}

final class NodeStateApp extends StatelessWidget {
  const NodeStateApp({required this.scope, super.key});

  final Scope scope;

  @override
  Widget build(BuildContext context) {
    return ScopeProvider.fixed(
      scope: scope,
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                NodeView<Profile>(builder: (profile) => Text(profile.title)),
                NodeView<Recommendations>(
                  builder: (recommendations) =>
                      Text(recommendations.titles.join(', ')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows the value of `T`, or what happens to it.
final class NodeView<T> extends StatelessWidget {
  const NodeView({required this.builder, super.key});

  final Widget Function(T value) builder;

  @override
  Widget build(BuildContext context) {
    final node = context.watchMaybeDiNode<T>();
    return switch (node?.state.phase) {
      NodePhase.active => builder(node!.value),
      NodePhase.activationFailed => Text(
        '$T failed: ${node!.activationException!.cause}',
      ),
      // No node, or a node that waits or activates.
      _ => Text('$T: loading'),
    };
  }
}
