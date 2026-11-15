------------------------------ MODULE Disposal ------------------------------
(***************************************************************************)
(* Callers of `dispose()` and the zone they call from.                     *)
(*                                                                         *)
(* Target T is disposed by one transaction on the serialized queue. The    *)
(* transaction marks T disposed when its releases finish, and its future   *)
(* completes later, after the rest of the transaction (errors.close).      *)
(* The cleanup may fail; every caller that waits gets that same result.    *)
(* Host callers outside any transaction may call T.dispose() any number   *)
(* of times; a release callback inside T's disposal transaction may       *)
(* also call T.dispose() or U.dispose() for another target U. Each call    *)
(* gets a result that completes, fails as reentrant, or waits.             *)
(*                                                                         *)
(* Holds of the disposal (R-UC-RT-LC-034): T starts with the open holds  *)
(* Holders, and its child scope D with one open hold. A request of T      *)
(* waits outside the queue while a hold of T or of D is open, unless a    *)
(* call ignores the holds. D can request its own disposal, which waits    *)
(* for the hold of D; a request of D after the request of T joins T. The  *)
(* disposal of T releases D, and a waiting caller of D gets its result.  *)
(*                                                                         *)
(* Code correspondence (abstraction map, not a refinement proof):          *)
(*   HostDispose    Scope.dispose / _disposeNode from a host zone          *)
(*   HostIgnore     Scope.dispose(ignoreHolds: true)                       *)
(*   CloseHold*     DisposeHold.close, _Runtime.holdClosed                 *)
(*   *DisposeD      Scope.dispose of the child D; the queued closure of D  *)
(*   StartTx        _RuntimeMutationQueue.run starts the queued disposal   *)
(*   InnerDispose   a release callback calls dispose inside the running   *)
(*                  mutation (Zone holds a running _RuntimeMutation)      *)
(*   FinishRelease  runCleanups finishes the release step                  *)
(*   MarkDisposed   disposeScope sets disposed, before errors.close       *)
(*   FinishTx       the mutation returns; the shared future               *)
(*                  (scope.disposal, node.disposal) completes             *)
(*                                                                         *)
(* Fault selects at most one deliberate defect (negative controls).        *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    Holders,  \* the open holds of T at the start
    Callers,  \* host callers of T.dispose()
    Fails,    \* {TRUE}, {FALSE}, or both: whether the cleanup fails
    Fault     \* "none" or one deliberate defect below

Faults == {
    "none",
    "CompleteEarly", \* a repeated call completes before the cleanup ends
    "DisposedShortcut", \* a call after the mark completes before the future
    "ShareFirst",    \* an inner call shares the disposal before the check
    "MarkFirst",     \* a rejected inner call marks its target first
    "NoWait",        \* a request queues the disposal with a hold open
    "LoseDescendant" \* the disposal of T leaves a waiting caller of D
}

ASSUME Fault \in Faults

VARIABLES
    fails,      \* the cleanup of T fails (chosen up front)
    disposalT,  \* "none" | "queued" | "running" | "marked" | "done"
    release,    \* T's release step: "idle" | "running" | "finished"
    caller,     \* [Callers -> "idle" | "waiting" | "ok" | "failed" | "noop"]
    innerT,     \* the release callback's T.dispose(): "none" | "waiting" | "rejected"
    innerU,     \* the release callback's U.dispose(): "none" | "rejected"
    markedU,    \* U's disposal was requested (cancels its setup, blocks initialize)
    disposalU,  \* U's disposal: "none" | "queued"
    holdT,      \* the open holds of T
    holdD,      \* the hold of the child D is open
    ignored,    \* a call ignored the holds of T
    ignorer,    \* the call that ignores the holds: "idle" | "called"
    disposalD,  \* D's own disposal: "none" | "waiting" | "queued" | "done"
    callerD,    \* the caller of D.dispose(): "idle" | "waiting" | "ok" | "failed" | "noop"
    releasedByT \* the disposal of T released D

vars == <<fails, disposalT, release, caller, innerT, innerU, markedU, disposalU,
          holdT, holdD, ignored, ignorer, disposalD, callerD, releasedByT>>

holdVars == <<holdT, holdD, ignored, ignorer, disposalD, callerD, releasedByT>>

\* No hold of T or of its child D is open.
NoHold == holdT = {} /\ ~holdD

TypeOK ==
    /\ fails \in BOOLEAN
    /\ disposalT \in {"none", "waiting", "queued", "running", "marked", "done"}
    /\ release \in {"idle", "running", "finished"}
    /\ caller \in [Callers -> {"idle", "waiting", "ok", "failed", "noop"}]
    /\ innerT \in {"none", "waiting", "rejected"}
    /\ innerU \in {"none", "rejected"}
    /\ markedU \in BOOLEAN
    /\ disposalU \in {"none", "queued"}
    /\ holdT \subseteq Holders
    /\ holdD \in BOOLEAN
    /\ ignored \in BOOLEAN
    /\ ignorer \in {"idle", "called"}
    /\ disposalD \in {"none", "waiting", "queued", "done"}
    /\ callerD \in {"idle", "waiting", "ok", "failed", "noop"}
    /\ releasedByT \in BOOLEAN

Outcome == IF fails THEN "failed" ELSE "ok"

Init ==
    /\ fails \in Fails
    /\ disposalT = "none"
    /\ release = "idle"
    /\ caller = [c \in Callers |-> "idle"]
    /\ innerT = "none"
    /\ innerU = "none"
    /\ markedU = FALSE
    /\ disposalU = "none"
    /\ holdT = Holders
    /\ holdD = TRUE
    /\ ignored = FALSE
    /\ ignorer = "idle"
    /\ disposalD = "none"
    /\ callerD = "idle"
    /\ releasedByT = FALSE

\* A host call from outside any transaction.
HostDispose(c) ==
    /\ caller[c] = "idle"
    /\ caller' = [caller EXCEPT ![c] =
         CASE disposalT = "done" -> "noop"
           [] disposalT = "marked" ->
                IF Fault = "DisposedShortcut" THEN "noop" ELSE "waiting"
           [] disposalT \in {"queued", "running"} ->
                IF Fault = "CompleteEarly" THEN "ok" ELSE "waiting"
           [] OTHER -> "waiting"]
    /\ disposalT' = IF disposalT = "none"
                     THEN IF NoHold \/ Fault = "NoWait" THEN "queued" ELSE "waiting"
                     ELSE disposalT
    /\ UNCHANGED <<fails, release, innerT, innerU, markedU, disposalU>>
    /\ UNCHANGED holdVars

\* A host call with ignoreHolds: the disposal of T enters the queue at once.
HostIgnore ==
    /\ ignorer = "idle"
    /\ ignorer' = "called"
    /\ disposalT \in {"none", "waiting"}
    /\ disposalT' = "queued"
    /\ ignored' = TRUE
    /\ UNCHANGED <<fails, release, caller, innerT, innerU, markedU, disposalU,
                   holdT, holdD, disposalD, callerD, releasedByT>>

\* A hold of T closes; a waiting disposal of T enters the queue when no hold
\* of its subtree is open any more.
CloseHoldT(h) ==
    /\ h \in holdT
    /\ holdT' = holdT \ {h}
    /\ disposalT' = IF disposalT = "waiting" /\ holdT' = {} /\ ~holdD
                     THEN "queued" ELSE disposalT
    /\ UNCHANGED <<fails, release, caller, innerT, innerU, markedU, disposalU,
                   holdD, ignored, ignorer, disposalD, callerD, releasedByT>>

\* The hold of D closes; a waiting disposal of D, and one of T, enter the
\* queue when their subtrees have no open hold.
CloseHoldD ==
    /\ holdD
    /\ holdD' = FALSE
    /\ disposalD' = IF disposalD = "waiting" THEN "queued" ELSE disposalD
    /\ disposalT' = IF disposalT = "waiting" /\ holdT = {}
                     THEN "queued" ELSE disposalT
    /\ UNCHANGED <<fails, release, caller, innerT, innerU, markedU, disposalU,
                   holdT, ignored, ignorer, callerD, releasedByT>>

\* A host call of D.dispose(). After the request of T, the call joins the
\* disposal of T; otherwise D waits for its own hold.
HostDisposeD ==
    /\ callerD = "idle"
    \* A call after D was released completes at once.
    /\ callerD' = IF disposalD = "done" THEN "noop" ELSE "waiting"
    /\ disposalD' = IF disposalT = "none" /\ disposalD = "none"
                     THEN IF holdD THEN "waiting" ELSE "queued"
                     ELSE disposalD
    /\ UNCHANGED <<fails, disposalT, release, caller, innerT, innerU, markedU,
                   disposalU, holdT, holdD, ignored, ignorer, releasedByT>>

\* The queued disposal of D runs alone on the queue and releases D.
StartTxD ==
    /\ disposalD = "queued"
    /\ disposalT \notin {"running", "marked"}
    /\ disposalD' = "done"
    /\ callerD' = IF callerD = "waiting" THEN "ok" ELSE callerD
    /\ UNCHANGED <<fails, disposalT, release, caller, innerT, innerU, markedU,
                   disposalU, holdT, holdD, ignored, ignorer, releasedByT>>

StartTx ==
    /\ disposalT = "queued"
    /\ disposalT' = "running"
    /\ release' = "running"
    /\ UNCHANGED <<fails, caller, innerT, innerU, markedU, disposalU>>
    /\ UNCHANGED holdVars

\* The release callback calls T.dispose() inside T's running transaction.
InnerDisposeT ==
    /\ release = "running"
    /\ innerT = "none"
    /\ innerT' = IF Fault = "ShareFirst" THEN "waiting" ELSE "rejected"
    /\ UNCHANGED <<fails, disposalT, release, caller, innerU, markedU, disposalU>>
    /\ UNCHANGED holdVars

\* The release callback calls U.dispose() for another target.
InnerDisposeU ==
    /\ release = "running"
    /\ innerU = "none"
    /\ innerU' = "rejected"
    /\ markedU' = (Fault = "MarkFirst")
    /\ UNCHANGED <<fails, disposalT, release, caller, innerT, disposalU>>
    /\ UNCHANGED holdVars

\* The release step returns once its own calls have settled; a call that
\* waits for this transaction never settles.
FinishRelease ==
    /\ release = "running"
    /\ innerT # "waiting"
    /\ release' = "finished"
    /\ UNCHANGED <<fails, disposalT, caller, innerT, innerU, markedU, disposalU>>
    /\ UNCHANGED holdVars

\* The releases are done: T is marked disposed, the transaction goes on.
MarkDisposed ==
    /\ disposalT = "running"
    /\ release = "finished"
    /\ disposalT' = "marked"
    /\ UNCHANGED <<fails, release, caller, innerT, innerU, markedU, disposalU>>
    /\ UNCHANGED holdVars

\* The transaction returns: every waiting caller gets the one result. The
\* disposal of T released D too, unless D was released first, and a waiting
\* caller of D gets the same result.
FinishTx ==
    /\ disposalT = "marked"
    /\ disposalT' = "done"
    /\ caller' = [c \in Callers |->
                    IF caller[c] = "waiting" THEN Outcome ELSE caller[c]]
    /\ innerT' = IF innerT = "waiting" THEN "rejected" ELSE innerT
    /\ UNCHANGED <<fails, release, innerU, markedU, disposalU>>
    /\ IF disposalD = "done" \/ (Fault = "LoseDescendant" /\ disposalD = "waiting")
       THEN UNCHANGED <<disposalD, callerD, releasedByT>>
       ELSE /\ disposalD' = "done"
            /\ releasedByT' = TRUE
            /\ callerD' = IF callerD = "waiting" THEN Outcome ELSE callerD
    /\ UNCHANGED <<holdT, holdD, ignored, ignorer>>

