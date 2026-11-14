-------------------------------- MODULE Lazy --------------------------------
(***************************************************************************)
(* Memoized resource holder created by `Component.lazy` and its owner.    *)
(*                                                                         *)
(* One owner component composes a dependency to the left of a Lazy holder. *)
(* Callers invoke Lazy.force concurrently; acquisitions settle in any order *)
(* and may fail. Releasing the owner marks the holder released, waits for *)
(* in-flight acquisition, releases an acquired lease, then releases the   *)
(* dependency (reverse composition order).                                *)
(*                                                                         *)
(* Code correspondence (abstraction map, not a refinement proof):          *)
(*   Force            Lazy.force                (lease.dart)                 *)
(*   AcquireSucceed   Lazy._acquire success                                *)
(*   AcquireFail      Lazy._acquire failure (not cached)                   *)
(*   BeginRelease     holder release starts: Lazy._release sets _released  *)
(*   FinishHolderRelease  Lazy._release after awaiting _pending            *)
(*   ReleaseDep       runCleanups continues to the left-composed lease     *)
(*                                                                         *)
(* Fault selects at most one deliberate defect (negative controls).        *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Callers,      \* concurrent callers of Lazy.force
    MaxAttempts,  \* bound on acquisitions started (host input)
    Fault         \* "none" or one deliberate defect below

Faults == {
    "none",
    "EagerAcquire",        \* acquire during activation, before any force
    "NoMemo",              \* force after success acquires again
    "NoSingleFlight",      \* concurrent first forces start new acquisitions
    "AcquireAfterRelease", \* force after release still acquires
    "SelfRelease",         \* a late acquisition releases itself too
    "DropLease",           \* release forgets acquired leases
    "NoSettleWait",        \* release does not wait for in-flight work
    "WaitForCallers"       \* release waits until callers stop observing
}

ASSUME MaxAttempts \in Nat \ {0}
ASSUME Fault \in Faults

FaultNoSettleWait == Fault = "NoSettleWait"
FaultNoSingleFlight == Fault = "NoSingleFlight"
FaultAcquireAfterRelease == Fault = "AcquireAfterRelease"
FaultSelfRelease == Fault = "SelfRelease"

Attempts == 1..MaxAttempts
CallerStates == {"idle", "waiting", "got", "rejected", "failed"}

VARIABLES
    owner,      \* "active" | "releasing" | "holderDone" | "released"
    released,   \* the holder rejects new acquisition
    attempts,   \* acquisitions started so far
    inflight,   \* attempt ids still acquiring
    succeeded,  \* attempt ids whose acquisition returned a lease
    live,       \* leases owned by the holder and not yet released
    releases,   \* release attempts per attempt id
    caller,     \* per-caller observation of Lazy.force
    dep,        \* lease composed to the left of the holder
    forceCalled,  \* history: some caller invoked force
    lateStart   \* history: an acquisition started after release

vars == <<owner, released, attempts, inflight, succeeded, live, releases,
          caller, dep, forceCalled, lateStart>>

pending == inflight # {}
acquired == live # {}

TypeOK ==
    /\ owner \in {"active", "releasing", "holderDone", "released"}
    /\ released \in BOOLEAN
    /\ attempts \in 0..MaxAttempts
    /\ inflight \subseteq Attempts
    /\ succeeded \subseteq Attempts
    /\ live \subseteq succeeded
    /\ releases \in [Attempts -> 0..2]
    /\ caller \in [Callers -> CallerStates]
    /\ dep \in {"live", "released"}
    /\ forceCalled \in BOOLEAN
    /\ lateStart \in BOOLEAN

Init ==
    /\ owner = "active"
    /\ released = FALSE
    /\ attempts = 0
    /\ inflight = {}
    /\ succeeded = {}
    /\ live = {}
    /\ releases = [i \in Attempts |-> 0]
    /\ caller = [c \in Callers |-> "idle"]
    /\ dep = "live"
    /\ forceCalled = FALSE
    /\ lateStart = FALSE

SetCaller(c, s) == caller' = [caller EXCEPT ![c] = s]

StartAcquisition(c) ==
    /\ attempts < MaxAttempts
    /\ attempts' = attempts + 1
    /\ inflight' = inflight \cup {attempts + 1}
    /\ lateStart' = (lateStart \/ released)
    /\ SetCaller(c, "waiting")

Force(c) ==
    /\ caller[c] = "idle"
    /\ forceCalled' = TRUE
    /\ \/ /\ released /\ ~FaultAcquireAfterRelease
          /\ SetCaller(c, "rejected")
          /\ UNCHANGED <<attempts, inflight, lateStart>>
       \/ /\ ~released /\ acquired /\ Fault # "NoMemo"
          /\ SetCaller(c, "got")
          /\ UNCHANGED <<attempts, inflight, lateStart>>
       \/ /\ ~released /\ acquired /\ Fault = "NoMemo" /\ ~pending
          /\ StartAcquisition(c)
       \/ /\ ~released \/ FaultAcquireAfterRelease
          /\ ~acquired
          /\ pending /\ ~FaultNoSingleFlight
          /\ SetCaller(c, "waiting")
          /\ UNCHANGED <<attempts, inflight, lateStart>>
       \/ /\ ~released \/ FaultAcquireAfterRelease
          /\ ~acquired
          /\ ~pending \/ FaultNoSingleFlight
          /\ StartAcquisition(c)
    /\ UNCHANGED <<owner, released, succeeded, live, releases, dep>>

\* Defect: acquisition begins as part of activation.
EagerStart ==
    /\ Fault = "EagerAcquire"
    /\ owner = "active" /\ attempts = 0
    /\ attempts' = 1
    /\ inflight' = {1}
    /\ UNCHANGED <<owner, released, succeeded, live, releases, caller, dep,
                   forceCalled, lateStart>>

\* Waiting callers share the settled future.
Settle(outcome) ==
    caller' = [c \in Callers |->
                 IF caller[c] = "waiting" THEN outcome ELSE caller[c]]

