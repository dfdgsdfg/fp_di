// The outcome of one attempt to activate a node. The runtime makes the
// attempt and chooses the value. A caller of the attempt switches on the
// value.
import 'core_cause.dart';

/// Why an attempt to activate a node did not start.
enum CoreNotStartedReason {
  /// The node left its runtime.
  removed,

  /// The node holds a committed activation.
  active,

  /// The scope of the node releases its nodes.
  scopeDisposing,

  /// A key that the node requires does not resolve.
  unsatisfied,

  /// A pending withdrawal canceled an earlier activation. The node waits for
  /// the withdrawal to finish.
  withdrawalPending,
}

/// The result of one attempt to activate a node.
sealed class CoreActivationOutcome {
  /// Creates an outcome. Use a subtype.
  const CoreActivationOutcome();
}

/// The activation committed: the node is active.
final class CoreCommitted extends CoreActivationOutcome {
  /// Creates the outcome of a commit.
  const CoreCommitted();
}

/// The attempt did not start, so the node is as it was.
final class CoreNotStarted extends CoreActivationOutcome {
  /// Creates the outcome of an attempt that did not start for [reason].
  const CoreNotStarted(this.reason);

  /// Why the attempt did not start.
  final CoreNotStartedReason reason;
}

/// A withdrawal canceled the activation. The cancellation is not a failure.
/// The node stays inactive and waits for the withdrawal.
final class CoreWithdrawn extends CoreActivationOutcome {
  /// Creates the outcome of a canceled activation that waits for a
  /// withdrawal.
  const CoreWithdrawn();
}

/// A cancellation ended the activation, and the node does not wait for a
/// withdrawal. The outcome also covers a disposal request that came before
/// the attempt began.
final class CoreInterrupted extends CoreActivationOutcome {
  /// Creates the outcome of an interrupted activation.
  const CoreInterrupted(this.interrupt);

  /// The cause of the interruption.
  final CoreInterrupt interrupt;
}

/// The activation failed.
final class CoreFailed extends CoreActivationOutcome {
  /// Creates the outcome of a failed activation.
  const CoreFailed(this.failure);

  /// The cause of the failure.
  final CoreFail failure;
}
