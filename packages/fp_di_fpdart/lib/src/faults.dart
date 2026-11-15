// The test-only faults of the runtime self-checks, the deliberate defects, and
// the self-check mute. The library file does not export this file.
//
// A self-check confirms an internal invariant inside an `assert`. A fault makes
// the runtime break that invariant, so a test can see the self-check fail. A
// defect makes the runtime misbehave in a way that a check of the random
// histories must detect. The runtime reads [RuntimeFaults.selfCheck] and
// [RuntimeFaults.defect] only through [RuntimeFaults.breaks] and
// [RuntimeFaults.injects], and these read them only inside an `assert`. A build
// without assertions never sees a fault or a defect.

/// The self-check that a fault breaks.
enum SelfCheckFault {
  /// No fault. The only value that a release build can see.
  none,

  /// A release runs the stack of dispose functions of a node a second time.
  releaseAtMostOnce,

  /// A node starts its release without the release of its dependents.
  dependentFirst,

  /// A canceled activation commits.
  noCommitAfterCancel,

  /// The check compares a read with an empty shape.
  readsWithinShape,

  /// A lifecycle operation starts without waiting for the previous one.
  serialMutations,

  /// A read of the state does not find the nodes that changed.
  snapshotsCurrent,
}

/// A deliberate defect of the runtime. A test sets one to confirm that a check
/// of the random lifecycle histories detects it. The names follow the defects
/// of the formal model of `fp_di` where one exists.
enum Defect {
  /// No defect. The only value that a release build can see.
  none,

  /// `ParallelSteps`: the dispose functions of one stack run at the same time.
  parallelSteps,

  /// `AcqOrder`: a stack releases the oldest entry first.
  acqOrder,

  /// `DropLease`: a failed activation skips the release of its stack.
  dropLease,

  /// `SecondCallerOk`: a call that joins a disposal in progress completes with
  /// success, whatever the disposal reports.
  secondCallerOk,

  /// A call after a scope disposal finished gives the result of that disposal.
  replayAfterEnd,

  /// The start of a release replaces the state and calls no listener.
  silentReleaseStart,

  /// A `Scope.dispose` from inside a running operation records the disposal
  /// request and calls the listeners before it fails.
  lateReentrancyCheck,

  /// The failure of `get` lists no failed node.
  dropFailedNodes,

  /// A read selects the farthest binding of a key, so an ancestor value wins
  /// over the value of a nearer scope.
  farthestBinding,

  /// `NoWait`: a disposal request queues the disposal while a hold of its
  /// subtree is open.
  queueWithHolds,

  /// A call that ignores open holds reports no `IgnoredHoldsFailure`.
  dropIgnoredReport,

  /// `LoseDescendant`: a disposal of an ancestor that releases a scope with a
  /// waiting `dispose` call leaves that call incomplete.
  loseHeldCaller,

  /// `NoStepAfterCancel`: the check between the steps of a component does not
  /// stop an activation that a caller canceled, so a later step starts.
  skipCheckpoint,
}

/// The switches that a test sets to make the runtime break an invariant. Every
/// switch applies to every runtime of the isolate.
abstract final class RuntimeFaults {
  /// The fault that the runtime applies. Tests set it and reset it in
  /// `tearDown`.
  static SelfCheckFault selfCheck = SelfCheckFault.none;

  /// The defect that the runtime applies. Tests set it and reset it in
  /// `tearDown`.
  static Defect defect = Defect.none;

  /// Whether the self-checks pass without evaluation, so that a check of the
  /// random lifecycle histories, not a self-check, meets a defect. The runtime
  /// reads it only inside an `assert`.
  static bool selfChecksMuted = false;

  /// Whether each read of the state compares the result with a state that the
  /// runtime builds from scratch. The comparison costs a time that is linear in
  /// the number of nodes, so only the tests that look for a wrong snapshot set
  /// it. The runtime reads it only inside an `assert`.
  static bool verifySnapshots = false;

  /// Whether [fault] is set. It is always false when assertions are disabled.
  static bool breaks(SelfCheckFault fault) {
    var set = false;
    assert(() {
      set = selfCheck == fault;
      return true;
    }());
    return set;
  }

  /// Whether [value] is set. It is always false when assertions are disabled.
  static bool injects(Defect value) {
    var set = false;
    assert(() {
      set = defect == value;
      return true;
    }());
    return set;
  }

  /// Whether the self-checks run now. It is always false when assertions are
  /// disabled.
  static bool get checking {
    var on = false;
    assert(() {
      on = !selfChecksMuted;
      return true;
    }());
    return on;
  }

  /// Clears every switch.
  static void reset() {
    selfCheck = SelfCheckFault.none;
    defect = Defect.none;
    selfChecksMuted = false;
    verifySnapshots = false;
  }
}
