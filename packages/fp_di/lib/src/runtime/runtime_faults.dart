// The test-only faults of the runtime self-checks, the deliberate defects,
// and the self-check mute (specs/runtime/lifecycle, "Self-checks and runtime
// cost"). Not exported from any public library.
//
// A self-check confirms an internal invariant inside an `assert`. A fault
// makes the runtime break that invariant, so a test can see the self-check
// fail. The runtime reads [RuntimeFaults.selfCheck] only through
// [RuntimeFaults.breaks], and that function reads it only inside an
// `assert`. A build without assertions therefore never sees a fault.

/// The self-check that a fault breaks.
enum RuntimeSelfCheckFault {
  /// No fault. The only value that a release build can see.
  none,

  /// A release pass runs the journal of an activation a second time.
  releaseAtMostOnce,

  /// A node starts its release without waiting for its dependents.
  dependentFirst,

  /// An acquisition that lands after its activation closed joins the journal.
  closedActivation,

  /// A failed activation publishes its staged values.
  atomicPublication,

  /// The check compares a read with an empty shape.
  readsWithinShape,

  /// A mutation starts without waiting for the previous one.
  serialMutations,

  /// The start of a release does not refresh the state of the nodes that
  /// wait for a withdrawn key.
  stateCurrent,
}

/// A deliberate defect of the runtime, named after the formal defect that it
/// implements where one exists. A test sets one to confirm that a check of
/// the random lifecycle histories detects it (specs/verification/test,
/// "Traceability chain"). The runtime reads [RuntimeFaults.defect] only
/// through [RuntimeFaults.injects], which reads it only inside an `assert`.
enum RuntimeDefect {
  /// No defect. The only value that a release build can see.
  none,

  /// `ParallelSteps`: the dispose functions of one journal run at the same
  /// time.
  parallelSteps,

  /// `AcqOrder`: a journal releases in acquisition order.
  acqOrder,

  /// `DropLease`: a failed activation skips the release of its journal.
  dropLease,

  /// `DropLater`: a failed `initialize` keeps only the rollback failures of the
  /// first failed member.
  dropLater,

  /// `DropLate`: the rollback failures of a canceled activation reach no
  /// recipient. The formal defect drops only the dispose failure of an
  /// acquisition that settles after the signal; this defect drops every
  /// rollback failure of the canceled activation.
  dropLate,

  /// `SecondCallerOk`: a call that joins a scope disposal in progress
  /// completes with success, whatever the disposal reports.
  secondCallerOk,

  /// No formal counterpart: a call after a scope disposal finished returns
  /// the result of that disposal.
  replayAfterEnd,

  /// No formal counterpart: a scope teardown starts a release only when no
  /// other release runs.
  sequentialTeardown,

  /// No formal counterpart: the start of a release replaces the state and
  /// calls no listener.
  silentReleaseStart,

  /// No formal counterpart: a `Scope.dispose` from inside a running mutation
  /// records the disposal request, cancels the setup in flight, and calls
  /// the listeners before it fails with `ReentrantMutationError`.
  lateReentrancyCheck,

  /// No formal counterpart: the `UnavailableKeyException` of `get` holds no
  /// failed node.
  dropFailedNodes,

  /// No formal counterpart: a read selects the farthest available binding of
  /// a key, so an ancestor value wins over the value of a nearer scope.
  farthestBinding,

  /// No formal counterpart: a listener that throws stays a listener.
  keepThrowingListener,

  /// `NoWait`: a disposal request queues the disposal mutation while a hold
  /// of its scope or of a descendant is open.
  queueWithHolds,

  /// `SetupWhileHeld`: an automatic activation starts for a node whose scope
  /// has a disposal request.
  setupWhileHeld,

  /// No formal counterpart: a call that ignores open holds reports no
  /// `IgnoredHoldsException`.
  dropIgnoredReport,

  /// `LoseDescendant`: a disposal of an ancestor that releases a scope with a
  /// waiting `dispose` call leaves that call incomplete.
  loseHeldCaller,

  /// `NoStepAfterCancel`: the checkpoint between the steps of a component
  /// does not throw after the token of its activation was canceled, so a later
  /// step starts. The model code cannot read the defect, and every
  /// `Dependency` step calls `context.checkpoint()`, so the context
  /// does not throw. The runtime calls the same checkpoint before a commit,
  /// so the defect skips that guard too.
  skipCheckpoint,
}

/// The switches that a test sets to make the runtime break an invariant.
/// Every switch applies to every runtime of the isolate.
abstract final class RuntimeFaults {
  /// The fault that the runtime applies. Tests set it and reset it in
  /// `tearDown`.
  static RuntimeSelfCheckFault selfCheck = RuntimeSelfCheckFault.none;

  /// The defect that the runtime applies. Tests set it and reset it in
  /// `tearDown`.
  static RuntimeDefect defect = RuntimeDefect.none;

  /// Whether the self-checks pass without evaluation, so that a check of the
  /// random lifecycle histories, not a self-check, meets a fault. The runtime
  /// reads it only inside an `assert`.
  static bool selfChecksMuted = false;

  /// Whether [fault] is set. It is always false when assertions are disabled.
  static bool breaks(RuntimeSelfCheckFault fault) {
    var set = false;
    assert(() {
      set = selfCheck == fault;
      return true;
    }());
    return set;
  }

  /// Whether [value] is set. It is always false when assertions are disabled.
  static bool injects(RuntimeDefect value) {
    var set = false;
    assert(() {
      set = defect == value;
      return true;
    }());
    return set;
  }

  /// Sets every switch to its default.
  static void reset() {
    selfCheck = RuntimeSelfCheckFault.none;
    defect = RuntimeDefect.none;
    selfChecksMuted = false;
  }
}
