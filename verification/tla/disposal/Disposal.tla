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
(* Code correspondence (abstraction map, not a refinement proof):          *)
(*   HostDispose    Scope.dispose / _disposeNode from a host zone          *)
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
    Callers,  \* host callers of T.dispose()
    Fails,    \* {TRUE}, {FALSE}, or both: whether the cleanup fails
    Fault     \* "none" or one deliberate defect below

Faults == {
    "none",
    "CompleteEarly", \* a repeated call completes before the cleanup ends
    "DisposedShortcut", \* a call after the mark completes before the future
    "ShareFirst",    \* an inner call shares the disposal before the check
    "MarkFirst"      \* a rejected inner call marks its target first
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
    disposalU   \* U's disposal: "none" | "queued"

vars == <<fails, disposalT, release, caller, innerT, innerU, markedU, disposalU>>

TypeOK ==
    /\ fails \in BOOLEAN
    /\ disposalT \in {"none", "queued", "running", "marked", "done"}
    /\ release \in {"idle", "running", "finished"}
    /\ caller \in [Callers -> {"idle", "waiting", "ok", "failed", "noop"}]
    /\ innerT \in {"none", "waiting", "rejected"}
    /\ innerU \in {"none", "rejected"}
    /\ markedU \in BOOLEAN
    /\ disposalU \in {"none", "queued"}

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
    /\ disposalT' = IF disposalT = "none" THEN "queued" ELSE disposalT
    /\ UNCHANGED <<fails, release, innerT, innerU, markedU, disposalU>>

StartTx ==
    /\ disposalT = "queued"
    /\ disposalT' = "running"
    /\ release' = "running"
    /\ UNCHANGED <<fails, caller, innerT, innerU, markedU, disposalU>>

\* The release callback calls T.dispose() inside T's running transaction.
InnerDisposeT ==
    /\ release = "running"
    /\ innerT = "none"
    /\ innerT' = IF Fault = "ShareFirst" THEN "waiting" ELSE "rejected"
    /\ UNCHANGED <<fails, disposalT, release, caller, innerU, markedU, disposalU>>

\* The release callback calls U.dispose() for another target.
InnerDisposeU ==
    /\ release = "running"
    /\ innerU = "none"
    /\ innerU' = "rejected"
    /\ markedU' = (Fault = "MarkFirst")
    /\ UNCHANGED <<fails, disposalT, release, caller, innerT, disposalU>>

\* The release step returns once its own calls have settled; a call that
\* waits for this transaction never settles.
FinishRelease ==
    /\ release = "running"
    /\ innerT # "waiting"
    /\ release' = "finished"
    /\ UNCHANGED <<fails, disposalT, caller, innerT, innerU, markedU, disposalU>>

\* The releases are done: T is marked disposed, the transaction goes on.
MarkDisposed ==
    /\ disposalT = "running"
    /\ release = "finished"
    /\ disposalT' = "marked"
    /\ UNCHANGED <<fails, release, caller, innerT, innerU, markedU, disposalU>>

\* The transaction returns: every waiting caller gets the one result.
FinishTx ==
    /\ disposalT = "marked"
    /\ disposalT' = "done"
    /\ caller' = [c \in Callers |->
                    IF caller[c] = "waiting" THEN Outcome ELSE caller[c]]
    /\ innerT' = IF innerT = "waiting" THEN "rejected" ELSE innerT
    /\ UNCHANGED <<fails, release, innerU, markedU, disposalU>>

Next ==
    \/ \E c \in Callers : HostDispose(c)
    \/ StartTx \/ InnerDisposeT \/ InnerDisposeU \/ FinishRelease
    \/ MarkDisposed \/ FinishTx

Spec == Init /\ [][Next]_vars

FairSpec ==
    Spec /\ WF_vars(StartTx) /\ WF_vars(FinishRelease)
         /\ WF_vars(MarkDisposed) /\ WF_vars(FinishTx)

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

\* Every requested disposal finishes, and every waiting caller completes.
DisposalCompletes ==
    /\ (disposalT \in {"queued", "running"}) ~> (disposalT = "done")
    /\ \A c \in Callers :
         (caller[c] = "waiting") ~> (caller[c] \in {"ok", "failed"})
=============================================================================
