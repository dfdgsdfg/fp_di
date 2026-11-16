---------------------------- MODULE Initialize ------------------------------
(***************************************************************************)
(* One call of `Scope.initialize`: concurrent activation of the members    *)
(* of one scope, member failure, rollback, and the closing reconciliation. *)
(*                                                                         *)
(* Scope S (the initialized scope) declares members 1..NM in declaration   *)
(* order. A child scope of S holds the descendant nodes NM+1..NM+ND, which *)
(* already exist and wait (dormant) for keys that members of S publish.    *)
(* Module shapes are constants that already passed the DuplicateKeyError   *)
(* and UndeclaredKeyError checks, so the model has no duplicate-key path.  *)
(* Keys are the only order between members; there is no `ordered` flag.    *)
(*                                                                         *)
(* Code correspondence (abstraction map, not a refinement proof):          *)
(*   Create          Scope.initialize: createNode for every member         *)
(*   Start           activateMembers: start(index) from pump               *)
(*                   (Ready = all prerequisites settled; CycleStart =      *)
(*                   the `inFlight == 0 && unstarted > 0` fallback)        *)
(*   Acquire         _RuntimeContext.acquire: lease added to cleanups      *)
(*   Commit          _Runtime.activate success: bindings staged then       *)
(*                   committed together, cleanups move to the node         *)
(*   Fail            _Runtime.activate catch: runCleanups(cleanups.reversed)*)
(*   EndSched        activateMembers returns an empty cause (all settled)  *)
(*   BeginRollback   activateMembers returns the causes after every start  *)
(*                   settled; initialize rolls back on a non-empty cause   *)
(*   ReconBegin/Done Scope.initialize reconcile(sink: ...): one dormant     *)
(*                   node at a time, ascending id; a failed member goes to *)
(*                   the sink, a failed descendant node is only reported   *)
(*   RbStep          the catch block: deactivate(node, permanent: true) for*)
(*                   nodes.reversed; deactivate releases dependents first  *)
(*   RbDone/ReconDone the reconcile() after the rollback                   *)
(*   Rebuild         _Runtime.reconcile -> _rebuildChanged: an active node *)
(*                   of a descendant scope whose resolved publishers       *)
(*                   changed (_targetChanged) is deactivated, then wakes   *)
(*                   again as a second episode in _activateDormant         *)
(*   StartLate       an acquire/publish that escaped its activation        *)
(*                   context: _RuntimeContext.acquire passed               *)
(*                   _ensureActivating and awaits createLease              *)
(*   LandLease       acquire resumes after the episode closed: the         *)
(*                   `if (!_activating)` branch disposes the lease once    *)
(*                   and throws; it never reaches cleanups.add             *)
(*   LateStage       publish/contribute from a closed context:             *)
(*                   _ensureActivating throws, so nothing is staged        *)
(*   Stage           publish/contribute in the open episode: staged.add    *)
(*                                                                         *)
(* Abstraction choices:                                                    *)
(*   - A step of the model is one await boundary of the Dart code. A       *)
(*     deactivation (all releases of one node) is one atomic step, because *)
(*     the mutation queue serializes it and no other work overlaps it.     *)
(*   - Activation outcomes are opaque: each step may acquire a lease or    *)
(*     the whole activation may fail after k acquisitions.                 *)
(*   - A member has one activation episode per call. A descendant node can *)
(*     have more: the episode it carried into the call (`Pre`, active      *)
(*     against an ancestor publisher), a rebuild episode, and an episode   *)
(*     after the rollback. Lease tokens are <<call, node, episode, step>>. *)
(*   - Staleness is modeled for descendant nodes only. A member that       *)
(*     observes a key that a later member publishes (the `Wake` cycle) is  *)
(*     rebuilt in the Dart code until the pass bound; Reconcile.tla owns   *)
(*     that feedback (`UnsettledFailsInit`), so no member is rebuilt here. *)
(*   - `Anc` keys come from an ancestor scope and stay available. A member *)
(*     that publishes an `Anc` key shadows it for the descendant scope.    *)
(*   - An escaped activation context (`Late` requests) is an environment   *)
(*     action. The runtime must reject it, and `ClosedActivation` states  *)
(*     that contract. The guard `_activating` reads node state, so it does *)
(*     not by itself reject a closed but still registered episode. No      *)
(*     public API hands a context to user code, so no Dart test reaches it.*)
(*   - Not modeled: cancellation, disposal, cleanup (release) failures,    *)
(*     DiChange listeners.                                                 *)
(*   - Reconcile picks the next eligible node nondeterministically; the    *)
(*     Dart code takes ascending id passes (a subset of these orders).     *)
(*                                                                         *)
(* Fault selects at most one deliberate defect (negative controls).        *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    NM,         \* members of the initialized scope, in declaration order
    ND,         \* nodes of a descendant scope (ids follow the members)
    MaxCalls,   \* initialize calls: a failed call may be retried
    MaxSteps,   \* upper bound on leases of one activation
    Steps,      \* tuple: acquisition steps of the activation of each node
    Key,        \* tuple: key published by each node (0 = none)
    Reads,      \* tuple of sets: keys read (required or optional)
    Req,        \* tuple of sets: required keys, a subset of Reads
    Anc,        \* keys that an ancestor scope publishes (always available)
    Pre,        \* descendant nodes already active against Anc at the call
    Late,       \* bound on escaped requests to a closed or stale episode
    Fault       \* "none" or one deliberate defect below

Faults == {
    "none",
    "EarlyRollback",      \* rollback starts while a sibling is in flight
    "PublishEarly",       \* binding visible before the activation completes
    "AcqOrder",           \* leases released in acquisition order
    "EarlyStart",         \* a member starts before its publisher settled
    "StartAfterFailure",  \* a ready member still starts after a failure
    "SkipDependents",     \* rollback releases a publisher before its dependents
    "DoubleRelease",      \* rollback releases a failed member's leases again
    "DropLease",          \* a failed member forgets its acquired leases
    "DeclOrder",          \* rollback in declaration order
    "RethrowEarliest",    \* rethrow the earliest failure in time
    "SkipRebuild",        \* the closing reconcile leaves a stale node active
    "ReleaseRebuilt",     \* rollback releases a rebuilt node's old leases again
    "RebuildLosesEdge",   \* a rebuilt node's new dependency edge is lost
    "MutateAfterClose",   \* a lease that lands after closure joins the node
    "StageAfterClose",    \* a closed episode stages new work
    "LateLeak"            \* a lease that lands after closure is never released
}

Members == 1..NM
Desc == (NM + 1)..(NM + ND)
Nodes == 1..(NM + ND)
Calls == 1..MaxCalls
LeaseIds == 1..MaxSteps
LateId == MaxSteps + 1           \* the lease of an escaped acquire request
AllIds == 1..LateId
KeyDom == 1..3
EpDom == 1..4                    \* carried-over, rebuild, after rollback
RelDom == (0..MaxCalls) \X Nodes \X EpDom \X AllIds

ASSUME NM \in 1..3 /\ ND \in 0..2 /\ MaxCalls \in 1..2 /\ MaxSteps \in 1..3
ASSUME Fault \in Faults
ASSUME Steps \in [Nodes -> 0..MaxSteps]
ASSUME Key \in [Nodes -> 0..3]
ASSUME Reads \in [Nodes -> SUBSET KeyDom]
ASSUME Req \in [Nodes -> SUBSET KeyDom]
ASSUME Anc \subseteq KeyDom /\ Pre \subseteq Desc /\ Late \in 0..3
ASSUME \A n \in Nodes : Req[n] \subseteq Reads[n]
\* Distinct keys, as initialize guarantees (DuplicateKeyError).
ASSUME \A m1, m2 \in Members :
           (m1 # m2 /\ Key[m1] # 0) => Key[m1] # Key[m2]
\* A component never reads its own publication.
ASSUME \A m \in Members : Key[m] \notin Reads[m]
\* Descendant nodes publish nothing and start dormant.
ASSUME \A d \in Desc : Key[d] = 0 /\ Req[d] # {}
\* A node active at the start of the call has its requirements from Anc.
ASSUME \A d \in Pre : Req[d] \subseteq Anc

\* Module shapes for the scenarios (selected by `<-` in each configuration).
\* "Parallel": member 1 reads the key of the later member 2 (a forward
\* reference); member 3 is independent of both and can fail while they run.
StepsParallel == <<2, 2, 1>>
StepsParallelWide == <<2, 2, 2>>
KeyParallel   == <<1, 2, 0>>
ReadsParallel == <<{2}, {}, {}>>
ReqParallel   == <<{2}, {}, {}>>
\* "Wake": members 1 and 2 form a cycle (1 requires key 2, 2 observes key 1),
\* so member 1 first activates in the closing reconcile. Node 3 belongs to a
\* descendant scope and requires key 2.
StepsWake == <<1, 1, 1>>
StepsWakeWide == <<2, 2, 2>>
KeyWake   == <<1, 2, 0>>
ReadsWake == <<{2}, {1}, {2}>>
ReqWake   == <<{2}, {}, {2}>>

\* "Rebuild": the Wake cycle among members 1 and 3 (1 requires key 3, 3 observes
\* key 1), and member 2, which publishes key 2 and commits while the cycle
\* waits. Node 4 of a descendant scope requires key 2, which the ancestor also
\* publishes. It is active against the ancestor when the call starts, so the
\* commit of member 2 makes it stale. The closing reconcile rebuilds it, and
\* member 1 can fail there, which rolls the call back.
StepsRebuild == <<1, 1, 1, 1>>
StepsRebuildWide == <<1, 2, 1, 2>>
KeyRebuild   == <<1, 2, 3, 0>>
ReadsRebuild == <<{3}, {}, {1}, {2}>>
ReqRebuild   == <<{3}, {}, {}, {2}>>
AncRebuild   == {2}
PreRebuild   == {4}

Min(S) == CHOOSE x \in S : \A y \in S : x <= y
Max(S) == CHOOSE x \in S : \A y \in S : y <= x

Phases == {"declared", "sched", "recon", "rollback", "rbRecon", "ok", "failed"}
Running == {"sched", "recon", "rollback", "rbRecon"}

VARIABLES
    phase,      \* progress of the current initialize call
    calls,      \* initialize calls started
    nst,        \* "none" (unregistered) | "idle" | "run" | "act"
    held,       \* lease ids acquired and not released, per node
    own,        \* owner of the held leases: "act" (activation) | "node"
    acq,        \* lease ids acquired in the node's episode (history)
    rel,        \* release attempts per lease token <<call, node, id>>
    relSeq,     \* release order of the node's leases in its episode
    started,    \* members whose activation was started
    viaCycle,   \* members started by the cycle fallback
    failed,     \* members whose activation failed in this call
    failSeq,    \* the same members in the order of failure
    rfail,      \* nodes that failed in the current reconcile
    pubs,       \* visible bindings <<call, node>>
    deps,       \* members each node read from (dependency edges)
    thrown,     \* member whose failure initialize rethrows (0 = none)
    rbLog,      \* nodes in the order the rollback deactivated them
    lateStart,  \* members started after a failure (history)
    ep,         \* activation episodes the node began in this call (1 = carried)
    rebuilt,    \* nodes the closing reconcile rebuilt in this call
    stg,        \* staged work <<node, episode>> of an open episode
    pend,       \* episode of the escaped acquire in flight per node (0 = none)
    lacq,       \* escaped acquires started in this call <<node, episode>>
    reqs        \* escaped requests issued in this call

vars == <<phase, calls, nst, held, own, acq, rel, relSeq, started, viaCycle,
          failed, failSeq, rfail, pubs, deps, thrown, rbLog, lateStart,
          ep, rebuilt, stg, pend, lacq, reqs>>
epV == <<ep>>
lateV == <<rebuilt, stg, pend, lacq, reqs>>
newV == <<ep, rebuilt, stg, pend, lacq, reqs>>

-----------------------------------------------------------------------------
(* Derived state *)

Flight == {m \in Members : nst[m] = "run"}
Settled == {m \in started : nst[m] # "run"}
ActiveSet == {n \in Nodes : nst[n] = "act"}

\* Members whose key a node reads: the scheduling dependencies.
Prereq(m) == {p \in Members : p # m /\ Key[p] # 0 /\ Key[p] \in Reads[m]}

\* A required key resolves to an ancestor key or a visible binding of another
\* member (a member binding is nearer than an ancestor one).
Sat(n) == \A k \in Req[n] :
              \/ k \in Anc
              \/ \E p \in Members : p # n /\ Key[p] = k /\ <<calls, p>> \in pubs

\* Members whose bindings a starting node reads.
Seen(n) == {p \in Members : p # n /\ Key[p] # 0 /\ Key[p] \in Reads[n]
                            /\ <<calls, p>> \in pubs}

Ready(m) == m \notin started /\ Prereq(m) \subseteq Settled
CycleStart == /\ Flight = {}
              /\ started # Members
              /\ ~(\E m \in Members : Ready(m))
CycleMin == Min(Members \ started)

\* The pump of activateMembers runs at once, so no other step interleaves
\* with it while it has something to start.
PumpPending == /\ phase = "sched"
               /\ failed = {}
               /\ started # Members
               /\ ((\E m \in Members : Ready(m)) \/ CycleStart)

Eligible(n) == /\ nst[n] = "idle"
               /\ n \notin rfail
               /\ Sat(n)

AnyRun == \E n \in Nodes : nst[n] = "run"
AllLanded == \A n \in Nodes : pend[n] = 0

\* An active node of a descendant scope reads another publisher than the
\* one it committed against (_targetChanged).
Stale(d) == /\ d \in Desc
            /\ nst[d] = "act"
            /\ Seen(d) # deps[d]

\* The edge of a rebuilt node is registered on its new publisher, except
\* under the RebuildLosesEdge defect.
ActDeps(n) == {d \in Nodes : /\ nst[d] = "act"
                             /\ n \in deps[d]
                             /\ ~(Fault = "RebuildLosesEdge" /\ d \in rebuilt)}
RECURSIVE Leaf(_)
\* The node that deactivate(n) releases first: dependents go before n.
Leaf(n) == IF ActDeps(n) = {} THEN n ELSE Leaf(Max(ActDeps(n)))

Reg == {m \in Members : nst[m] # "none"}

RelOrder(k) == IF Fault = "AcqOrder" THEN [i \in 1..k |-> i]
                                     ELSE [i \in 1..k |-> k + 1 - i]

Closure1(S) == S \cup UNION {deps[x] : x \in S}
Reach(a) == Closure1(Closure1(Closure1(deps[a])))

-----------------------------------------------------------------------------
TypeOK ==
    /\ phase \in Phases
    /\ calls \in 0..MaxCalls
    /\ nst \in [Nodes -> {"none", "idle", "run", "act"}]
    /\ held \in [Nodes -> SUBSET AllIds]
    /\ own \in [Nodes -> {"act", "node"}]
    /\ acq \in [Nodes -> SUBSET LeaseIds]
    /\ rel \in [RelDom -> 0..2]
    /\ \A n \in Nodes : Len(relSeq[n]) <= 2 * MaxSteps
                        /\ \A i \in 1..Len(relSeq[n]) : relSeq[n][i] \in LeaseIds
    /\ started \subseteq Members
    /\ viaCycle \subseteq Members
    /\ failed \subseteq Members
    /\ Len(failSeq) <= NM
    /\ \A i \in 1..Len(failSeq) : failSeq[i] \in Members
    /\ rfail \subseteq Nodes
    /\ pubs \subseteq (Calls \X Nodes)
    /\ deps \in [Nodes -> SUBSET Members]
    /\ thrown \in 0..NM
    /\ Len(rbLog) <= NM + ND
    /\ \A i \in 1..Len(rbLog) : rbLog[i] \in Nodes
    /\ lateStart \subseteq Members
    /\ ep \in [Nodes -> 0..4]
    /\ rebuilt \subseteq Desc
    /\ stg \subseteq (Nodes \X EpDom)
    /\ pend \in [Nodes -> 0..4]
    /\ lacq \subseteq (Nodes \X EpDom)
    /\ reqs \in 0..Late

Init ==
    /\ phase = "declared"
    /\ calls = 0
    /\ nst = [n \in Nodes |->
                IF n \in Pre THEN "act"
                ELSE IF n \in Desc THEN "idle" ELSE "none"]
    /\ held = [n \in Nodes |-> IF n \in Pre THEN 1..Steps[n] ELSE {}]
    /\ own = [n \in Nodes |-> IF n \in Pre THEN "node" ELSE "act"]
    /\ acq = [n \in Nodes |-> IF n \in Pre THEN 1..Steps[n] ELSE {}]
    /\ rel = [t \in RelDom |-> 0]
    /\ relSeq = [n \in Nodes |-> <<>>]
    /\ started = {}
    /\ viaCycle = {}
    /\ failed = {}
    /\ failSeq = <<>>
    /\ rfail = {}
    /\ pubs = {}
    /\ deps = [n \in Nodes |-> {}]
    /\ thrown = 0
    /\ rbLog = <<>>
    /\ lateStart = {}
    /\ ep = [n \in Nodes |-> IF n \in Pre THEN 1 ELSE 0]
    /\ rebuilt = {}
    /\ stg = {}
    /\ pend = [n \in Nodes |-> 0]
    /\ lacq = {}
    /\ reqs = 0

\* Release attempts of the given lease tokens, in the configured order.
ReleaseWith(n, toks) ==
    /\ held' = [held EXCEPT ![n] = {}]
    /\ rel' = [t \in RelDom |-> IF t \in toks THEN rel[t] + 1 ELSE rel[t]]
    /\ relSeq' = [relSeq EXCEPT ![n] = RelOrder(Cardinality(held[n]))]

\* Releases every held lease of n in the configured order.
ReleaseUpd(n) == ReleaseWith(n, {<<calls, n, ep[n], i>> : i \in held[n]})

\* A node starts an activation episode whose requirements hold.
BeginRun(n) ==
    /\ nst' = [nst EXCEPT ![n] = "run"]
    /\ acq' = [acq EXCEPT ![n] = {}]
    /\ held' = [held EXCEPT ![n] = {}]
    /\ own' = [own EXCEPT ![n] = "act"]
    /\ relSeq' = [relSeq EXCEPT ![n] = <<>>]
    /\ deps' = [deps EXCEPT ![n] = Seen(n)]
    /\ ep' = [ep EXCEPT ![n] = @ + 1]

-----------------------------------------------------------------------------
\* A new call starts a new episode for every node that is not active.
Fresh(n) == n \in Members \/ nst[n] # "act"

(* Create the nodes of every member in declaration order. *)
Create ==
    /\ phase \in {"declared", "failed"}
    /\ calls < MaxCalls
    /\ AllLanded
    /\ calls' = calls + 1
    /\ phase' = "sched"
    /\ nst' = [n \in Nodes |-> IF n \in Members THEN "idle" ELSE nst[n]]
    /\ held' = [n \in Nodes |-> IF Fresh(n) THEN {} ELSE held[n]]
    /\ own' = [n \in Nodes |-> IF Fresh(n) THEN "act" ELSE own[n]]
    /\ acq' = [n \in Nodes |-> IF Fresh(n) THEN {} ELSE acq[n]]
    /\ relSeq' = [n \in Nodes |-> IF Fresh(n) THEN <<>> ELSE relSeq[n]]
    /\ deps' = [n \in Nodes |-> IF Fresh(n) THEN {} ELSE deps[n]]
    /\ ep' = [n \in Nodes |-> IF Fresh(n) THEN 0 ELSE 1]
    /\ started' = {}
    /\ viaCycle' = {}
    /\ failed' = {}
    /\ failSeq' = <<>>
    /\ rfail' = {}
    /\ thrown' = 0
    /\ rbLog' = <<>>
    /\ lateStart' = {}
    /\ rebuilt' = {}
    /\ stg' = {}
    /\ lacq' = {}
    /\ reqs' = 0
    /\ UNCHANGED <<rel, pubs, pend>>

(* A member starts when its publishers settled; a dormant one settles. *)
Start(m) ==
    /\ phase = "sched"
    /\ m \notin started
    /\ \/ /\ failed = {} /\ Ready(m)
          /\ viaCycle' = viaCycle
       \/ /\ failed = {} /\ CycleStart /\ m = CycleMin
          /\ viaCycle' = viaCycle \cup {m}
       \/ /\ Fault = "EarlyStart" /\ failed = {}
          /\ viaCycle' = viaCycle
       \/ /\ Fault = "StartAfterFailure" /\ failed # {} /\ Ready(m)
          /\ viaCycle' = viaCycle
    /\ started' = started \cup {m}
    /\ lateStart' = IF failed # {} THEN lateStart \cup {m} ELSE lateStart
    /\ IF Sat(m)
         THEN BeginRun(m)
         ELSE UNCHANGED <<nst, acq, held, own, relSeq, deps, epV>>
    /\ UNCHANGED <<phase, calls, rel, failed, failSeq, rfail, pubs, thrown,
                   rbLog, lateV>>

(* Each owned step of the Dependency chain acquires one lease. *)
Acquire(n) ==
    /\ nst[n] = "run"
    /\ ~PumpPending
    /\ Cardinality(acq[n]) < Steps[n]
    /\ LET s == Cardinality(acq[n]) + 1
       IN /\ acq' = [acq EXCEPT ![n] = @ \cup {s}]
          /\ held' = [held EXCEPT ![n] = @ \cup {s}]
          /\ pubs' = IF Fault = "PublishEarly" /\ s = 1 /\ Key[n] # 0
                       THEN pubs \cup {<<calls, n>>} ELSE pubs
    /\ UNCHANGED <<phase, calls, nst, own, rel, relSeq, started, viaCycle,
                   failed, failSeq, rfail, deps, thrown, rbLog, lateStart,
                   newV>>

(* The staged bindings become visible together; leases pass to the node. *)
Commit(n) ==
    /\ nst[n] = "run"
    /\ ~PumpPending
    /\ Cardinality(acq[n]) = Steps[n]
    /\ nst' = [nst EXCEPT ![n] = "act"]
    /\ own' = [own EXCEPT ![n] = "node"]
    /\ pubs' = IF Key[n] # 0 THEN pubs \cup {<<calls, n>>} ELSE pubs
    /\ stg' = {x \in stg : x[1] # n}
    /\ UNCHANGED <<phase, calls, held, acq, rel, relSeq, started, viaCycle,
                   failed, failSeq, rfail, deps, thrown, rbLog, lateStart,
                   ep, rebuilt, pend, lacq, reqs>>

(* The activation throws; it releases its own leases in reverse order. *)
Fail(n) ==
    /\ nst[n] = "run"
    /\ ~PumpPending
    /\ nst' = [nst EXCEPT ![n] = "idle"]
    /\ IF Fault = "DropLease"
         THEN /\ held' = [held EXCEPT ![n] = {}]
              /\ UNCHANGED <<rel, relSeq>>
         ELSE ReleaseUpd(n)
    /\ failed' = IF n \in Members THEN failed \cup {n} ELSE failed
    /\ failSeq' = IF n \in Members THEN Append(failSeq, n) ELSE failSeq
    /\ rfail' = IF phase \in {"recon", "rbRecon"} THEN rfail \cup {n} ELSE rfail
    /\ stg' = {x \in stg : x[1] # n}
    /\ UNCHANGED <<phase, calls, own, acq, started, viaCycle, pubs, deps,
                   thrown, rbLog, lateStart, ep, rebuilt, pend, lacq, reqs>>

(* Every member settled without failure: the closing reconcile. *)
EndSched ==
    /\ phase = "sched"
    /\ failed = {}
    /\ started = Members
    /\ Flight = {}
    /\ phase' = "recon"
    /\ rfail' = {}
    /\ UNCHANGED <<calls, nst, held, own, acq, rel, relSeq, started, viaCycle,
                   failed, failSeq, pubs, deps, thrown, rbLog, lateStart,
                   newV>>

(* A member failed and every started member settled (or the fault). *)
BeginRollback ==
    /\ phase = "sched"
    /\ failed # {}
    /\ (Flight = {} \/ Fault = "EarlyRollback")
    /\ phase' = "rollback"
    /\ thrown' = IF Fault = "RethrowEarliest" THEN failSeq[1] ELSE Min(failed)
    /\ UNCHANGED <<calls, nst, held, own, acq, rel, relSeq, started, viaCycle,
                   failed, failSeq, rfail, pubs, deps, rbLog, lateStart,
                   newV>>

(* Reconcile wakes one dormant node whose requirements hold. *)
ReconBegin(n) ==
    /\ phase \in {"recon", "rbRecon"}
    /\ ~AnyRun
    /\ Eligible(n)
    /\ BeginRun(n)
    /\ UNCHANGED <<phase, calls, rel, started, viaCycle, failed, failSeq, rfail,
                   pubs, thrown, rbLog, lateStart, lateV>>

(* _rebuildChanged: a stale active node of a descendant scope is deactivated
   and becomes dormant; it can wake again as a second episode. *)
Rebuild(d) ==
    /\ phase \in {"recon", "rbRecon"}
    /\ ~AnyRun
    /\ Fault # "SkipRebuild"
    /\ Stale(d)
    /\ ReleaseUpd(d)
    /\ nst' = [nst EXCEPT ![d] = "idle"]
    /\ deps' = [deps EXCEPT ![d] = {}]
    /\ rebuilt' = rebuilt \cup {d}
    /\ UNCHANGED <<phase, calls, own, acq, started, viaCycle, failed, failSeq,
                   rfail, pubs, thrown, rbLog, lateStart, ep, stg, pend, lacq,
                   reqs>>

(* Reconcile ends when no node is eligible and no active node is stale. *)
ReconDone ==
    /\ phase \in {"recon", "rbRecon"}
    /\ ~AnyRun
    /\ ~(\E n \in Nodes : Eligible(n))
    /\ Fault = "SkipRebuild" \/ ~(\E d \in Desc : Stale(d))
    /\ IF phase = "recon"
         THEN /\ IF failed = {}
                   THEN /\ phase' = "ok"
                        /\ thrown' = thrown
                   ELSE /\ phase' = "rollback"
                        /\ thrown' = IF Fault = "RethrowEarliest"
                                       THEN failSeq[1] ELSE Min(failed)
         ELSE /\ phase' = "failed"
              /\ thrown' = thrown
    /\ UNCHANGED <<calls, nst, held, own, acq, rel, relSeq, started, viaCycle,
                   failed, failSeq, rfail, pubs, deps, rbLog, lateStart,
                   newV>>

(* The extra release attempts of a rolled-back rebuilt node (the defect). *)
OldEpisode(r) ==
    IF Fault = "ReleaseRebuilt" /\ r \in rebuilt
      THEN {<<calls, r, ep[r] - 1, i>> : i \in 1..Steps[r]}
      ELSE {}

(* deactivate(t, permanent: true) for the next member, last declared first. *)
RbStep ==
    /\ phase = "rollback"
    /\ Reg # {}
    /\ LET t == IF Fault = "DeclOrder" THEN Min(Reg) ELSE Max(Reg)
           r == IF Fault = "SkipDependents" THEN t ELSE Leaf(t)
       IN \/ /\ nst[t] = "act"
             /\ ReleaseWith(r, {<<calls, r, ep[r], i>> : i \in held[r]}
                                 \cup OldEpisode(r))
             /\ nst' = [nst EXCEPT ![r] = IF r = t THEN "none" ELSE "idle"]
             /\ pubs' = pubs \ {<<calls, r>>}
             /\ rbLog' = Append(rbLog, r)
          \/ /\ nst[t] # "act"
             /\ nst' = [nst EXCEPT ![t] = "none"]
             /\ IF Fault = "DoubleRelease" /\ t \in failed
                  THEN rel' = [x \in RelDom |->
                                 IF x[1] = calls /\ x[2] = t /\ x[3] = ep[t]
                                    /\ x[4] \in acq[t]
                                   THEN rel[x] + 1 ELSE rel[x]]
                  ELSE rel' = rel
             /\ UNCHANGED <<held, relSeq, pubs, rbLog>>
    /\ UNCHANGED <<phase, calls, own, acq, started, viaCycle, failed, failSeq,
                   rfail, deps, thrown, lateStart, newV>>

(* Every created node is gone; reconcile once more. *)
RbDone ==
    /\ phase = "rollback"
    /\ Reg = {}
    /\ phase' = "rbRecon"
    /\ rfail' = {}
    /\ UNCHANGED <<calls, nst, held, own, acq, rel, relSeq, started, viaCycle,
                   failed, failSeq, pubs, deps, thrown, rbLog, lateStart,
                   newV>>

-----------------------------------------------------------------------------
(* Escaped activation contexts (R-UC-RT-LC-002). Environment actions: user
   code that holds a context after its episode closed (committed, failed,
   rolled back, or replaced by a rebuild episode). *)

\* An acquire passed the guard in an open episode and awaits its lease.
StartLate(n) ==
    /\ reqs < Late
    /\ nst[n] = "run"
    /\ ~PumpPending
    /\ pend[n] = 0
    /\ <<n, ep[n]>> \notin lacq
    /\ pend' = [pend EXCEPT ![n] = ep[n]]
    /\ lacq' = lacq \cup {<<n, ep[n]>>}
    /\ reqs' = reqs + 1
    /\ UNCHANGED <<phase, calls, nst, held, own, acq, rel, relSeq, started,
                   viaCycle, failed, failSeq, rfail, pubs, deps, thrown, rbLog,
                   lateStart, ep, rebuilt, stg>>

\* The lease lands after its episode closed. The runtime releases it once
\* and rejects the acquire; the lease never joins the node.
LandLease(n) ==
    /\ pend[n] # 0
    /\ \/ nst[n] # "run"
       \/ pend[n] < ep[n]
    /\ pend' = [pend EXCEPT ![n] = 0]
    /\ IF Fault = "MutateAfterClose"
         THEN /\ held' = [held EXCEPT ![n] = @ \cup {LateId}]
              /\ UNCHANGED rel
         ELSE IF Fault = "LateLeak"
         THEN UNCHANGED <<held, rel>>
         ELSE /\ rel' = [t \in RelDom |->
                           IF t = <<calls, n, pend[n], LateId>>
                             THEN rel[t] + 1 ELSE rel[t]]
              /\ UNCHANGED held
    /\ UNCHANGED <<phase, calls, nst, own, acq, relSeq, started, viaCycle,
                   failed, failSeq, rfail, pubs, deps, thrown, rbLog, lateStart,
                   ep, rebuilt, stg, lacq, reqs>>

\* publish/contribute in an open episode stages work.
Stage(n) ==
    /\ Late > 0
    /\ nst[n] = "run"
    /\ ~PumpPending
    /\ Key[n] # 0
    /\ <<n, ep[n]>> \notin stg
    /\ stg' = stg \cup {<<n, ep[n]>>}
    /\ UNCHANGED <<phase, calls, nst, held, own, acq, rel, relSeq, started,
                   viaCycle, failed, failSeq, rfail, pubs, deps, thrown, rbLog,
                   lateStart, ep, rebuilt, pend, lacq, reqs>>

\* publish/contribute from the context of episode e after it closed (or while
\* a newer episode of the node runs). The runtime throws and stages nothing.
LateStage(n, e) ==
    /\ reqs < Late
    /\ e \in 1..ep[n]
    /\ \/ nst[n] # "run"
       \/ e < ep[n]
    /\ reqs' = reqs + 1
    /\ stg' = IF Fault = "StageAfterClose" THEN stg \cup {<<n, e>>} ELSE stg
    /\ UNCHANGED <<phase, calls, nst, held, own, acq, rel, relSeq, started,
                   viaCycle, failed, failSeq, rfail, pubs, deps, thrown, rbLog,
                   lateStart, ep, rebuilt, pend, lacq>>

Terminated ==
    /\ \/ phase = "ok"
       \/ phase = "failed" /\ calls = MaxCalls
    /\ AllLanded
    /\ UNCHANGED vars

Next ==
    \/ Create
    \/ \E m \in Members : Start(m)
    \/ \E n \in Nodes : Acquire(n) \/ Commit(n) \/ Fail(n) \/ ReconBegin(n)
                        \/ Rebuild(n) \/ StartLate(n) \/ LandLease(n)
                        \/ Stage(n)
    \/ \E n \in Nodes, e \in EpDom : LateStage(n, e)
    \/ EndSched
    \/ BeginRollback
    \/ ReconDone
    \/ RbStep
    \/ RbDone
    \/ Terminated

Spec == Init /\ [][Next]_vars

\* Liveness assumption: finite callbacks settle and runtime steps run.
FairSpec == Spec /\ WF_vars(Next)

-----------------------------------------------------------------------------
(* Safety properties (R-UC-RT-LC-009, R-UC-RT-LC-014). *)

\* A binding is visible only while its activation is committed, and a failed
\* call leaves none (no staged publication is public).
AtomicPublication ==
    /\ \A p \in pubs : p[1] = calls /\ nst[p[2]] = "act"
    /\ phase = "failed" => pubs = {}

\* Every member in flight settles before any rollback step.
SettleBeforeRollback ==
    phase \in {"rollback", "rbRecon", "failed"} => Flight = {}

\* At most one committed binding per key (scope is fixed).
UniqueBinding ==
    \A p, q \in pubs : Key[p[2]] = Key[q[2]] => p = q

\* Every acquired lease is held by exactly one live owner or released once,
\* and so is every lease that landed after its episode closed. After a failed
\* call only a descendant node that is active again holds leases.
LeaseAccounted ==
    /\ \A n \in Nodes :
         held[n] # {} =>
           \/ own[n] = "act" /\ nst[n] = "run"
           \/ own[n] = "node" /\ nst[n] = "act"
    /\ \A n \in Nodes : \A s \in acq[n] :
         (IF s \in held[n] THEN 1 ELSE 0) + rel[<<calls, n, ep[n], s>>] = 1
    /\ \A x \in lacq :
         (IF pend[x[1]] = x[2] THEN 1 ELSE 0)
           + rel[<<calls, x[1], x[2], LateId>>] = 1
    /\ phase = "failed" =>
         \A n \in Nodes : held[n] # {} => (n \in Desc /\ nst[n] = "act")

ReleaseAtMostOnce == \A t \in RelDom : rel[t] <= 1

\* Leases of one activation release in reverse acquisition order.
ReverseAcquisition ==
    \A n \in Nodes : \A i \in 1..(Len(relSeq[n]) - 1) :
        relSeq[n][i] > relSeq[n][i + 1]

\* A dependent is deactivated before its publisher: the publisher's value
\* stays alive while the dependent releases.
DependentFirst ==
    \A n \in Nodes : nst[n] = "act" => deps[n] \subseteq ActiveSet

\* Rollback runs in reverse declaration order, except where a dependent of
\* a later member must go first. A node of a descendant scope goes with the
\* member it reads (DependentFirst), which can be an earlier member.
ReverseDeclaration ==
    \A i, j \in 1..Len(rbLog) :
        (i < j /\ rbLog[i] < rbLog[j] /\ rbLog[j] \in Members)
            => rbLog[j] \in Reach(rbLog[i])

\* A dependent never starts before its publishers settled (cycle excepted).
PublishersFirst ==
    phase = "sched" =>
        \A m \in started \ viaCycle :
            Prereq(m) \subseteq started /\ Prereq(m) \cap Flight = {}

\* After a failure the call starts no further member.
NoStartAfterFailure == lateStart = {}

\* After the rollback no node of a descendant scope reads a member binding:
\* a node that the call woke or rebuilt is dormant, or active again against
\* an ancestor publisher only.
WokenDormantAfterRollback ==
    phase \in {"rbRecon", "failed"} =>
        \A d \in Desc :
            /\ nst[d] \in {"act", "run"} => deps[d] = {}
            /\ nst[d] = "idle" => held[d] = {}

\* The rethrown failure is the first failed member in declaration order.
RethrowFirstDeclared ==
    phase \in {"rollback", "rbRecon", "failed"} => thrown = Min(failed)

\* A failed call unregisters every node and stays declared; a successful
\* call leaves every member registered and reconcile quiescent (no eligible
\* node, no stale active node).
ScopeOutcome ==
    /\ phase = "failed" => /\ failed # {}
                           /\ \A m \in Members : nst[m] = "none"
    /\ phase = "ok" => /\ failed = {}
                       /\ \A m \in Members : nst[m] \in {"idle", "act"}
    /\ phase \in {"ok", "failed"} =>
         /\ ~AnyRun
         /\ ~(\E n \in Nodes : Eligible(n))
         /\ ~(\E d \in Desc : Stale(d))

\* Work of a closed episode is never accepted: staged work exists only in the
\* open episode of its node, and every held lease belongs to the episode that
\* acquired it (a lease that lands after closure never transfers to the node).
ClosedActivation ==
    /\ \A x \in stg : nst[x[1]] = "run" /\ x[2] = ep[x[1]]
    /\ \A n \in Nodes : held[n] \subseteq acq[n]

\* Liveness: a started call ends under the fairness assumptions.
InitializeCompletes == (phase \in Running) ~> (phase \in {"ok", "failed"})

=============================================================================
