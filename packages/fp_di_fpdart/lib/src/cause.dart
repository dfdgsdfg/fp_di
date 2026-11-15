import 'package:fpdart/fpdart.dart';

/// The type tag of [Cause] for the fpdart higher-kinded types.
abstract final class _CauseHKT {}

/// The reason why an operation failed, as a tree.
///
/// A cause is the `Cause` of ZIO. It keeps every failure of an operation and
/// the order in which the failures happened. The cases are [Empty], [Fail],
/// [Die], [Then], and [Both].
///
/// A [Fail] holds a typed error. A [Die] holds a defect: an error that the
/// type `E` does not describe, such as a dispose function that threw.
/// An [Interrupt] marks an operation that a caller canceled, such as an
/// activation that a disposal canceled. [Then] joins two causes that happened
/// one after the other. [Both] joins two causes that happened at the same
/// time.
///
/// [Empty] is the identity of `+` and `&`. A cause is a [Functor] over the
/// typed error, and a [Foldable] over the typed errors, from left to right.
/// Use [Cause.thenMonoid] and [Cause.bothMonoid] to combine
/// causes with the fpdart typeclasses.
sealed class Cause<E> extends HKT<_CauseHKT, E>
    with Functor<_CauseHKT, E>, Foldable<_CauseHKT, E> {
  /// Creates a cause.
  const Cause();

  /// A cause that happened after this cause.
  ///
  /// [Empty] is the identity. An empty operand gives the other operand.
  Cause<E> operator +(Cause<E> next) => switch ((this, next)) {
    (Empty<E>(), _) => next,
    (_, Empty<E>()) => this,
    _ => Then<E>(this, next),
  };

  /// A cause that happened at the same time as this cause.
  ///
  /// [Empty] is the identity. An empty operand gives the other operand.
  Cause<E> operator &(Cause<E> other) => switch ((this, other)) {
    (Empty<E>(), _) => other,
    (_, Empty<E>()) => this,
    _ => Both<E>(this, other),
  };

  /// A cause with the typed errors changed by [f].
  ///
  /// The structure and the defects stay as they are.
  @override
  Cause<B> map<B>(B Function(E error) f) => switch (this) {
    Empty<E>() => Empty<B>(),
    Fail<E>(:final error, :final stackTrace) => Fail<B>(f(error), stackTrace),
    Die<E>(:final defect, :final stackTrace) => Die<B>(defect, stackTrace),
    Interrupt<E>(:final stackTrace) => Interrupt<B>(stackTrace),
    Then<E>(:final first, :final second) => Then<B>(
      first.map(f),
      second.map(f),
    ),
    Both<E>(:final left, :final right) => Both<B>(left.map(f), right.map(f)),
  };

  /// Folds the tree into one value, from the leaves to the root.
  ///
  /// Each argument handles one case. The folded values of the two branches of
  /// a [Then] or a [Both] go to [then] or [both].
  Z fold<Z>({
    required Z Function() empty,
    required Z Function(E error, StackTrace stackTrace) fail,
    required Z Function(Object defect, StackTrace stackTrace) die,
    required Z Function(StackTrace stackTrace) interrupt,
    required Z Function(Z first, Z second) then,
    required Z Function(Z left, Z right) both,
  }) => switch (this) {
    Empty<E>() => empty(),
    Fail<E>(:final error, :final stackTrace) => fail(error, stackTrace),
    Die<E>(:final defect, :final stackTrace) => die(defect, stackTrace),
    Interrupt<E>(:final stackTrace) => interrupt(stackTrace),
    Then<E>(:final first, :final second) => then(
      first.fold(
        empty: empty,
        fail: fail,
        die: die,
        interrupt: interrupt,
        then: then,
        both: both,
      ),
      second.fold(
        empty: empty,
        fail: fail,
        die: die,
        interrupt: interrupt,
        then: then,
        both: both,
      ),
    ),
    Both<E>(:final left, :final right) => both(
      left.fold(
        empty: empty,
        fail: fail,
        die: die,
        interrupt: interrupt,
        then: then,
        both: both,
      ),
      right.fold(
        empty: empty,
        fail: fail,
        die: die,
        interrupt: interrupt,
        then: then,
        both: both,
      ),
    ),
  };

  /// The typed errors of the cause, from left to right.
  List<E> get failures => fold<List<E>>(
    empty: () => const [],
    fail: (error, _) => [error],
    die: (_, _) => const [],
    interrupt: (_) => const [],
    then: (first, second) => [...first, ...second],
    both: (left, right) => [...left, ...right],
  );

  /// The defects of the cause, from left to right.
  List<Object> get defects => fold<List<Object>>(
    empty: () => const [],
    fail: (_, _) => const [],
    die: (defect, _) => [defect],
    interrupt: (_) => const [],
    then: (first, second) => [...first, ...second],
    both: (left, right) => [...left, ...right],
  );

  /// The stack traces of the interruptions in the cause, from left to right.
  List<StackTrace> get interruptions => fold<List<StackTrace>>(
    empty: () => const [],
    fail: (_, _) => const [],
    die: (_, _) => const [],
    interrupt: (stackTrace) => [stackTrace],
    then: (first, second) => [...first, ...second],
    both: (left, right) => [...left, ...right],
  );

  /// Whether the cause holds an [Interrupt].
  bool get isInterrupted => interruptions.isNotEmpty;

  /// The cause without its typed errors and its interruptions: the [Die]
  /// values only, in the structure of the cause.
  ///
  /// The result is [Empty] when the cause holds no defect.
  Cause<E> get onlyDefects => fold<Cause<E>>(
    empty: Empty<E>.new,
    fail: (_, _) => Empty<E>(),
    die: Die<E>.new,
    interrupt: (_) => Empty<E>(),
    then: (first, second) => first + second,
    both: (left, right) => left & right,
  );

  /// The first typed error, or `None` when the cause has no typed error.
  Option<E> get failureOption {
    final all = failures;
    return all.isEmpty ? const None() : Some(all.first);
  }

  /// Whether the cause has no [Fail], no [Die], and no [Interrupt].
  bool get isEmpty =>
      failures.isEmpty && defects.isEmpty && interruptions.isEmpty;

  /// An indented tree of the cause, for a message.
  ///
  /// The text has no stack trace.
  String prettyPrint() => fold<List<String>>(
    empty: () => const ['Empty'],
    fail: (error, _) => ['Fail: $error'],
    die: (defect, _) => ['Die: $defect'],
    interrupt: (_) => const ['Interrupt'],
    then: (first, second) => ['Then', ..._indent(first), ..._indent(second)],
    both: (left, right) => ['Both', ..._indent(left), ..._indent(right)],
  ).join('\n');

  /// Folds the typed errors from the right.
  ///
  /// The fold visits the errors of [failures] from the last to the first.
  @override
  B foldRight<B>(B b, B Function(B acc, E a) f) => failures.reversed.fold(b, f);

  /// Folds the typed errors from the left.
  ///
  /// The fold visits the errors of [failures] from the first to the last.
  @override
  B foldLeft<B>(B b, B Function(B acc, E a) f) => failures.fold(b, f);

  /// A cause that happened after this cause and then [v].
  @override
  Cause<E> plus(covariant Cause<E> v) => this + v;

  /// A cause with a new typed failure [t] before this cause.
  @override
  Cause<E> prepend(E t) => Fail<E>(t, StackTrace.current) + this;

  /// A cause with a new typed failure [t] after this cause.
  @override
  Cause<E> append(E t) => this + Fail<E>(t, StackTrace.current);

  /// The equality typeclass of causes.
  ///
  /// The equality is structural, and it ignores the stack traces.
  static Eq<Cause<E>> eq<E>() =>
      Eq.instance<Cause<E>>((first, second) => first == second);

  /// The monoid of sequential composition: `+` with [Empty] as identity.
  static Monoid<Cause<E>> thenMonoid<E>() =>
      Monoid.instance<Cause<E>>(Empty<E>(), (x, y) => x + y);

  /// The monoid of parallel composition: `&` with [Empty] as identity.
  static Monoid<Cause<E>> bothMonoid<E>() =>
      Monoid.instance<Cause<E>>(Empty<E>(), (x, y) => x & y);

  @override
  String toString() => prettyPrint();
}

