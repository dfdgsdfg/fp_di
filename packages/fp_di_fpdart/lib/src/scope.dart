import 'dart:async';

import 'package:fpdart/fpdart.dart';

import 'cause.dart';
import 'component.dart';
import 'core/core.dart';
import 'failure.dart';
import 'key.dart';
import 'node.dart';
import 'runtime/runtime.dart';

export 'core/ids.dart' show NodeId;
export 'core/phases.dart' show NodePhase, ScopePhase;
export 'core/snapshots.dart' show NodeState, ScopeState;

/// A running instance of a list of components: the values of the components
/// and the functions that dispose them.
///
/// A scope is reactive. [run] creates one node for each component, and
/// activates the nodes in order of dependency. A node whose required key has
/// no publisher waits. It activates when a publisher appears, in this scope,
/// in an ancestor, or in a scope that runs later. When a nearer publisher of a
/// key appears, or when the publisher of a key leaves, each node that read the
/// key releases its value and creates it again.
///
/// A scope has a phase that moves from `declared` through `initializing` to
/// `initialized`, and, after a disposal, through `disposeRequested` and
/// `disposing` to `disposed`. A [child] scope reads the values of its
/// ancestors, and it can run before its parent.
///
/// No operation of a scope throws. A failure is a `Left` with a [Cause], or a
/// value of [DiFailure] in an `Either`. A failure that no caller receives, such
/// as the failed automatic activation of a node, goes to [errors]. A scope is
/// the `Scope` of ZIO: it holds finalizers and runs them in the reverse order
/// of creation.
final class Scope {
  Scope._(this._runtime, this._id);

  /// Creates a root scope of [components]. The scope creates no value until
  /// [run].
  ///
  /// The scope keeps a copy of the list. The scope owns a new runtime, which
  /// its children share.
  factory Scope({required List<Component<Object?>> components}) {
    final runtime = Runtime.create();
    late final ScopeId id;
    runtime.write((state) {
      final (next, created) = declareScope(state, const None(), components);
      id = created;
      return next;
    });
    return Scope._(runtime, id);
  }

  final Runtime _runtime;
  final ScopeId _id;

  ScopeRecord get _record => scopeRecord(_runtime.state, _id);

  /// The components that the scope declares.
  ///
  /// The list is unmodifiable.
  List<Component<Object?>> get components => _record.components;

  /// The parent scope, or `None` for a root scope.
  Option<Scope> get parent =>
      _record.parent.map((parent) => Scope._(_runtime, parent));

  /// The current phase of the scope.
  ScopePhase get phase => scopePhase(_runtime.state, _id);

  /// Whether a run of the scope succeeded. The value stays true after a
  /// disposal was requested.
  bool get isInitialized => _record.initialized;

  /// Whether the scope or an ancestor accepted a disposal. The value never
  /// returns to false.
  bool get isDisposed => disposalRequested(_runtime.state, _id);

  /// The number of observable changes of the runtime of this scope.
  ///
  /// Two reads that give the same revision give the same state. A read of the
  /// scope never changes the revision.
  int get revision => _runtime.state.revision;

  /// The state of the scope, with the states of its nodes and of its
  /// children.
  ScopeState get state => scopeState(_runtime.state, _id);

  /// The failures that no caller receives, for the whole tree of scopes.
  ///
  /// The stream is a broadcast stream. A failure without a subscriber is lost.
  /// The root closes the stream when its disposal ends. Each event is a cause:
  ///
  /// - The failure of an automatic activation of a node, and the dispose
  ///   failures that the rollback of that activation held.
  /// - The dispose failures of a release that a reconciliation started.
  /// - An [UnsettledFailure] when optional reads feed back and do not settle.
  /// - A [ListenerFailure] when a listener threw.
  ///
  /// A canceled activation is not reported. The failures of `run`, `dispose`,
  /// and the `dispose` of a node return to their callers.
  Stream<Cause<DiFailure>> get errors => _runtime.errors;

  /// Creates a child scope of [components].
  ///
  /// The child reads the values of this scope and of its ancestors. The child
  /// can run before this scope runs: its nodes then wait for the publishers.
  /// The parent disposes the child before it releases its own components.
  /// The result is a `Left` when this scope is disposing or disposed. A scope
  /// that accepted a disposal gives a child that has the phase
  /// `disposeRequested`.
  Either<DiFailure, Scope> child({
    List<Component<Object?>> components = const [],
  }) {
    if (_gone) return Left(const DisposedScopeFailure('child'));
    late final ScopeId id;
    _runtime.apply((state) {
      final (next, created) = declareScope(state, Some(_id), components);
      id = created;
      return next;
    });
    return Right(Scope._(_runtime, id));
  }