Next ==
    \/ \E c \in Callers : HostDispose(c)
    \/ HostIgnore \/ \E h \in Holders : CloseHoldT(h) \/ CloseHoldD
    \/ HostDisposeD \/ StartTxD
    \/ StartTx \/ InnerDisposeT \/ InnerDisposeU \/ FinishRelease
    \/ MarkDisposed \/ FinishTx

Spec == Init /\ [][Next]_vars

TxFairness ==
    /\ WF_vars(StartTx) /\ WF_vars(FinishRelease)
    /\ WF_vars(MarkDisposed) /\ WF_vars(FinishTx) /\ WF_vars(StartTxD)

\* Every hold closes eventually.
FairSpec ==
    Spec /\ TxFairness
         /\ \A h \in Holders : WF_vars(CloseHoldT(h)) /\ WF_vars(CloseHoldD)

\* No hold has to close, but a call that ignores the holds comes.
FairIgnoreSpec == Spec /\ TxFairness /\ WF_vars(HostIgnore)

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)

\* A caller's dispose() completes only after the whole transaction finished,
\* and with the result of that cleanup. A call after the end is a no-op.
CompleteAfterCleanup ==
    \A c \in Callers : caller[c] \in {"ok", "failed"} => disposalT = "done"

\* Every caller that called while the disposal ran gets its result.
SharedResult ==
    \A c \in Callers : caller[c] \in {"ok", "failed"} => caller[c] = Outcome

