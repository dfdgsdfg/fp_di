// Internal types. The library file does not export this file.
import 'dart:async';

import 'package:fpdart/fpdart.dart';

import 'key.dart';

/// The effect of a step: it gives a `Right` value, or a `Left` that fails
/// the activation. A throw fails the activation, too.
typedef StepEffect<A, B> = Future<Either<Object?, B>> Function(A input);

/// The release of a value that a step owns.
typedef StepRelease<B> = FutureOr<void> Function(B value);

/// An interpreter of a dependency tree, as an algebra.
///
/// The type `G` is the tag of the result type. A method gives an
/// `HKT<G, A>`, so the result can depend on the type `A` of the value. A
/// method receives the results of the sub-trees, so the algebra does not walk
/// the tree. A node dispatches to one method, and the method holds all the
/// interpretation logic.
abstract interface class DependencyAlgebra<G> {
  /// A value that exists already.
  HKT<G, A> pure<A>(A value);

  /// A required read of [key].
  HKT<G, A> require<A>(DiKey<A> key);

  /// An optional read of [key].
  HKT<G, Option<A>> optional<A>(DiKey<A> key);

  /// The application of the function value [ff] to the value [fa].
  ///
  /// The application runs [fa] first and then [ff].
  HKT<G, B> ap<A, B>(HKT<G, A> fa, HKT<G, B Function(A a)> ff);

  /// One [effect] after the value of [source], with an optional [release].
  HKT<G, B> step<A, B>(
    HKT<G, A> source,
    StepEffect<A, B> effect,
    StepRelease<B>? release,
  );
}

/// The syntax tree of a dependency: a free applicative.
///
/// A node describes a value and does nothing. A node holds no interpretation
/// logic. An interpreter is a [DependencyAlgebra], and [fold] only dispatches.
sealed class DependencyNode<A> {
  /// Creates a node.
  const DependencyNode();

  /// Folds the tree with [algebra], from the leaves to the root.
  HKT<G, A> fold<G>(DependencyAlgebra<G> algebra);
}

/// A value that exists already.
final class PureNode<A> extends DependencyNode<A> {
  /// Creates a node of [value].
  const PureNode(this.value);

  /// The value.
  final A value;

  @override
  HKT<G, A> fold<G>(DependencyAlgebra<G> algebra) => algebra.pure(value);
}

/// A required read of [key].
final class RequireNode<A> extends DependencyNode<A> {
  /// Creates a required read of [key].
  const RequireNode(this.key);

  /// The key that the node reads.
  final DiKey<A> key;

  @override
  HKT<G, A> fold<G>(DependencyAlgebra<G> algebra) => algebra.require(key);
}

/// An optional read of [key].
final class OptionalNode<A> extends DependencyNode<Option<A>> {
  /// Creates an optional read of [key].
  const OptionalNode(this.key);

  /// The key that the node reads.
  final DiKey<A> key;

  @override
  HKT<G, Option<A>> fold<G>(DependencyAlgebra<G> algebra) =>
      algebra.optional(key);
}

/// The application of a function value [ff] to the value [fa].
final class ApNode<A, B> extends DependencyNode<B> {
  /// Creates the application of [ff] to [fa].
  const ApNode(this.fa, this.ff);

  /// The argument. The application runs it first.
  final DependencyNode<A> fa;

  /// The function.
  final DependencyNode<B Function(A a)> ff;

  @override
  HKT<G, B> fold<G>(DependencyAlgebra<G> algebra) =>
      algebra.ap<A, B>(fa.fold(algebra), ff.fold(algebra));
}

/// One effect after the value of [source], with an optional release.
final class StepNode<A, B> extends DependencyNode<B> {
  /// Creates a step.
  const StepNode(this.source, this.effect, this.release);

  /// The tree that gives the input of the step.
  final DependencyNode<A> source;

  /// The effect of the step.
  final StepEffect<A, B> effect;

  /// The release of the result, or `null` when the step owns nothing.
  final StepRelease<B>? release;

  @override
  HKT<G, B> fold<G>(DependencyAlgebra<G> algebra) =>
      algebra.step<A, B>(source.fold(algebra), effect, release);
}