  bool get _gone {
    final current = phase;
    return current == ScopePhase.disposing || current == ScopePhase.disposed;
  }

  /// Creates a node for each component, and activates the nodes.
  ///
  /// The run is a lifecycle operation. Lifecycle operations of one root run
  /// one after the other, in the order of the calls. The run is valid in the
  /// phase `declared`. In the phase `initialized` it is a [ScopePhaseFailure],
  /// and after a disposal request it is a [DisposedScopeFailure].
  ///
  /// The run checks the components before it creates any node, and a failed
  /// check changes nothing. The check accumulates: the `Cause` has every
  /// duplicate key and then every undeclared key, joined with [Both]. A key
  /// counts as declared when another component of the scope or any ancestor
  /// declares it, whether or not that ancestor runs.
  ///
  /// A node activates when every required key resolves, in order of the reads.
  /// Independent nodes activate at the same time, and each node commits on its
  /// own. A node whose required key has no publisher waits, and the run still
  /// succeeds. When the run succeeds, the scope is `initialized`.
  ///
  /// When the activation of a node fails, no further node starts, and the
  /// nodes in flight settle. Then the run releases every node of the scope,
  /// in reverse order of declaration and one after the other. The scope is
  /// `declared` again, and the run can start again. The cause is the failure
  /// of the node with the lowest id, followed by the dispose failures. When
  /// the scope accepted a disposal during the run, the cause holds an
  /// [Interrupt], and the scope stays `disposeRequested`.
  Future<Exit<DiFailure, Scope>> run() {
    if (isDisposed) {
      return Future.value(
        Left(Fail<DiFailure>(DisposedScopeFailure('run'), StackTrace.current)),
      );
    }
    return _runtime
        .mutate<Unit>('run', () => _runtime.initialize(_id).run())
        .then((exit) => exit.map((_) => this));
  }

  /// Disposes the scope, its descendants, and everything they own.
  ///
  /// The call is valid in every phase. It accepts the disposal at once: the
  /// phase is `disposeRequested`, and a running activation in the subtree is
  /// canceled before the call returns. The disposal itself is a lifecycle
  /// operation that waits for the earlier ones. Then the phase is
  /// `disposing`, the nodes release, and the phase is `disposed`.
  ///
  /// A node releases after every node that read one of its values finished.
  /// Nodes that do not read each other release at the same time. Every
  /// dispose function runs, also after a failure. The result is `Right`, or a
  /// `Left` with a [Cause] of [Die] values, one for each dispose function that
  /// failed, in descending order of node id. A disposal does not create nodes
  /// again.
  ///
  /// A second call, or a call of a descendant, while a disposal runs, shares
  /// the result of that disposal. A call after the disposal ended gives
  /// `Right`. A call inside a lifecycle operation gives a
  /// [ReentrantMutationFailure].
  ///
  /// The argument [ignoreHolds] is reserved for the holds of a later version.
  Future<Exit<DiFailure, Unit>> dispose({bool ignoreHolds = false}) =>
      _runtime.disposeScopeCall(_id, ignoreHolds: ignoreHolds);

  /// Runs [program] against the scope and always disposes the scope.
  ///
  /// The task is lazy. When it runs, it runs the scope. When the run fails,
  /// the task disposes the scope. Otherwise the task runs the program and
  /// then disposes the scope. The task never throws. The scope is the
  /// `ZIO.scoped` of ZIO.
  ///
  /// The `Cause` of a `Left` holds each failure as an `Either`. A `Left` is a
  /// failure of the scope, and a `Right` is a failure of the program.
  ///
  /// - A failed run gives the cause of the run followed by the cause of the
  ///   disposal.
  /// - A `Left` of the program gives a [Fail] of the `Left` value, followed by
  ///   the cause of the disposal.
  /// - A throw of the program gives a [Die] of the error, followed by the
  ///   cause of the disposal.
  /// - A failed disposal after a success gives the cause of the disposal.
  ///
  /// A scope that is not in the phase `declared` is under the control of its
  /// owner. In this case the run fails with a [ScopePhaseFailure] or a
  /// [DisposedScopeFailure], and the task does not dispose the scope.
  TaskEither<Cause<Either<DiFailure, E>>, A> use<E, A>(
    ReaderTaskEither<Scope, E, A> program,
  ) => TaskEither.fromTaskFlatten(
    Task<Exit<DiFailure, Scope>>(run).flatMap(
      (started) => started.match(
        (runCause) => _afterFailedRun<E, A>(runCause),
        (_) => _attemptProgram(program).flatMap(
          (used) =>
              _disposeCause().map((disposal) => _combine<E, A>(used, disposal)),
        ),
      ),
    ),
  );