List<String> _indent(List<String> lines) => [
  for (final line in lines) '  $line',
];

/// A cause with no failure.
///
/// [Empty] is the identity of `+` and `&`.
final class Empty<E> extends Cause<E> {
  /// Creates an empty cause.
  const Empty();

  @override
  bool operator ==(Object other) => other is Empty<Object?>;

  @override
  int get hashCode => (Empty).hashCode;
}

/// A typed failure.
final class Fail<E> extends Cause<E> {
  /// Creates a failure of [error] that happened at [stackTrace].
  const Fail(this.error, this.stackTrace);

  /// The typed error.
  final E error;

  /// The stack trace of the place where the failure happened.
  final StackTrace stackTrace;

  @override
  bool operator ==(Object other) =>
      other is Fail<Object?> && other.error == error;

  @override
  int get hashCode => Object.hash(Fail, error);
}

/// A defect: an error that the type `E` does not describe.
///
/// A dispose function that threw, or a program that threw, is a defect.
final class Die<E> extends Cause<E> {
  /// Creates a defect of [defect] that happened at [stackTrace].
  const Die(this.defect, this.stackTrace);

  /// The error that was thrown, or the value that describes the defect.
  final Object defect;

  /// The stack trace of the place where the defect happened.
  final StackTrace stackTrace;

  @override
  bool operator ==(Object other) =>
      other is Die<Object?> && other.defect == defect;

  @override
  int get hashCode => Object.hash(Die, defect);
}

/// An operation that a caller canceled.
///
/// An activation that a disposal canceled is an interruption. It is never a
/// [Fail].
final class Interrupt<E> extends Cause<E> {
  /// Creates an interruption that happened at [stackTrace].
  const Interrupt(this.stackTrace);

  /// The stack trace of the place where the cancellation took effect.
  final StackTrace stackTrace;

  @override
  bool operator ==(Object other) => other is Interrupt<Object?>;

  @override
  int get hashCode => (Interrupt).hashCode;
}

/// Two causes that happened one after the other.
final class Then<E> extends Cause<E> {
  /// Creates a sequence of [first] and then [second].
  const Then(this.first, this.second);

  /// The cause that happened first.
  final Cause<E> first;

  /// The cause that happened next.
  final Cause<E> second;

  @override
  bool operator ==(Object other) =>
      other is Then<Object?> && other.first == first && other.second == second;

  @override
  int get hashCode => Object.hash(Then, first, second);
}

/// Two causes that happened at the same time.
final class Both<E> extends Cause<E> {
  /// Creates a pair of [left] and [right] that happened at the same time.
  const Both(this.left, this.right);

  /// The left cause.
  final Cause<E> left;

  /// The right cause.
  final Cause<E> right;

  @override
  bool operator ==(Object other) =>
      other is Both<Object?> && other.left == left && other.right == right;

  @override
  int get hashCode => Object.hash(Both, left, right);
}

/// The result of an operation: a [Cause] on failure, or a value.
///
/// The type is the `Exit` of ZIO, as an fpdart `Either`.
typedef Exit<E, A> = Either<Cause<E>, A>;