AcquireSucceed(i) ==
    /\ i \in inflight
    /\ inflight' = inflight \ {i}
    /\ succeeded' = succeeded \cup {i}
    \* Ownership stays with the holder until FinishHolderRelease.
    /\ live' = live \cup {i}
    /\ releases' = IF FaultSelfRelease /\ released
                     THEN [releases EXCEPT ![i] = @ + 1]
                     ELSE releases
    /\ Settle(IF released THEN "rejected" ELSE "got")
    /\ UNCHANGED <<owner, released, attempts, dep, forceCalled, lateStart>>

\* A failure reaches waiting callers and is not cached.
AcquireFail(i) ==
    /\ i \in inflight
    /\ inflight' = inflight \ {i}
    /\ Settle("failed")
    /\ UNCHANGED <<owner, released, attempts, succeeded, live, releases, dep,
                   forceCalled, lateStart>>

\* A caller may observe its result and call force again.
Reset(c) ==
    /\ caller[c] \in {"got", "rejected", "failed"}
    /\ SetCaller(c, "idle")
    /\ UNCHANGED <<owner, released, attempts, inflight, succeeded, live,
                   releases, dep, forceCalled, lateStart>>

BeginRelease ==
    /\ owner = "active"
    /\ owner' = "releasing"
    /\ released' = TRUE
    /\ UNCHANGED <<attempts, inflight, succeeded, live, releases, caller, dep,
                   forceCalled, lateStart>>

FinishHolderRelease ==
    /\ owner = "releasing"
    /\ ~pending \/ FaultNoSettleWait
    /\ Fault = "WaitForCallers" => \A c \in Callers : caller[c] = "idle"
    /\ releases' = IF Fault = "DropLease" THEN releases
                   ELSE [i \in Attempts |->
                           IF i \in live THEN releases[i] + 1 ELSE releases[i]]
    /\ live' = {}
    /\ owner' = "holderDone"
    /\ UNCHANGED <<released, attempts, inflight, succeeded, caller, dep,
                   forceCalled, lateStart>>

ReleaseDep ==
    /\ owner = "holderDone"
    /\ dep' = "released"
    /\ owner' = "released"
    /\ UNCHANGED <<released, attempts, inflight, succeeded, live, releases,
                   caller, forceCalled, lateStart>>

Next ==
    \/ \E c \in Callers : Force(c) \/ Reset(c)
    \/ \E i \in Attempts : AcquireSucceed(i) \/ AcquireFail(i)
    \/ EagerStart
    \/ BeginRelease
    \/ FinishHolderRelease
    \/ ReleaseDep

Spec == Init /\ [][Next]_vars

\* Liveness assumptions: callbacks settle and runtime cleanup steps run.
FairSpec ==
    /\ Spec
    /\ WF_vars(\E i \in Attempts : AcquireSucceed(i) \/ AcquireFail(i))
    /\ WF_vars(FinishHolderRelease)
    /\ WF_vars(ReleaseDep)

-----------------------------------------------------------------------------
(* Safety properties (R-UC-RT-LC-007 unless noted).                        *)

AcquireOnlyOnUse == attempts > 0 => forceCalled

SingleFlight == Cardinality(inflight) <= 1

AtMostOneSuccess == Cardinality(succeeded) <= 1

NoAcquireAfterRelease == ~lateStart

\* R-UC-RT-LC-002: one release attempt per lease.
ReleaseAtMostOnce == \A i \in Attempts : releases[i] <= 1

\* Release order: the holder's lease and in-flight work before the dependency.
DependentFirst == dep = "released" => (live = {} /\ inflight = {})

\* After the owner is released, every acquired lease was released exactly once.
LeaseAccounted ==
    owner = "released" => (live = {} /\ \A i \in succeeded : releases[i] = 1)

\* Liveness: a started release finishes under the fairness assumptions.
ReleaseCompletes == (owner = "releasing") ~> (owner = "released")

=============================================================================
