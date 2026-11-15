/// Flutter integration for fp_di.
///
/// [ScopeProvider] publishes a caller-owned `Scope` to the widget tree. It
/// does not create, initialize, or dispose a scope. [ScopeBuilder] creates a
/// child scope, initializes it, publishes it, builds from its state, and
/// disposes it when it is unmounted; [ScopeBuilder.value] builds from the
/// state of a caller-owned scope. [DiBuildContext] reads the published scope
/// from a `BuildContext`: `di` and `maybeDi` read once, and `watchDi`,
/// `watchMaybeDi`, and `watchMaybeDiNode` rebuild the widget when the value
/// or the node of a key changes.
///
/// A host that replaces a scope changes the value of the listenable of
/// [ScopeProvider.listenable] first and disposes the old scope after that.
/// A scope that one page or one route owns belongs to a [ScopeBuilder] of
/// that page or route.
library;

export 'src/di_extensions.dart';
export 'src/scope_builder.dart';
export 'src/scope_provider.dart';