\* A no-op completion happens only after the disposal finished.
NoopAfterEnd == \A c \in Callers : caller[c] = "noop" => disposalT = "done"

\* No call inside the running transaction waits for that transaction.
NoSelfWait == innerT # "waiting"

\* A rejected call changes nothing: U is marked only with a disposal.
NoMarkWithoutDisposal == markedU => disposalU # "none"

\* No release of T starts while a hold of T or of D is open, unless a call
\* ignored the holds. D is released by its own disposal only after its hold
\* closed.
NoDisposalWhileHeld ==
    /\ release # "idle" => NoHold \/ ignored
    /\ (disposalD = "done" /\ ~releasedByT) => ~holdD

\* A caller of D gets the result of the disposal that released D.
CallersAgreeD ==
    callerD \in {"ok", "failed"} =>
        callerD = IF releasedByT THEN Outcome ELSE "ok"

\* A requested disposal ends, and each waiting caller of T and of D completes.
HeldDisposalProgress ==
    /\ (disposalT \in {"waiting", "queued", "running"}) ~> (disposalT = "done")
    /\ \A c \in Callers :
         (caller[c] = "waiting") ~> (caller[c] \in {"ok", "failed"})
    /\ (callerD = "waiting") ~> (callerD \in {"ok", "failed"})

\* Every requested disposal finishes, and every waiting caller completes.
DisposalCompletes ==
    /\ (disposalT \in {"queued", "running"}) ~> (disposalT = "done")
    /\ \A c \in Callers :
         (caller[c] = "waiting") ~> (caller[c] \in {"ok", "failed"})
=============================================================================