  /// The disposal after a failed run. A phase failure means that the owner
  /// controls the scope, so the scope stays as it is.
  Task<Exit<Either<DiFailure, E>, A>> _afterFailedRun<E, A>(
    Cause<DiFailure> runCause,
  ) =>
      (runCause.failures.any(
                (failure) =>
                    failure is ScopePhaseFailure ||
                    failure is DisposedScopeFailure,
              )
              ? Task.of(const Empty<DiFailure>() as Cause<DiFailure>)
              : _disposeCause())
          .map(
            (disposal) => Left<Cause<Either<DiFailure, E>>, A>(
              _lift<E>(runCause) + _lift<E>(disposal),
            ),
          );

  /// The result of the program and the cause of the disposal in one exit.
  static Exit<Either<DiFailure, E>, A> _combine<E, A>(
    Exit<Either<DiFailure, E>, A> used,
    Cause<DiFailure> disposal,
  ) => used.match(
    (cause) => Left<Cause<Either<DiFailure, E>>, A>(cause + _lift<E>(disposal)),
    (value) => disposal.isEmpty
        ? Right<Cause<Either<DiFailure, E>>, A>(value)
        : Left<Cause<Either<DiFailure, E>>, A>(_lift<E>(disposal)),
  );

  Task<Cause<DiFailure>> _disposeCause() => Task(dispose).map(
    (exit) => exit.match((cause) => cause, (_) => const Empty<DiFailure>()),
  );

  static Cause<Either<DiFailure, E>> _lift<E>(Cause<DiFailure> cause) =>
      cause.map<Either<DiFailure, E>>(Left.new);

  /// The program as a task that never throws.
  ///
  /// A throw is a `Die`, and a `Left` is a `Fail` of a `Right`.
  Task<Exit<Either<DiFailure, E>, A>> _attemptProgram<E, A>(
    ReaderTaskEither<Scope, E, A> program,
  ) =>
      TaskEither<Cause<Either<DiFailure, E>>, Either<E, A>>.tryCatch(
            () => program.run(this),
            (error, stackTrace) => Die<Either<DiFailure, E>>(error, stackTrace),
          )
          .chainEither(
            (result) => result.mapLeft<Cause<Either<DiFailure, E>>>(
              (error) => Fail<Either<DiFailure, E>>(
                Right<DiFailure, E>(error),
                StackTrace.current,
              ),
            ),
          )
          .match(
            Left<Cause<Either<DiFailure, E>>, A>.new,
            Right<Cause<Either<DiFailure, E>>, A>.new,
          );

  /// The value that the scope or the nearest ancestor publishes for [key].
  ///
  /// The key is `DiKey<T>()` when [key] is `null`. A node that publishes the
  /// key is available while it is active and does not release. When it
  /// releases, the lookup goes on in the ancestors. The result is a `Left`
  /// when the scope is disposing or disposed, and when no publisher resolves.
  Either<DiFailure, T> get<T>({DiKey<T>? key}) {
    final read = key ?? DiKey<T>();
    if (_gone) return Left(const DisposedScopeFailure('get'));
    final s = _runtime.state;
    return resolve(s, _id, read).match(
      () => Left(UnavailableKeyFailure(read)),
      (publisher) =>
          Right(nodeRecord(s, publisher.node).value.toNullable() as T),
    );
  }

  /// Like [get], with an `Option`: `None` for every failure.
  Option<T> getOption<T>({DiKey<T>? key}) => get<T>(key: key).toOption();

