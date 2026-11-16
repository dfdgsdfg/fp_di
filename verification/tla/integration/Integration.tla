---------------------------- MODULE Integration ----------------------------
(***************************************************************************)
(* Histories that cross models: a cancelled activation, the failure of its *)
(* late release, and the callers of a disposal that shares one result.     *)
(*                                                                         *)
(* This module checks the current code, as a composition of the            *)
(* vocabulary of Cancellation.tla (signal, late lease, rollback, awaiting  *)
(* withdrawal), Disposal.tla (callers that share one disposal), and        *)
(* Reporting.tla (dispose failures with an identity, delivered records,    *)
(* exact recipients). Each focused model passes alone; this one checks     *)
(* the routing of a dispose failure across all three in one history.       *)
(*                                                                         *)
(* One node R runs an activation episode inside transaction X. Its         *)
(* acquisition ignores the signal and settles late. While X runs, the host *)
(* calls dispose() (callers 1 and 2 share one disposal). Which target the  *)
(* host disposes selects the history (Cause):                              *)
(*   "owner"       R itself or its scope. The activation is cancelled by   *)
(*                 its owner and is never retried.                         *)
(*   "withdrawal"  The publisher P that R reads. R is cancelled for the    *)
(*                 withdrawal, stays dormant, and may activate again after *)
(*                 the withdrawal (a fallback publisher or an optional     *)
(*                 read). The release of P may fail.                       *)
(* The disposal transaction D queues behind X. The late release of R may   *)
(* fail. The model checks who receives each dispose failure.               *)
(*                                                                         *)
(* Code correspondence (abstraction map, not a refinement proof):          *)
(*   HostDispose    Scope.dispose / _disposeNode: requestScopeDisposal,    *)
(*                  requestNodeDisposal, _requestWithdrawal complete the   *)
(*                  signal at the call (scope.dart, runtime.dart); a       *)
(*                  repeated call shares node.disposal / scope.disposal    *)
(*   Land           the future of DiContext.acquire settles; the           *)
(*                  post-acquire guard of _RuntimeActivation.acquire is    *)
(*                  idle, because D has not started (_activating)          *)
(*   Commit         activate: publish staging, set active                  *)
(*   Rollback       activate catch: runCleanups(activation.cleanups) after *)
(*                  the checkpoint; failed releases join rollbackFailures  *)
(*   Deliver        the dispose failures leave activate:                   *)
(*                  - owner:                                               *)
(*                    ActivationCanceledException(rollbackFailures),       *)
(*                    through activateMembers and the rollback of          *)
(*                    initialize to the initialize caller; for an automatic*)
(*                    activation, _activateDormant emits DisposeException  *)
(*                    to Scope.errors                                      *)
(*                  - withdrawal: activate returns, the node is dormant,   *)
(*                    emitError(DisposeException) goes to Scope.errors,    *)
(*                    and an initialize that started R succeeds            *)
(*   StartTx        _RuntimeMutationQueue.run starts D after X returned    *)
(*   ReleasePub     deactivate(P, permanent): runCleanups of P             *)
(*   MarkDisposed   removeNode (R or P)                                    *)
(*   FinishWithdrawal  finishWithdrawal: R no longer awaits P              *)
(*   Reconcile      reconcile after the withdrawal: R activates again      *)
(*   FinishTx       the mutation returns; the shared future completes     *)
(*                  with DisposeException(dispose failures of D) or        *)
(*                  normally                                               *)
(*                                                                         *)
(* Abstractions and deviations from the focused models.                    *)
(*   - Release callbacks may fail here (Cancellation.tla: they never do).  *)
(*     R has one late lease. Release of P is one atomic step.              *)
(*   - Only the first dispose request must arrive while X runs (the        *)
(*     history); later calls arrive at any time, as in Disposal.tla.       *)
(*     Disposal.tla's CompleteEarly and DisposedShortcut stay there.       *)
(*   - With Via = "initialize" and Cause = "withdrawal", P is in an        *)
(*     ancestor scope: scope.nodes is empty during initialize.             *)
(*   - Reactivation of R is the phase "reactivated"; its own episode is    *)
(*     not modeled (Reconcile.tla, Cancellation.tla).                      *)
(*   - The post-acquire guard of _RuntimeActivation.acquire is not         *)
(*     modeled: D queues behind X, so it cannot run while the late         *)
(*     lease lands. Fault OverlapDispose removes that serialization.       *)
(*   - Lazy, reentrancy, and the Scope.errors stream being closed or       *)
(*     without listener are outside this model.                            *)
(*                                                                         *)
(* Fault selects at most one deliberate defect (negative controls).        *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Cause,        \* "owner" | "withdrawal": what the host disposes
    Via,          \* "initialize" | "reconcile": the call that ran the activation
    Callers,      \* host callers of dispose(), numbers other than 0
    LateFailsSet, \* {TRUE}, {FALSE}, or both: the late release of R fails
    PubFailsSet,  \* the release of P fails (Cause = "withdrawal" only)
    FallbackSet,  \* R is satisfied again after the withdrawal
    Fault         \* "none" or one deliberate defect below

Faults == {
    "none",
    "MisrouteLate",         \* the late dispose failure joins the dispose
                            \* result
    "DropLate",             \* the late dispose failure reaches no caller
    "SecondCallerOk",       \* a caller after the first sees success
    "OverlapDispose",       \* D starts while the activation still runs
    "RollbackAtSignal",     \* rollback starts before the acquisition settles
    "ReactivateEarly",      \* R activates while it awaits the withdrawal
    "RollbackAwaitsDispose" \* the rollback waits for D, which waits for it
}

ASSUME Fault \in Faults
ASSUME Cause \in {"owner", "withdrawal"}
ASSUME Via \in {"initialize", "reconcile"}
ASSUME Callers \subseteq Nat \ {0}
ASSUME LateFailsSet \subseteq BOOLEAN /\ PubFailsSet \subseteq BOOLEAN
ASSUME FallbackSet \subseteq BOOLEAN
ASSUME Cause = "owner" => PubFailsSet = {FALSE} /\ FallbackSet = {FALSE}

VARIABLES
    lateFails, \* the late release of R fails (chosen up front)
    pubFails,  \* the release of P fails (chosen up front)
    fallback,  \* R is satisfied after the withdrawal (chosen up front)
    act,       \* activation of R: "flight" | "landed" | "rolledBack" | "done"
    landed,    \* the late lease exists (ghost)
    relLate,   \* release attempts of the late lease
    sig,       \* signal of R: "none" | "owner" | "withdrawal"
    awaiting,  \* R awaits the withdrawal of P
    rph,       \* "setup" | "active" | "dormant" | "removed" | "reactivated"
    disp,      \* the disposal: "none" | "queued" | "running" | "marked" | "done"
    pubRel,    \* the release of P: "na" | "idle" | "finished"
    recon,     \* D reconciled after the withdrawal
    caller,    \* [Callers -> "idle" | "waiting" | "got" | "noop"]
    firstC,    \* the caller of the first request (0: none yet)
    delivered  \* the results that reached recipients: a set of records

vars == <<lateFails, pubFails, fallback, act, landed, relLate, sig, awaiting,
          rph, disp, pubRel, recon, caller, firstC, delivered>>

TypeOK ==
    /\ lateFails \in BOOLEAN /\ pubFails \in BOOLEAN /\ fallback \in BOOLEAN
    /\ act \in {"flight", "landed", "rolledBack", "done"}
    /\ landed \in BOOLEAN
    /\ relLate \in 0..2
    /\ sig \in {"none", "owner", "withdrawal"}
    /\ awaiting \in BOOLEAN
    /\ rph \in {"setup", "active", "dormant", "removed", "reactivated"}
    /\ disp \in {"none", "queued", "running", "marked", "done"}
    /\ pubRel \in {"na", "idle", "finished"}
    /\ recon \in BOOLEAN
    /\ caller \in [Callers -> {"idle", "waiting", "got", "noop"}]
    /\ firstC \in Callers \cup {0}

Init ==
    /\ lateFails \in LateFailsSet
    /\ pubFails \in PubFailsSet
    /\ fallback \in FallbackSet
    /\ act = "flight"
    /\ landed = FALSE
    /\ relLate = 0
    /\ sig = "none"
    /\ awaiting = FALSE
    /\ rph = "setup"
    /\ disp = "none"
    /\ pubRel = IF Cause = "withdrawal" THEN "idle" ELSE "na"
    /\ recon = FALSE
    /\ caller = [c \in Callers |-> "idle"]
    /\ firstC = 0
    /\ delivered = {}

-----------------------------------------------------------------------------
(* Records. `who` is 0 unless the recipient is a dispose caller. *)

InitRec(disposeFailures) ==
    [to |-> "initialize", who |-> 0,
     kind |-> IF Cause = "owner" THEN "canceled" ELSE "ok",
     disposeFailures |-> disposeFailures]

ErrRec(disposeFailures) ==
    [to |-> "errors", who |-> 0, kind |-> "dispose",
     disposeFailures |-> disposeFailures]

\* The records of the activation, for the late dispose failures `late`:
\* initialize carries them when the owner cancelled the call; Scope.errors
\* gets them for an automatic activation and for a withdrawal.
ActivationRecords(late) ==
    LET toInit == IF Cause = "owner" THEN late ELSE {}
        toErr == IF Cause = "owner" /\ Via = "initialize" THEN {} ELSE late
    IN  (IF Via = "initialize" THEN {InitRec(toInit)} ELSE {})
        \cup (IF toErr # {} THEN {ErrRec(toErr)} ELSE {})

LateAttempted == lateFails /\ relLate >= 1
PubAttempted == pubFails /\ pubRel = "finished"

\* The late dispose failures that the activation reports. Faults change only
\* this.
ReportedLate ==
    IF ~LateAttempted \/ Fault \in {"DropLate", "MisrouteLate"}
    THEN {} ELSE {"late"}

\* The dispose failures of the disposal transaction D itself.
DisposalFailures ==
    (IF PubAttempted THEN {"pub"} ELSE {})
    \cup (IF Fault = "MisrouteLate" /\ LateAttempted THEN {"late"} ELSE {})

CallerRec(c) ==
    LET disposeFailures == IF Fault = "SecondCallerOk" /\ c # firstC
                           THEN {} ELSE DisposalFailures
    IN  [to |-> "dispose", who |-> c,
         kind |-> IF disposeFailures = {} THEN "ok" ELSE "failed",
         disposeFailures |-> disposeFailures]

-----------------------------------------------------------------------------
(* Activation *)

\* The uncooperative acquisition settles. The lease is owned by the
\* activation (cleanups), because D has not started.
Land ==
    /\ ~landed
    /\ landed' = TRUE
    /\ act' = IF act = "flight" THEN "landed" ELSE act
    /\ UNCHANGED <<lateFails, pubFails, fallback, relLate, sig, awaiting, rph,
                   disp, pubRel, recon, caller, firstC, delivered>>

\* No signal: the checkpoint passes and the activation commits.
Commit ==
    /\ act = "landed"
    /\ sig = "none"
    /\ act' = "done"
    /\ rph' = "active"
    /\ UNCHANGED <<lateFails, pubFails, fallback, landed, relLate, sig,
                   awaiting, disp, pubRel, recon, caller, firstC, delivered>>

\* The checkpoint sees the signal: no commit; the lease is released once.
Rollback ==
    /\ sig # "none"
    /\ \/ act = "landed"
       \/ (Fault = "RollbackAtSignal" /\ act = "flight")
    /\ act' = "rolledBack"
    /\ relLate' = IF landed THEN relLate + 1 ELSE relLate
    /\ UNCHANGED <<lateFails, pubFails, fallback, landed, sig, awaiting, rph,
                   disp, pubRel, recon, caller, firstC, delivered>>

\* The activation leaves with its dispose failures and X returns.
Deliver ==
    /\ act = "rolledBack"
    /\ (Fault = "RollbackAwaitsDispose" => disp = "done")
    /\ act' = "done"
    /\ rph' = IF (rph = "removed" \/ (Cause = "owner" /\ Via = "initialize"))
              THEN "removed" ELSE "dormant"
    /\ delivered' = delivered \cup ActivationRecords(ReportedLate)
    /\ UNCHANGED <<lateFails, pubFails, fallback, landed, relLate, sig,
                   awaiting, disp, pubRel, recon, caller, firstC>>

-----------------------------------------------------------------------------
(* Host callers of dispose() and the disposal transaction D *)

\* The first request arrives while X runs and completes the signal at once;
\* a repeated call arrives at any time and shares the disposal.
HostDispose(c) ==
    /\ caller[c] = "idle"
    /\ (disp # "none" \/ act \in {"flight", "landed"})
    /\ caller' = [caller EXCEPT ![c] =
         CASE disp = "done" -> "noop"
           [] OTHER -> "waiting"]
    /\ firstC' = IF disp = "none" THEN c ELSE firstC
    /\ disp' = IF disp = "none" THEN "queued" ELSE disp
    /\ sig' = IF disp = "none" THEN Cause ELSE sig
    /\ awaiting' = IF disp = "none" /\ Cause = "withdrawal" THEN TRUE
                   ELSE awaiting
    /\ UNCHANGED <<lateFails, pubFails, fallback, act, landed, relLate, rph,
                   pubRel, recon, delivered>>

\* D queues behind X: it starts only after the activation returned.
StartTx ==
    /\ disp = "queued"
    /\ (act = "done" \/ Fault = "OverlapDispose")
    /\ disp' = "running"
    /\ UNCHANGED <<lateFails, pubFails, fallback, act, landed, relLate, sig,
                   awaiting, rph, pubRel, recon, caller, firstC, delivered>>

\* The release of P runs; it may fail.
ReleasePub ==
    /\ disp = "running"
    /\ pubRel = "idle"
    /\ pubRel' = "finished"
    /\ UNCHANGED <<lateFails, pubFails, fallback, act, landed, relLate, sig,
                   awaiting, rph, disp, recon, caller, firstC, delivered>>

MarkDisposed ==
    /\ disp = "running"
    /\ pubRel # "idle"
    /\ disp' = "marked"
    /\ rph' = IF Cause = "owner" THEN "removed" ELSE rph
    /\ UNCHANGED <<lateFails, pubFails, fallback, act, landed, relLate, sig,
                   awaiting, pubRel, recon, caller, firstC, delivered>>

FinishWithdrawal ==
    /\ disp = "marked"
    /\ awaiting
    /\ awaiting' = FALSE
    /\ UNCHANGED <<lateFails, pubFails, fallback, act, landed, relLate, sig,
                   rph, disp, pubRel, recon, caller, firstC, delivered>>

\* The reconciliation inside D: a satisfied dormant reader activates again.
Reconcile ==
    /\ disp = "marked"
    /\ ~awaiting
    /\ ~recon
    /\ recon' = TRUE
    /\ rph' = IF Cause = "withdrawal" /\ fallback /\ rph = "dormant"
              THEN "reactivated" ELSE rph
    /\ UNCHANGED <<lateFails, pubFails, fallback, act, landed, relLate, sig,
                   awaiting, disp, pubRel, caller, firstC, delivered>>

\* The mutation returns: every waiting caller gets the one result.
FinishTx ==
    /\ disp = "marked"
    /\ ~awaiting
    /\ recon
    /\ disp' = "done"
    /\ caller' = [c \in Callers |->
                    IF caller[c] = "waiting" THEN "got" ELSE caller[c]]
    /\ delivered' = delivered \cup
         {CallerRec(c) : c \in {d \in Callers : caller[d] = "waiting"}}
    /\ UNCHANGED <<lateFails, pubFails, fallback, act, landed, relLate, sig,
                   awaiting, rph, pubRel, recon, firstC>>

\* Defect: R activates while it still awaits the withdrawal of P.
ReactivateEarly ==
    /\ Fault = "ReactivateEarly"
    /\ Cause = "withdrawal"
    /\ fallback
    /\ rph = "dormant"
    /\ awaiting
    /\ rph' = "reactivated"
    /\ UNCHANGED <<lateFails, pubFails, fallback, act, landed, relLate, sig,
                   awaiting, disp, pubRel, recon, caller, firstC, delivered>>

Next ==
    \/ Land \/ Commit \/ Rollback \/ Deliver
    \/ \E c \in Callers : HostDispose(c)
    \/ StartTx \/ ReleasePub \/ MarkDisposed \/ FinishWithdrawal
    \/ Reconcile \/ FinishTx \/ ReactivateEarly

Spec == Init /\ [][Next]_vars

FairSpec ==
    Spec /\ WF_vars(Land) /\ WF_vars(Commit) /\ WF_vars(Rollback)
         /\ WF_vars(Deliver) /\ WF_vars(StartTx) /\ WF_vars(ReleasePub)
         /\ WF_vars(MarkDisposed) /\ WF_vars(FinishWithdrawal)
         /\ WF_vars(Reconcile) /\ WF_vars(FinishTx)

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)

\* What the code delivers, from the fixed outcome. Faults never change it.
ExpectedLate == IF lateFails THEN {"late"} ELSE {}
ExpectedActivation == ActivationRecords(ExpectedLate)
ExpectedDisposalFailures == IF Cause = "withdrawal" /\ pubFails THEN {"pub"}
                          ELSE {}
ExpectedCaller(c) ==
    [to |-> "dispose", who |-> c,
     kind |-> IF ExpectedDisposalFailures = {} THEN "ok" ELSE "failed",
     disposeFailures |-> ExpectedDisposalFailures]

\* Each delivered record is exactly the one its recipient must receive, and
\* a recipient receives at most one.
RecipientsExact ==
    /\ \A d \in delivered :
         \/ (d.to \in {"initialize", "errors"} /\ d \in ExpectedActivation)
         \/ (d.to = "dispose" /\ d = ExpectedCaller(d.who))
    /\ \A d1, d2 \in delivered :
         (d1.to = d2.to /\ d1.who = d2.who) => d1 = d2

\* The activation returned: its records exist.
ActivationDelivered ==
    (act = "done" /\ rph # "active") => ExpectedActivation \subseteq delivered

\* Every caller that shared the disposal gets the same result.
CallersAgree ==
    \A d1, d2 \in delivered :
        (d1.to = "dispose" /\ d2.to = "dispose")
            => d1.kind = d2.kind /\ d1.disposeFailures = d2.disposeFailures

\* Every release that ran and failed reaches some recipient.
NoLostDisposeFailure ==
    (act = "done" /\ disp \in {"none", "done"}) =>
        /\ LateAttempted =>
               "late" \in UNION {d.disposeFailures : d \in delivered}
        /\ PubAttempted =>
               "pub" \in UNION {d.disposeFailures : d \in delivered}

ReleaseAtMostOnce == relLate <= 1

\* The late lease is released once, after the activation was cancelled.
LeaseAccounted == (act = "done" /\ rph # "active" /\ landed) => relLate = 1

\* Rollback starts only after the acquisition settled.
SettleBeforeRollback == act \in {"rolledBack", "done"} => landed

\* An activation whose signal completed never commits.
NoCommitAfterCancel == rph = "active" => sig = "none"

\* The disposal transaction does not overlap the activation transaction, so
\* the publisher is released only after the reader's late lease.
DisposalAfterRollback == disp \in {"running", "marked", "done"} => act = "done"

\* A removed reader never returns; a withdrawn reader returns only after the
\* publisher's release and the end of the withdrawal.
NoReactivateBeforeWithdrawal ==
    rph = "reactivated" =>
        /\ Cause = "withdrawal"
        /\ ~awaiting
        /\ pubRel = "finished"

\* Liveness: every started activation and disposal finishes, and every
\* waiting caller completes.
IntegrationCompletes ==
    /\ (act \in {"flight", "landed", "rolledBack"}) ~> (act = "done")
    /\ (disp \in {"queued", "running", "marked"}) ~> (disp = "done")
    /\ \A c \in Callers : (caller[c] = "waiting") ~> (caller[c] = "got")

(***************************************************************************)
(* Reachability witnesses: each states that a behavior never happens. The  *)
(* expected violation shows that a conforming configuration reaches it.    *)
(***************************************************************************)

\* A failed late release reaches the initialize caller of a cancelled call.
WitnessLateToInitialize ==
    ~(\E d \in delivered : d.to = "initialize" /\ "late" \in d.disposeFailures)

\* The late dispose failure and the dispose failure of the publisher take
\* different routes: errors and both dispose callers.
WitnessSplitRouting ==
    ~(/\ \E d \in delivered : d.to = "errors" /\ "late" \in d.disposeFailures
      /\ \A c \in Callers :
           \E d \in delivered : d.to = "dispose" /\ d.who = c
                                /\ d.disposeFailures = {"pub"})

\* The reader activates again although the publisher's release failed.
WitnessReactivatedAfterFailure == ~(rph = "reactivated" /\ pubFails)
=============================================================================
