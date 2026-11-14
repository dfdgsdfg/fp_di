import 'package:flutter/widgets.dart';
import 'package:fp_di/fp_di.dart';

import 'scope_provider.dart';

/// Reads of the scope that the closest [ScopeProvider] publishes.
///
/// A read without `watch` registers no dependency, so the widget does not
/// rebuild. A read with `watch` rebuilds the widget when another node answers
/// the key, when the node commits again, or when the value appears or
/// leaves. A change inside the value does not rebuild the widget.
///
/// Each read throws a `FlutterError` when no provider is above. Use
/// [ScopeProvider.maybeOf] for a widget that also works without a provider.
extension DiBuildContext on BuildContext {
  /// Looks up [T] without subscribing this widget to lifecycle changes.
  T di<T>({DiKey<T>? key}) => ScopeProvider.of(this).get<T>(key: key);

  /// Looks up [T] and rebuilds when the member that publishes it, or its
  /// availability, changes.
  ///
  /// Mutating the object stored in [T] does not notify this widget.
  T watchDi<T>({DiKey<T>? key}) {
    final actual = key ?? DiKey<T>();
    return ScopeProvider.of(this, key: actual).get<T>(key: actual);
  }

  /// Looks up [T] without subscribing this widget, or returns null when the
  /// key has no value.
  ///
  /// The key has no value when no node publishes it or when its node is not
  /// active. See `Scope.maybeGet`.
  T? maybeDi<T>({DiKey<T>? key}) =>
      ScopeProvider.of(this).maybeGet<T>(key: key);

  /// Looks up [T], or returns null when the key has no value, and rebuilds
  /// when the value appears, leaves, or comes from another node.
  ///
  /// Use it for a key whose node can be withdrawn, and in a route that can
  /// exit after the host replaced the scope.
  T? watchMaybeDi<T>({DiKey<T>? key}) {
    final actual = key ?? DiKey<T>();
    return ScopeProvider.of(this, key: actual).maybeGet<T>(key: actual);
  }

  /// The node that publishes [T], without subscribing this widget.
  ///
  /// It is null when no node publishes the key. See `Scope.findNode`.
  ComponentNode<T>? maybeDiNode<T>({DiKey<T>? key}) =>
      ScopeProvider.of(this).findNode<T>(key: key);

  /// The node that publishes [T]. Rebuilds this widget when the state of
  /// that node changes.
  ///
  /// Use it to show what happens to a value, and not only the value:
  ///
  /// ```dart
  /// final node = context.watchMaybeDiNode<Profile>();
  /// return switch (node?.state.phase) {
  ///   NodePhase.active => ProfileView(node!.value),
  ///   NodePhase.activationFailed =>
  ///     ErrorView(node!.activationException!.cause),
  ///   _ => const Loading(),
  /// };
  /// ```
  ///
  /// The widget rebuilds when a transition of the runtime leaves the node
  /// with another `NodeState`: another phase, another failure, other missing
  /// keys, or another commit. It also rebuilds when another node publishes
  /// the key. The node reads `activating` and `deactivating` while an
  /// activation or a release runs. Treat every phase except `active` and
  /// `activationFailed` as pending.
  ///
  /// The failure of `Scope.initialize` goes to the caller of `initialize`
  /// and rolls the members of that scope back, so no node holds it.
  ComponentNode<T>? watchMaybeDiNode<T>({DiKey<T>? key}) {
    final actual = key ?? DiKey<T>();
    return ScopeProvider.of(this, nodeKey: actual).findNode<T>(key: actual);
  }
}
