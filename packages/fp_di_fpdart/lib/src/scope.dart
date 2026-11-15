import 'package:fpdart/fpdart.dart';

import 'cause.dart';
import 'component.dart';
import 'environment.dart';
import 'failure.dart';
import 'finalizers.dart';
import 'key.dart';
import 'plan.dart';

/// The phase of a [Scope].
///
/// A scope moves from `declared` through `running` to `active` or `failed`.
/// Then it moves through `disposing` to `disposed`.
enum ScopePhase {
  /// The scope exists, and `run` has not started.
  declared,

  /// `run` is creating the components.
  running,

  /// `run` succeeded. The scope publishes its values.
  active,

  /// `run` failed. The scope published nothing.
  failed,

  /// `dispose` is releasing the components.
  disposing,

  /// `dispose` finished. The scope publishes nothing.
  disposed,
}

/// The state of a scope. A scope holds one state in one `IORef`.
///
/// A transition is a pure function from one state to the next state.
sealed class _State {
  const _State();

  ScopePhase get phase;
}

final class _Declared extends _State {
  const _Declared();

  @override
  ScopePhase get phase => ScopePhase.declared;
}

/// The run is in progress. [settled] completes when the run has written its
/// result state. [disposal] is the disposal that waits for the run, if a
/// caller requested one.
final class _Running extends _State {
  const _Running(this.settled, this.disposal);

  final Future<Object?> settled;
  final Future<Exit<DiFailure, Unit>>? disposal;

  @override
  ScopePhase get phase => ScopePhase.running;
}

final class _Active extends _State {
  const _Active(this.environment, this.finalizers);

  final Environment environment;
  final Finalizers finalizers;

  @override
  ScopePhase get phase => ScopePhase.active;
}

final class _Failed extends _State {
  const _Failed();

  @override
  ScopePhase get phase => ScopePhase.failed;
}

final class _Disposing extends _State {
  const _Disposing(this.result);

  final Future<Exit<DiFailure, Unit>> result;

  @override
  ScopePhase get phase => ScopePhase.disposing;
}

final class _Disposed extends _State {
  const _Disposed(this.exit);

  final Exit<DiFailure, Unit> exit;

  @override
  ScopePhase get phase => ScopePhase.disposed;
}

/// A running instance of a list of components: the values of the components
/// and the functions that dispose them.
///
/// A scope runs once. The run creates every component in order of
/// dependency and publishes the values together. The dispose releases the
/// components, dependents first. A scope can have child scopes that read the
/// values of their ancestors.
///
/// No operation of a scope throws. A failure is a `Left` with a [Cause]. A
/// scope is the `Scope` of ZIO: it holds finalizers and runs them in the
/// reverse order of creation.
final class Scope {
  /// Creates a scope of [components]. The scope creates no value until [run].
  ///
  /// The scope keeps a copy of the list.
  Scope({required List<Component<Object?>> components})
    : this._(components, null);

  Scope._(List<Component<Object?>> components, this._parent)
    : _components = List.unmodifiable(components);

  final List<Component<Object?>> _components;
  final Scope? _parent;
  // The two `IORef` values are the one unavoidable construction of effects:
  // a field initializer must give the reference now, so the `IO` runs here.
  final IORef<_State> _state = IORef.create<_State>(const _Declared()).run();
  final IORef<List<Scope>> _children = IORef.create<List<Scope>>(
    const [],
  ).run();

  _State get _current => _state.read().run();

  void _become(_State next) => _state.write(next).run();

  /// The components that the scope declares.
  ///
  /// The list is unmodifiable.
  List<Component<Object?>> get components => _components;

  /// The parent scope, or `None` for a root scope.
  Option<Scope> get parent => Option.fromNullable(_parent);

  /// The current phase of the scope.
  ScopePhase get phase => _current.phase;

  /// Creates a child scope of [components].
  ///
  /// The child reads the values of this scope and of its ancestors. The
  /// child fails at its own [run] when this scope is not active. The parent
  /// disposes the child before the parent releases its own components.
  Scope child({List<Component<Object?>> components = const []}) {
    final created = Scope._(components, this);
    _children.modify((children) => [...children, created]).run();
    return created;
  }

  /// Creates the components of the scope and publishes their values.
  ///
  /// The run is valid once, in the phase `declared`. A second run is a
  /// `Left`. A child runs only when its parent is active.
  ///
  /// The run checks the components before it creates any value. The check
  /// accumulates: the `Cause` has every duplicate key and then every
  /// undeclared key, joined with [Both]. The check for a cycle runs only when
  /// the first two checks pass. Then the run activates the components in
  /// layers. The components of one layer activate at the same time, and all
  /// of them settle. A component reads each key from the nearest scope that
  /// publishes the key, starting with this scope.
  ///
  /// When components fail, the cause joins the failures of the layer with
  /// `&`. The run then disposes each committed component. It disposes the
  /// layers in reverse order, one after the other, and the components of one
  /// layer at the same time. The cause of the run is the failures followed
  /// by the dispose failures. The run publishes nothing. The phase is then
  /// `failed`. A validation failure and an inactive parent give the phase
  /// `failed`, too.
  Future<Exit<DiFailure, Scope>> run() {
    final current = _current;
    if (current is! _Declared) {
      return Future.value(_phaseFailure<Scope>('run', current.phase));
    }
    final execution = _execute().run();
    _become(_Running(execution, null));
    return execution;
  }

  Task<Exit<DiFailure, Scope>> _execute() => _prepare()
      .flatMap((prepared) => Plan.build(prepared.$2, prepared.$1))
      .match<(_State, Exit<DiFailure, Scope>)>(
        (cause) => (const _Failed(), Left(cause)),
        (built) => (_Active(built.$1, built.$2), Right(this)),
      )
      .flatMap(
        (outcome) => _state.write(outcome.$1).toTask().map((_) => outcome.$2),
      );

