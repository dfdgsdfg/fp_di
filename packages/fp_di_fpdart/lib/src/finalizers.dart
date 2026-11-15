// Internal types. The library file does not export this file.
import 'dart:async';

import 'package:fpdart/fpdart.dart';

import 'cause.dart';
import 'failure.dart';
import 'faults.dart';

/// An immutable stack of the dispose functions of the values that an owner
/// holds.
///
/// A release runs the newest entry first, one entry after the other. A
/// release never throws. A dispose function that throws becomes a `Die` in
/// the resulting `Cause`.
final class Finalizers {
  const Finalizers._(this._entries);

  /// The stack with no entry.
  static const Finalizers empty = Finalizers._([]);

  /// The monoid of stacking: [empty] and [then].
  ///
  /// The operation is associative. A release of the combination runs the
  /// entries of the second stack first.
  static final Monoid<Finalizers> monoid = Monoid.instance<Finalizers>(
    empty,
    (first, second) => first.then(second),
  );

  final List<_Entry> _entries;

  /// Whether the stack has no entry.
  bool get isEmpty => _entries.isEmpty;

  /// A stack with [release] on top.
  ///
  /// The [owner] names the component in a [DisposeFailure].
  Finalizers push(String owner, FutureOr<void> Function() release) =>
      Finalizers._([..._entries, _Single(owner, release)]);

  /// A stack with a [release] on top that gives its own cause.
  ///
  /// The task never throws. A release of a value that owns more values, such
  /// as a `Lazy`, uses it: each failure of the inner release is already a `Die`
  /// of the cause.
  Finalizers pushCause(Task<Cause<DiFailure>> Function() release) =>
      Finalizers._([..._entries, _Cause(release)]);

  /// A stack with the entries of [next] on top.
  Finalizers then(Finalizers next) =>
      next.isEmpty ? this : Finalizers._([..._entries, ...next._entries]);

  /// A task that releases the stack and gives the cause of every failure.
  ///
  /// The entries release from the newest to the oldest, one after the other.
  /// Every entry runs. The cause is `Empty` when no dispose function failed.
  Task<Cause<DiFailure>> release() => Task(() async {
    // The newest entry starts at once, without a wait before it.
    var cause = const Empty<DiFailure>() as Cause<DiFailure>;
    // The defect `AcqOrder` releases the oldest entry first.
    final ordered = RuntimeFaults.injects(Defect.acqOrder)
        ? _entries
        : _entries.reversed.toList();
    // The defect `ParallelSteps` starts every entry before it awaits one.
    if (RuntimeFaults.injects(Defect.parallelSteps)) {
      final all = await Future.wait<Cause<DiFailure>>([
        for (final entry in ordered) entry.release().run(),
      ]);
      return all.fold<Cause<DiFailure>>(cause, (sum, next) => sum + next);
    }
    for (final entry in ordered) {
      cause += await entry.release().run();
    }
    return cause;
  });
}

sealed class _Entry {
  const _Entry();

  Task<Cause<DiFailure>> release();
}

final class _Single extends _Entry {
  const _Single(this.owner, this.run);

  final String owner;
  final FutureOr<void> Function() run;

  @override
  Task<Cause<DiFailure>> release() =>
      TaskEither<Cause<DiFailure>, Unit>.tryCatch(
        () async {
          await run();
          return unit;
        },
        (error, stackTrace) =>
            Die<DiFailure>(DisposeFailure(owner, error), stackTrace),
      ).match((defect) => defect, (_) => const Empty<DiFailure>());
}

final class _Cause extends _Entry {
  const _Cause(this.run);

  final Task<Cause<DiFailure>> Function() run;

  @override
  Task<Cause<DiFailure>> release() => run();
}
