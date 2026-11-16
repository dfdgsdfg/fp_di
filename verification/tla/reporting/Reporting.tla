------------------------------ MODULE Reporting ------------------------------
(***************************************************************************)
(* Delivery of failures: which error reaches which caller.                 *)
(*                                                                         *)
(* Release attempts are counted by the other models. This one tracks what  *)
(* is reported: each failed release is a dispose failure with an identity, *)
(* each failed creation keeps its cause, and the model records the errors  *)
(* that reach a caller (the initialize result, the force result, the       *)
(* dispose result).                                                        *)
(*                                                                         *)
(* Path "members": independent members of one initialize run at once; any *)
(* may fail, and the release of any acquired lease may fail. The call      *)
(* rethrows the first failed creation in declaration order with every      *)
(* dispose failure.                                                        *)
(*                                                                         *)
(* Path "lazy": a Lazy creation acquires a lease, then its second step may *)
(* fail; the owner's release may begin at any time. A failed creation      *)
(* reaches force with its cause and dispose failures, or, after the        *)
(* release began, force gets DisposedLazy and the dispose failures join    *)
(* the owner's dispose result.                                             *)
(*                                                                         *)
(* Code correspondence (abstraction map, not a refinement proof):          *)
(*   FinishMember     _Runtime.activate success or failure path            *)
(*   Deliver          activateMembers returns the member causes; initialize*)
(*                    adds the dispose failures of deactivation and throws *)
(*                    RuntimeCause.activationError (scope.dart,            *)
(*                    runtime_cause.dart)                                  *)
(*   Acquire, Fail    a Lazy creation in createDeferred (dependency.dart)  *)
(*   BeginShutdown    Lazy._release (lease.dart)                           *)
(*   FinishShutdown   Lazy._release throws DisposeException                *)
(*                                                                         *)
(* Fault selects at most one deliberate defect (negative controls).        *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Path,     \* "members" | "lazy"
    Members,  \* declaration order 1..N, for Path = "members"
    Fault     \* "none" or one deliberate defect below

Faults == {
    "none",
    "DropLater",          \* only the first failed member's dispose failures
                          \* are kept
    "DisposeFailureReplacesCause",
                          \* a dispose failure replaces the creation cause
    "SwallowShutdown",    \* dispose failures of a creation that settles
                          \* after the owner's release began are dropped
    "MisrouteShutdown",   \* those dispose failures go to force, not to dispose
    "DisposedEarly",      \* a failure before the release is reported as
                          \* DisposedLazy
    "NoDeliver"           \* the members' result is never delivered
}

ASSUME Fault \in Faults
ASSUME Path \in {"members", "lazy"}
ASSUME Members \subseteq Nat \ {0}

NoCause == "none"  \* lazy causes are strings; member causes are member numbers
Min(S) == CHOOSE x \in S : \A y \in S : x <= y

VARIABLES
    releaseFails, \* [ids -> BOOLEAN] which releases fail (chosen up front)
    st,           \* members: [Members -> "run" | "ok" | "failed"]
    lz,           \* lazy: "idle" | "acquired" | "created" | "failed"
    shutdown,     \* lazy: "none" | "begun" | "done"
    pending,      \* lazy: dispose failures kept for the owner's release
    settledLate,  \* lazy ghost: the creation settled after the release began
    delivered     \* the errors that reached callers: a set of records

vars == <<releaseFails, st, lz, shutdown, pending, settledLate, delivered>>

Ids == IF Path = "members" THEN Members ELSE {1}

Init ==
    /\ releaseFails \in [Ids -> BOOLEAN]
    /\ st = [m \in Members |-> "run"]
    /\ lz = "idle"
    /\ shutdown = "none"
    /\ pending = {}
    /\ settledLate = FALSE
    /\ delivered = {}

(***************************************************************************)
(* Path "members"                                                          *)
(***************************************************************************)
Failed == {m \in Members : st[m] = "failed"}

\* Dispose failures of a member's own rollback (it failed) or of its
\* deactivation in
\* the call's rollback (it committed): either way its lease is released.
DisposeFailureOf(m) == IF releaseFails[m] THEN {m} ELSE {}

FinishMember(m) ==
    /\ Path = "members"
    /\ st[m] = "run"
    /\ st' \in {[st EXCEPT ![m] = "ok"], [st EXCEPT ![m] = "failed"]}
    /\ UNCHANGED <<releaseFails, lz, shutdown, pending, delivered, settledLate>>

\* Every member settled and one failed: the call rethrows.
Deliver ==
    /\ Path = "members"
    /\ \A m \in Members : st[m] # "run"
    /\ Failed # {}
    /\ delivered = {}
    /\ Fault # "NoDeliver"
    /\ LET first == Min(Failed)
           own == IF Fault = "DropLater"
                  THEN DisposeFailureOf(first)
                  ELSE UNION {DisposeFailureOf(m) : m \in Failed}
           deactivation ==
               UNION {DisposeFailureOf(m) : m \in Members \ Failed}
       IN delivered' = {[to |-> "initialize", cause |-> first,
                         disposeFailures |-> own \cup deactivation]}
    /\ UNCHANGED <<releaseFails, st, lz, shutdown, pending, settledLate>>

(***************************************************************************)
(* Path "lazy"                                                             *)
(***************************************************************************)
\* force starts a creation only before the owner's release began; after it,
\* Lazy.force throws DisposedLazyException without creating.
Acquire ==
    /\ Path = "lazy"
    /\ lz = "idle"
    /\ shutdown = "none"
    /\ lz' = "acquired"
    /\ UNCHANGED <<releaseFails, st, shutdown, pending, delivered, settledLate>>

Succeed ==
    /\ Path = "lazy"
    /\ lz = "acquired"
    /\ lz' = "created"
    /\ settledLate' = (shutdown # "none")
    /\ delivered' = delivered \cup
         IF shutdown = "none"
         THEN {[to |-> "force", cause |-> NoCause, disposeFailures |-> {}]}
         ELSE {[to |-> "force", cause |-> "disposedLazy",
                disposeFailures |-> {}]}
    /\ UNCHANGED <<releaseFails, st, shutdown, pending>>

\* The second step fails with cause 2; the rollback releases the lease.
Fail ==
    /\ Path = "lazy"
    /\ lz = "acquired"
    /\ lz' = "failed"
    /\ settledLate' = (shutdown # "none")
    /\ LET disposeFailures == DisposeFailureOf(1)
       IN IF shutdown = "none"
          THEN /\ delivered' = delivered \cup
                  {[to |-> "force",
                    cause |-> CASE (Fault = "DisposeFailureReplacesCause" /\
                                    disposeFailures # {})
                                     -> NoCause
                                [] Fault = "DisposedEarly" -> "disposedLazy"
                                [] OTHER -> "secondStep",
                    disposeFailures |-> IF Fault = "DisposedEarly"
                                        THEN {} ELSE disposeFailures]}
               /\ UNCHANGED pending
          ELSE /\ delivered' = delivered \cup
                  {[to |-> "force", cause |-> "disposedLazy",
                    disposeFailures |-> IF Fault = "MisrouteShutdown"
                                        THEN disposeFailures ELSE {}]}
               /\ pending' = IF Fault \in {"SwallowShutdown", "MisrouteShutdown"}
                             THEN pending ELSE pending \cup disposeFailures
    /\ UNCHANGED <<releaseFails, st, shutdown>>

BeginShutdown ==
    /\ Path = "lazy"
    /\ shutdown = "none"
    /\ shutdown' = "begun"
    /\ UNCHANGED <<releaseFails, st, lz, pending, delivered, settledLate>>

\* The release waits for the creation to settle, releases a created value,
\* and throws the dispose failures it collected.
FinishShutdown ==
    /\ Path = "lazy"
    /\ shutdown = "begun"
    /\ lz \in {"idle", "created", "failed"}
    /\ shutdown' = "done"
    /\ LET own == IF lz = "created" THEN DisposeFailureOf(1) ELSE {}
       IN delivered' = delivered \cup
            {[to |-> "dispose", cause |-> NoCause,
              disposeFailures |-> pending \cup own]}
    /\ UNCHANGED <<releaseFails, st, lz, pending, settledLate>>

Next ==
    \/ \E m \in Members : FinishMember(m)
    \/ Deliver
    \/ Acquire \/ Succeed \/ Fail \/ BeginShutdown \/ FinishShutdown

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)
TypeOK ==
    /\ releaseFails \in [Ids -> BOOLEAN]
    /\ lz \in {"idle", "acquired", "created", "failed"}
    /\ shutdown \in {"none", "begun", "done"}

ReportedDisposeFailures == UNION {d.disposeFailures : d \in delivered}

\* The outcome is fixed: every member settled, or the creation settled and
\* the release finished (or never began).
Settled ==
    \/ Path = "members" /\ \A m \in Members : st[m] # "run"
    \/ /\ Path = "lazy"
       /\ lz \in {"idle", "created", "failed"}
       /\ shutdown \in {"none", "done"}

\* The record that each recipient must receive, from the fixed outcome.
ExpectedInitialize ==
    [to |-> "initialize", cause |-> Min(Failed),
     disposeFailures |-> {m \in Members : releaseFails[m]}]

ExpectedForce ==
    CASE lz = "created" /\ ~settledLate ->
           [to |-> "force", cause |-> NoCause, disposeFailures |-> {}]
      [] lz = "failed" /\ ~settledLate ->
           [to |-> "force", cause |-> "secondStep",
            disposeFailures |-> DisposeFailureOf(1)]
      [] OTHER -> [to |-> "force", cause |-> "disposedLazy",
                   disposeFailures |-> {}]

\* The owner's release reports the release of a created value and the
\* rollback failures of a creation that settled after it began.
ExpectedDispose ==
    [to |-> "dispose", cause |-> NoCause,
     disposeFailures |-> IF lz = "created" \/ (lz = "failed" /\ settledLate)
                THEN DisposeFailureOf(1) ELSE {}]

\* Each delivered record is exactly the one its recipient must receive, and
\* a recipient receives at most one.
RecipientsExact ==
    /\ \A d \in delivered :
         /\ d.to = "initialize" => d = ExpectedInitialize
         /\ d.to = "force" => d = ExpectedForce
         /\ d.to = "dispose" => d = ExpectedDispose
    /\ \A d1, d2 \in delivered : d1.to = d2.to => d1 = d2

\* The results that must exist once the outcome is settled.
Delivered ==
    /\ Path = "members" /\ Failed # {} =>
         \E d \in delivered : d.to = "initialize"
    /\ Path = "lazy" /\ lz \in {"created", "failed"} =>
         \E d \in delivered : d.to = "force"
    /\ Path = "lazy" /\ shutdown = "done" =>
         \E d \in delivered : d.to = "dispose"

\* Every release that ran and failed reaches some caller, once every
\* result is delivered.
NoLostDisposeFailure ==
    (Settled /\ Delivered) =>
        \A id \in Ids :
            (/\ releaseFails[id]
             /\ \/ Path = "members" /\ Failed # {}
                \* The release ran: the rollback of a failed creation, or
                \* the owner's release of a created value.
                \/ Path = "lazy" /\ lz = "failed"
                \/ Path = "lazy" /\ lz = "created" /\ shutdown = "done")
            => id \in ReportedDisposeFailures

\* The reported failure keeps its cause: the first failed member, or the
\* creation's own cause unless the creation settled after the release began.
CausePreserved ==
    \A d \in delivered :
        /\ d.to = "initialize" => d.cause = Min(Failed)
        /\ (d.to = "force" /\ lz = "failed")
             => d.cause = IF settledLate THEN "disposedLazy" ELSE "secondStep"

\* Liveness: once settled, every result is eventually delivered.
ReportingCompletes == <>[](Settled => Delivered)

Fairness ==
    /\ WF_vars(Deliver) /\ WF_vars(Succeed \/ Fail) /\ WF_vars(FinishShutdown)
    /\ \A m \in Members : WF_vars(FinishMember(m))

FairSpec == Spec /\ Fairness
=============================================================================