  /// The inherited environment and the layers of the components.
  TaskEither<Cause<DiFailure>, (Environment, Strata)> _prepare() =>
      _inherited().flatMap(
        (environment) => TaskEither.fromEither(
          Plan.of(_components, [
            for (var scope = _parent; scope != null; scope = scope._parent)
              scope._components.publishes,
          ]),
        ).map((layers) => (environment, layers)),
      );

  /// The environment that the parent makes visible.
  ///
  /// The task reads the state of the parent when it runs.
  TaskEither<Cause<DiFailure>, Environment> _inherited() => switch (_parent) {
    null => TaskEither.right(Environment.empty),
    final parent =>
      TaskEither<Cause<DiFailure>, _State>.fromTask(
        Task.of(unit).flatMap((_) => parent._state.read().toTask()),
      ).flatMap(
        (state) => switch (state) {
          _Active(:final environment) => TaskEither.right(environment),
          final other => TaskEither.left(
            Fail<DiFailure>(
              InactiveAncestorFailure(other.phase),
              StackTrace.current,
            ),
          ),
        },
      ),
  };

  bool get _ancestorsActive =>
      _parent == null ||
      (_parent._current is _Active && _parent._ancestorsActive);

  /// Disposes the child scopes and then the components of the scope.
  ///
  /// The disposal is valid in every phase and runs once. A later call
  /// returns the same result. When the scope is running, the disposal waits
  /// for the run to settle, and the phase stays `running` until then. The
  /// disposal releases the most recently created child first, one child after
  /// the other. Then it releases the components in reverse layer order, so
  /// a component is released before the components that it reads. The
  /// components of one layer release at the same time.
  ///
  /// Every dispose function runs, also after a failure. The result is
  /// `Right`, or a `Left` with a [Cause] of [Die] values. Each defect is a
  /// [DisposeFailure]. The cause includes the failures of the children. The
  /// phase is `disposed` in both cases.
  Future<Exit<DiFailure, Unit>> dispose() => switch (_current) {
    _Disposing(:final result) => result,
    _Disposed(:final exit) => Future.value(exit),
    _Running(disposal: final pending?) => pending,
    _Running(:final settled) => _disposeAfter(settled),
    final current => _beginTeardown(current),
  };

  Future<Exit<DiFailure, Unit>> _disposeAfter(Future<Object?> settled) {
    final disposal = settled.then((_) => dispose());
    _become(_Running(settled, disposal));
    return disposal;
  }

  Future<Exit<DiFailure, Unit>> _beginTeardown(_State current) {
    final result = _teardown(current).run();
    _become(_Disposing(result));
    return result;
  }

  Task<Exit<DiFailure, Unit>> _teardown(_State current) => _disposeChildren()
      .flatMap((children) => _releaseOwn(current).map((own) => children + own))
      .map<Exit<DiFailure, Unit>>(
        (cause) => cause.isEmpty ? const Right(unit) : Left(cause),
      )
      .flatMap(
        (exit) => _state
            .write(_Disposed(exit))
            .toTask()
            .flatMap((_) => _detach())
            .map((_) => exit),
      );

  Task<Cause<DiFailure>> _disposeChildren() => Task.of(unit)
      .flatMap((_) => _children.read().toTask())
      .flatMap(
        (children) => children.reversed.fold(
          Task<Cause<DiFailure>>.of(const Empty<DiFailure>()),
          (done, child) => done.flatMap(
            (before) => Task(() => child.dispose()).map(
              (exit) =>
                  before +
                  exit.match((cause) => cause, (_) => const Empty<DiFailure>()),
            ),
          ),
        ),
      );

  Task<Cause<DiFailure>> _releaseOwn(_State current) => switch (current) {
    _Active(:final finalizers) => finalizers.release(),
    _ => Task.of(const Empty<DiFailure>()),
  };

  /// Removes the scope from the children of its parent.
  Task<Unit> _detach() => switch (_parent) {
    null => Task.of(unit),
    final parent =>
      parent._children
          .modify(
            (children) => [
              for (final child in children)
                if (!identical(child, this)) child,
            ],
          )
          .toTask(),
  };

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
  /// owner. In this case the run fails with a [ScopePhaseFailure], and the
  /// task does not dispose the scope.
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
      (runCause.failures.any((failure) => failure is ScopePhaseFailure)
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

  /// The value that the scope or the nearest active ancestor publishes for
  /// [key].
  ///
  /// The key is `DiKey<T>()` when [key] is `null`. The result is a `Left`
  /// when the scope is not active, or when no active scope in the chain
  /// publishes the key.
  Either<DiFailure, T> get<T>({DiKey<T>? key}) {
    final current = _current;
    if (current is! _Active) {
      return Left(ScopePhaseFailure(operation: 'get', phase: current.phase));
    }
    final read = key ?? DiKey<T>();
    if (!_ancestorsActive || !current.environment.contains(read)) {
      return Left(UnavailableKeyFailure(read));
    }
    return Right(current.environment.read(read));
  }

  /// Like [get], with an `Option`: `None` for every failure.
  Option<T> getOption<T>({DiKey<T>? key}) => get<T>(key: key).toOption();

  @override
  String toString() => 'Scope(${phase.name})';
}

Exit<DiFailure, T> _phaseFailure<T>(String operation, ScopePhase phase) => Left(
  Fail(
    ScopePhaseFailure(operation: operation, phase: phase),
    StackTrace.current,
  ),
);