  /// The value of [key], as soon as a publisher resolves.
  ///
  /// The task is lazy: each run reads the scope again. The task gives the
  /// value now when a publisher resolves. It fails with a
  /// [DisposedScopeFailure] when the scope accepted a disposal, and with an
  /// [UnavailableKeyFailure] when no scope from this scope to the root can
  /// still publish the key. Otherwise it waits for the next change. A failed
  /// run of a scope does not end the wait.
  TaskEither<DiFailure, T> getWhenAvailable<T>({DiKey<T>? key}) {
    final read = key ?? DiKey<T>();
    Option<Either<DiFailure, T>> check() {
      final s = _runtime.state;
      if (!_gone) {
        final found = resolve(s, _id, read);
        if (found.isSome()) {
          return Some(
            Right(
              nodeRecord(s, found.toNullable()!.node).value.toNullable() as T,
            ),
          );
        }
      }
      if (disposalRequested(s, _id)) {
        return Some(Left(const DisposedScopeFailure('getWhenAvailable')));
      }
      if (!canPublish(s, _id, read)) {
        return Some(Left(UnavailableKeyFailure(read)));
      }
      return const None();
    }

    return TaskEither(() {
      final now = check();
      if (now.isSome()) return Future.value(now.toNullable()!);
      final completer = Completer<Either<DiFailure, T>>();
      late final void Function() listener;
      listener = () {
        if (completer.isCompleted) return;
        final next = check();
        next.match(() {}, (result) {
          _runtime.removeListener(_id, listener);
          completer.complete(result);
        });
      };
      _runtime.addListener(_id, listener);
      return completer.future;
    });
  }

  /// The nodes of the scope, in the order of the components.
  ///
  /// The list is empty until a run succeeds, and stays after a disposal. The
  /// call never fails.
  List<ComponentNode<Object?>> get nodes {
    final record = _record;
    if (!record.initialized) return const [];
    return List.unmodifiable([
      for (final id in record.nodes) componentNodeOf<Object?>(_runtime, id),
    ]);
  }

  /// The node of the component of this scope that publishes [key].
  ///
  /// The result is a `Left` when the scope is disposing or disposed, when the
  /// scope is not initialized, and when no component of the scope publishes
  /// the key. An effect has no key: find it in [nodes].
  Either<DiFailure, ComponentNode<T>> node<T>({DiKey<T>? key}) {
    final read = key ?? DiKey<T>();
    if (_gone) return Left(const DisposedScopeFailure('node'));
    final record = _record;
    if (!record.initialized) {
      return Left(ScopePhaseFailure(operation: 'node', phase: phase));
    }
    for (var i = 0; i < record.components.length; i++) {
      final component = record.components[i];
      if (!component.isEffect && component.key == read) {
        return Right(componentNodeOf<T>(_runtime, record.nodes[i]));
      }
    }
    return Left(UnavailableKeyFailure(read));
  }

  /// The node that answers a read of [key] from this scope.
  ///
  /// The node is the publisher that [get] reads. When no publisher resolves,
  /// the node is the node of the nearest scope, from this scope to the root,
  /// that declares the key and has a node for it. That node can wait or
  /// release. The result is `None` when the scope is disposing or disposed, and
  /// when no scope has a node for the key.
  Option<ComponentNode<T>> findNode<T>({DiKey<T>? key}) {
    final read = key ?? DiKey<T>();
    if (_gone) return const None();
    final s = _runtime.state;
    final found = resolve(s, _id, read);
    if (found.isSome()) {
      return Some(componentNodeOf<T>(_runtime, found.toNullable()!.node));
    }
    ScopeId? at = _id;
    while (at != null) {
      final node = nodeForKey(s, at, read);
      if (node.isSome()) {
        return Some(componentNodeOf<T>(_runtime, node.toNullable()!));
      }
      at = scopeRecord(s, at).parent.toNullable();
    }
    return const None();
  }

  /// Adds [listener], which the runtime calls after each change of the state
  /// of the tree of scopes.
  ///
  /// The call of a listener is synchronous, inside the change. A change that
  /// a listener starts replaces the state at once, and its round of calls
  /// waits for the round in progress. A listener that throws leaves, and the
  /// failure goes to [errors] after the round. A listener is added once for a
  /// scope. The listeners of a scope hear the last change, the disposal of
  /// the scope, and then leave.
  ///
  /// The result is a `Left` when the scope is disposing or disposed. A scope
  /// that waits for its disposal accepts a listener.
  Either<DiFailure, Unit> addListener(void Function() listener) {
    if (_gone) return Left(const DisposedScopeFailure('addListener'));
    _runtime.addListener(_id, listener);
    return const Right(unit);
  }

  /// Removes [listener] from this scope. The call is valid in every phase.
  void removeListener(void Function() listener) =>
      _runtime.removeListener(_id, listener);

  @override
  bool operator ==(Object other) =>
      other is Scope && identical(other._runtime, _runtime) && other._id == _id;

  @override
  int get hashCode => Object.hash(identityHashCode(_runtime), _id.value);

  @override
  String toString() => 'Scope(${phase.name})';
}
