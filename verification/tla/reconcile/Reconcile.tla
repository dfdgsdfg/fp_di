------------------------------ MODULE Reconcile ------------------------------
(***************************************************************************)
(* Reconciliation and withdrawal of the fp_di runtime.                     *)
(*                                                                         *)
(* Scopes have fixed contents. The host initializes scopes in any order,   *)
(* disposes members and scopes, and each mutation runs as one serialized   *)
(* transaction: withdraw (dependents first), recheck the targets of active *)
(* nodes, activate eligible dormant nodes, and repeat until stable.        *)
(*                                                                         *)
(* Code correspondence (abstraction map, not a refinement proof):          *)
(*   InitScope        Scope.initialize: register the members (their       *)
(*                    activation always succeeds here; the failure and    *)
(*                    rollback of initialize is modeled in Initialize.tla) *)
(*   DisposeNode      ComponentNode.dispose -> _Runtime.deactivate(perm)  *)
(*   DisposeScope     Scope.dispose -> _Runtime.disposeScope              *)
(*   ReleaseOne       _Runtime.deactivate: dependents first, then the     *)
(*                    node's own cleanups (runCleanups). One release is   *)
(*                    one atomic step here, in any dependents-first order;*)
(*                    disposeScope runs releases concurrently, and        *)
(*                    Teardown.tla checks their overlap                    *)
(*   CheckChanged     _Runtime.reconcile, active-target loop with         *)
(*                    _targetChanged                                       *)
(*   ActivateDormant  _Runtime.reconcile, dormant loop -> activate        *)
(*   FinishDormant    end of the dormant loop: recheck or finish          *)
(*   Rules            core/core_node.dart and core/core_resolve.dart;     *)
(*                    the runtime members that follow delegate to them    *)
(*   resolve          coreResolve (nearest available binding)             *)
(*   satisfied        coreSatisfied (required keys only)                  *)
(*   Members          coreContributionKeysOf: the declared                *)
(*                    contributions to a collection in the reader's scope *)
(*                    and its ancestors, except the reader's own; a       *)
(*                    member leaves only when its scope is initialized    *)
(*                    and its node is removed                             *)
(*                    (the line `scope.initialized && removed`)           *)
(*   ReqKeys/OptKeys  coreSatisfied, _strictContributionKeys,             *)
(*                    plainReads: a collection read expands to the        *)
(*                    contribution keys of the current membership at      *)
(*                    every use; nothing is captured                      *)
(*   Changed          coreTargetChanged, without its comparison of        *)
(*                    the member list: a member that leaves while its     *)
(*                    key is unresolved changes no resolved target here   *)
(*                    (the runtime rebuilds the reader in that case)      *)
(*                                                                         *)
(* A contributor publishes its own unique member key, as the runtime does *)
(* with _DiContributionKey. Another node may read that key as a plain     *)
(* key, as an entry of a map key is read. Value algebra (set collapse,    *)
(* map ids, order) is outside the model.                                  *)
(*                                                                         *)
(* The order in which changed or dormant nodes are picked is free, a      *)
(* superset of the id order the runtime uses.                              *)
(*                                                                         *)
(* Holds of a disposal (R-UC-RT-LC-034). With Held, the child scope has an *)
(* open hold from the start. HeldRequest is the disposal request of that   *)
(* scope: the scope is "requested" at once and its disposal waits outside  *)
(* the queue. During the wait the host mutates other nodes, so a publisher *)
(* of the parent may withdraw and return. The withdrawal deactivates the   *)
(* readers of the requested scope, and no node of that scope starts an     *)
(* activation again. CloseHold and ReleaseHolds end the wait and run the   *)
(* scope disposal. The request comes between two transactions; a request   *)
(* inside a transaction, which cancels the activations in flight, belongs  *)
(* to Cancellation.tla. A disposal request of the root while the child     *)
(* hold is open is not modeled; Disposal.tla owns the join of holds.       *)
(*                                                                         *)
(*   HeldRequest      Scope.dispose with a hold open: disposeRequested      *)
(*   CloseHold,       DisposeHold.close, _Runtime.holdClosed: the last      *)
(*   ReleaseHolds     close queues the waiting disposal                     *)
(*                                                                         *)
(* Fault selects at most one deliberate defect (negative controls).        *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Topology,     \* "G002" | "Shadow" | "Chain" | "Feedback" | "Collection" | "Held"
    Held,         \* the child scope has an open hold at the start
    MaxFailures,  \* automatic activations that may fail (host input)
    MaxDisposeFailures,
                  \* own releases that may fail and block reactivation
    Fault         \* "none" or one deliberate defect below

Faults == {
    "none",
    "UnsettledSucceeds", \* initialize succeeds with its members stale
    "SkipRecheck",       \* the runtime before G-RT-LC-002 was fixed
    "OptionalRequired",  \* optional reads gate activation
    "PublisherFirst",    \* a publisher releases before its dependents
    "RebuildUnchanged",  \* recheck rebuilds a node whose target is equal
    "ResurrectRemoved",  \* a disposed member activates again
    "ActivateWhileHeld", \* a node of a scope whose held disposal waits activates
    "OmitOptional",      \* the committed view drops optional reads
    "CaptureMembership", \* a disposed member never leaves the membership
    "OwnMember",         \* a reader's own contribution is one of its members
    "ChildVisible"       \* contributions of a child scope are members and resolve
}

ASSUME Fault \in Faults
ASSUME MaxFailures \in Nat /\ MaxDisposeFailures \in Nat
ASSUME Held \in BOOLEAN

NoNode == "none"

(***************************************************************************)
(* Topologies. Scope "root" has no parent; "child" has parent "root".      *)
(* Keys are distinct within one scope, as initialize requires.             *)
(***************************************************************************)
Scopes == {"root", "child"}
Parent == [s \in Scopes |-> IF s = "child" THEN "root" ELSE "none"]

\* G-RT-LC-002: a watcher in the child optionally reads the String that a
\* sibling publishes once the root's int arrives.
G002 == [
    nodes |-> {"int", "watcher", "producer"},
    scope |-> [n \in {"int", "watcher", "producer"} |->
                 IF n = "int" THEN "root" ELSE "child"],
    req   |-> [n \in {"int", "watcher", "producer"} |->
                 IF n = "producer" THEN {"kInt"} ELSE {}],
    opt   |-> [n \in {"int", "watcher", "producer"} |->
                 IF n = "watcher" THEN {"kStr"} ELSE {}],
    pub   |-> [n \in {"int", "watcher", "producer"} |->
                 CASE n = "int" -> "kInt"
                   [] n = "producer" -> "kStr"
                   [] OTHER -> NoNode]]

\* A nearer publisher shadows the root one, and disposing it falls back.
Shadow == [
    nodes |-> {"far", "near", "reader"},
    scope |-> [n \in {"far", "near", "reader"} |->
                 IF n = "far" THEN "root" ELSE "child"],
    req   |-> [n \in {"far", "near", "reader"} |->
                 IF n = "reader" THEN {"k"} ELSE {}],
    opt   |-> [n \in {"far", "near", "reader"} |-> {}],
    pub   |-> [n \in {"far", "near", "reader"} |->
                 IF n = "reader" THEN NoNode ELSE "k"]]

\* A chain with an optional read of the root: a <- b <- c, c also reads a.
Chain == [
    nodes |-> {"a", "b", "c"},
    scope |-> [n \in {"a", "b", "c"} |-> IF n = "a" THEN "root" ELSE "child"],
    req   |-> [n \in {"a", "b", "c"} |->
                 CASE n = "b" -> {"k1"} [] n = "c" -> {"k2"} [] OTHER -> {}],
    opt   |-> [n \in {"a", "b", "c"} |-> IF n = "c" THEN {"k1"} ELSE {}],
    pub   |-> [n \in {"a", "b", "c"} |->
                 CASE n = "a" -> "k1" [] n = "b" -> "k2" [] OTHER -> NoNode]]

\* Optional feedback: x reads K optionally and publishes L; y requires L
\* and publishes K. The spec does not promise convergence; the runtime must
\* still stop.
Feedback == [
    nodes |-> {"x", "y"},
    scope |-> [n \in {"x", "y"} |-> "root"],
    req   |-> [n \in {"x", "y"} |-> IF n = "y" THEN {"L"} ELSE {}],
    opt   |-> [n \in {"x", "y"} |-> IF n = "x" THEN {"K"} ELSE {}],
    pub   |-> [n \in {"x", "y"} |-> IF n = "x" THEN "L" ELSE "K"]]

\* Collection keys. Contributors c1 (root) and c2 (child) publish the member
\* keys m1 and m2. c2 also requires m1, so disposing c1 makes c2 dormant while
\* it stays a member. rs (child) reads C strictly and also contributes m3.
\* ro (root) reads C optionally and sees only the root contribution.
Collection == [
    nodes   |-> {"c1", "c2", "rs", "ro"},
    scope   |-> [n \in {"c1", "c2", "rs", "ro"} |->
                   IF n \in {"c1", "ro"} THEN "root" ELSE "child"],
    req     |-> [n \in {"c1", "c2", "rs", "ro"} |->
                   IF n = "c2" THEN {"m1"} ELSE {}],
    opt     |-> [n \in {"c1", "c2", "rs", "ro"} |-> {}],
    pub     |-> [n \in {"c1", "c2", "rs", "ro"} |->
                   CASE n = "c1" -> "m1" [] n = "c2" -> "m2"
                     [] n = "rs" -> "m3" [] OTHER -> NoNode],
    contrib |-> [n \in {"c1", "c2", "rs", "ro"} |->
                   IF n = "ro" THEN NoNode ELSE "C"],
    colreq  |-> [n \in {"c1", "c2", "rs", "ro"} |->
                   IF n = "rs" THEN {"C"} ELSE {}],
    colopt  |-> [n \in {"c1", "c2", "rs", "ro"} |->
                   IF n = "ro" THEN {"C"} ELSE {}]]

\* A held scope. x is a root publisher; p, also in the root, reads x
\* optionally and publishes kP; r, in the child, requires kP. The disposal of
\* x withdraws p and r. p stays eligible, since its read of x is optional, and
\* returns. r must not activate again while the disposal of the child waits.
HeldTopology == [
    nodes |-> {"x", "p", "r"},
    scope |-> [n \in {"x", "p", "r"} |-> IF n = "r" THEN "child" ELSE "root"],
    req   |-> [n \in {"x", "p", "r"} |-> IF n = "r" THEN {"kP"} ELSE {}],
    opt   |-> [n \in {"x", "p", "r"} |-> IF n = "p" THEN {"kX"} ELSE {}],
    pub   |-> [n \in {"x", "p", "r"} |->
                 CASE n = "x" -> "kX" [] n = "p" -> "kP" [] OTHER -> NoNode]]

T == CASE Topology = "G002" -> G002
       [] Topology = "Held" -> HeldTopology
       [] Topology = "Collection" -> Collection
       [] Topology = "Shadow" -> Shadow
       [] Topology = "Chain" -> Chain
       [] Topology = "Feedback" -> Feedback

Nodes == T.nodes
Keys == UNION {T.req[n] \cup T.opt[n] \cup
                (IF T.pub[n] = NoNode THEN {} ELSE {T.pub[n]}) : n \in Nodes}
MaxPasses == Cardinality(Nodes) + 1

VARIABLES
    scopeState,  \* [Scopes -> {"declared", "initialized", "requested", "disposed"}]
    registered,  \* [Nodes -> BOOLEAN]
    active,      \* [Nodes -> BOOLEAN]
    blocked,     \* [Nodes -> BOOLEAN] own release failed
    committed,   \* [Nodes -> [Keys -> Nodes \cup {NoNode}]] committed view
    withdrawing, \* nodes being deactivated: unavailable, not yet released
    permanent,   \* withdrawing nodes that are removed when released
    pc,          \* "idle" | "withdraw" | "check" | "dormant"
    afterWithdraw, \* phase to resume once withdrawing is empty
    failedNow,   \* automatic activation failures in this transaction
    initCall,    \* members of the initialize in this transaction
    passes,      \* recheck passes in this transaction
    diverged,    \* the transaction stopped at MaxPasses without stability
    failures,    \* automatic activation failures so far
    disposeFailures,  \* own dispose failures so far
    removed,     \* ghost: members that were disposed
    neutral,     \* ghost: a node was rebuilt with an unchanged target
    unsettled,   \* ghost: members of the initialize left stale at the bound
    held,        \* the hold of the child scope is open
    lateAct      \* ghost: a node activated in a scope whose disposal was requested

holdVars == <<held, lateAct>>

vars == <<scopeState, registered, active, blocked, committed, withdrawing,
          permanent, pc, afterWithdraw, failedNow, initCall, passes,
          diverged, failures, disposeFailures, removed, neutral, unsettled,
          held, lateAct>>

(***************************************************************************)
(* Resolution                                                              *)
(***************************************************************************)
Live(s) == scopeState[s] = "initialized"

\* The available binding of key k in scope s, or NoNode.
Binding(s, k) ==
    LET ps == {n \in Nodes : T.scope[n] = s /\ T.pub[n] = k /\ registered[n]
                               /\ active[n] /\ n \notin withdrawing}
    IN IF ps = {} THEN NoNode ELSE CHOOSE n \in ps : TRUE

\* Nearest available binding, from s up to the root, excluding the owner.
Resolve(s, k, owner) ==
    LET here == Binding(s, k)
    IN IF here # NoNode /\ here # owner THEN here
       ELSE IF Parent[s] = "none" THEN NoNode
       ELSE LET up == Binding(Parent[s], k)
            IN IF up # owner THEN up ELSE NoNode

(***************************************************************************)
(* Collection reads. The membership is computed from the current state at  *)
(* every use. The oracle definitions (Members, ReqKeys, OptKeys, Reads,    *)
(* Target, Changed, Satisfied, Eligible) are correct and carry no fault.   *)
(* The Rt definitions drive the actions and carry the deliberate faults.   *)
(***************************************************************************)
Colls == {"C"}
Contrib(n) == IF "contrib" \in DOMAIN T THEN T.contrib[n] ELSE NoNode
ColReq(n) == IF "colreq" \in DOMAIN T THEN T.colreq[n] ELSE {}
ColOpt(n) == IF "colopt" \in DOMAIN T THEN T.colopt[n] ELSE {}

Ancestors(s) == IF Parent[s] = "none" THEN {s} ELSE {s, Parent[s]}
Kids(s) == {t \in Scopes : Parent[t] = s}

\* A contribution leaves only when its scope is initialized and it is no
\* longer registered. A dormant or withdrawn contributor stays a member, and
\* so does one in a scope that is not yet initialized.
MemberLive(m) == scopeState[T.scope[m]] = "declared" \/ registered[m]

\* Every contributor to c that n could ever see: the over-approximation
\* that a captured membership would keep.
Candidates(n, c) ==
    {m \in Nodes : Contrib(m) = c /\ m # n
                     /\ T.scope[m] \in Ancestors(T.scope[n])}

Members(n, c) == {m \in Candidates(n, c) : MemberLive(m)}

MemKeys(ms) == {T.pub[m] : m \in ms}

ReqKeys(n) == T.req[n] \cup UNION {MemKeys(Members(n, c)) : c \in ColReq(n)}
OptKeys(n) == T.opt[n] \cup UNION {MemKeys(Members(n, c)) : c \in ColOpt(n)}
Reads(n) == ReqKeys(n) \cup OptKeys(n)

\* The membership that the actions use.
RtMembers(n, c) ==
    {m \in Nodes :
        /\ Contrib(m) = c
        /\ (Fault = "OwnMember" \/ m # n)
        /\ T.scope[m] \in (IF Fault = "ChildVisible"
                            THEN Ancestors(T.scope[n]) \cup Kids(T.scope[n])
                            ELSE Ancestors(T.scope[n]))
        /\ (Fault = "CaptureMembership" \/ MemberLive(m))}

RtReqKeys(n) ==
    T.req[n] \cup UNION {MemKeys(RtMembers(n, c)) : c \in ColReq(n)}
RtOptKeys(n) ==
    T.opt[n] \cup UNION {MemKeys(RtMembers(n, c)) : c \in ColOpt(n)}
RtReads(n) == RtReqKeys(n) \cup RtOptKeys(n)

\* ChildVisible: a member key that does not resolve in the scope of n or an
\* ancestor also resolves to a child scope binding.
RtResolve(s, k, owner) ==
    LET up == Resolve(s, k, owner)
        below == {Binding(t, k) : t \in Kids(s)} \ {NoNode, owner}
    IN IF up # NoNode \/ Fault # "ChildVisible" \/ below = {} THEN up
       ELSE CHOOSE b \in below : TRUE

Target(n) == [k \in Keys |->
                IF k \in Reads(n) THEN Resolve(T.scope[n], k, n) ELSE NoNode]

RtTarget(n) == [k \in Keys |->
                IF k \in RtReads(n) THEN RtResolve(T.scope[n], k, n) ELSE NoNode]

Satisfied(n) == \A k \in ReqKeys(n) : Resolve(T.scope[n], k, n) # NoNode

RtSatisfied(n) ==
    /\ \A k \in RtReqKeys(n) : RtResolve(T.scope[n], k, n) # NoNode
    /\ Fault = "OptionalRequired" =>
         \A k \in RtOptKeys(n) : RtResolve(T.scope[n], k, n) # NoNode

Commit(n) ==
    IF Fault = "OmitOptional"
    THEN [k \in Keys |-> IF k \in RtReqKeys(n) THEN RtTarget(n)[k] ELSE NoNode]
    ELSE RtTarget(n)

Changed(n) == committed[n] # Target(n)
RtChanged(n) == committed[n] # RtTarget(n)

\* Active nodes that read a value of one of ns.
DependentsOf(ns) ==
    {m \in Nodes : active[m] /\ \E k \in Keys : committed[m][k] \in ns}

RECURSIVE Closure(_)
Closure(ns) == LET next == ns \cup DependentsOf(ns)
               IN IF next = ns THEN ns ELSE Closure(next)

Eligible(n) ==
    /\ registered[n]
    /\ ~active[n] /\ ~blocked[n]
    /\ Live(T.scope[n])
    /\ n \notin failedNow
    /\ Satisfied(n)

RtEligible(n) ==
    /\ (registered[n] \/ Fault = "ResurrectRemoved")
    /\ ~active[n] /\ ~blocked[n]
    /\ (Live(T.scope[n])
         \/ (Fault = "ActivateWhileHeld" /\ scopeState[T.scope[n]] = "requested"))
    /\ n \notin failedNow
    /\ RtSatisfied(n)

EmptyView == [k \in Keys |-> NoNode]

(***************************************************************************)
(* Initial state                                                           *)
(***************************************************************************)
Init ==
    /\ scopeState = [s \in Scopes |-> "declared"]
    /\ registered = [n \in Nodes |-> FALSE]
    /\ active = [n \in Nodes |-> FALSE]
    /\ blocked = [n \in Nodes |-> FALSE]
    /\ committed = [n \in Nodes |-> EmptyView]
    /\ withdrawing = {}
    /\ permanent = {}
    /\ pc = "idle"
    /\ afterWithdraw = "check"
    /\ failedNow = {}
    /\ initCall = {}
    /\ passes = 0
    /\ diverged = FALSE
    /\ failures = 0
    /\ disposeFailures = 0
    /\ removed = {}
    /\ neutral = FALSE
    /\ unsettled = {}
    /\ held = Held
    /\ lateAct = FALSE

StartTxn == /\ failedNow' = {} /\ passes' = 0 /\ diverged' = FALSE

(***************************************************************************)
(* Host mutations (serialized: only when idle)                             *)
(***************************************************************************)
InitScope(s) ==
    /\ pc = "idle"
    /\ scopeState[s] = "declared"
    /\ (Parent[s] # "none" => scopeState[Parent[s]] # "disposed")
    /\ scopeState' = [scopeState EXCEPT ![s] = "initialized"]
    /\ registered' = [n \in Nodes |-> registered[n] \/ T.scope[n] = s]
    /\ initCall' = {n \in Nodes : T.scope[n] = s}
    /\ pc' = "dormant"
    /\ StartTxn
    /\ UNCHANGED <<active, blocked, committed, withdrawing, permanent,
                   afterWithdraw, failures, disposeFailures, removed, neutral,
                   unsettled, holdVars>>

DisposeNode(n) ==
    /\ pc = "idle"
    /\ registered[n]
    /\ Live(T.scope[n])
    /\ removed' = removed \cup {n}
    /\ IF active[n]
       THEN /\ withdrawing' = Closure({n})
            /\ permanent' = {n}
            /\ registered' = registered
       ELSE /\ withdrawing' = {}
            /\ permanent' = {}
            /\ registered' = [registered EXCEPT ![n] = FALSE]
    /\ pc' = "withdraw"
    /\ afterWithdraw' = "check"
    /\ initCall' = {}
    /\ StartTxn
    /\ UNCHANGED <<scopeState, active, blocked, committed, failures,
                   disposeFailures, neutral, unsettled, holdVars>>

Subtree(s) == IF s = "root" THEN Scopes ELSE {s}

\* An open hold of the child scope delays the disposal of its scope and of
\* the root, which contains it.
HoldOpen(s) == held /\ "child" \in Subtree(s)

\* The disposal mutation of scope s and its subtree.
DisposeMutation(s) ==
    /\ pc = "idle"
    /\ LET gone == {n \in Nodes : T.scope[n] \in Subtree(s) /\ registered[n]}
       IN /\ scopeState' = [t \in Scopes |->
                              IF t \in Subtree(s) THEN "disposed"
                              ELSE scopeState[t]]
          /\ removed' = removed \cup gone
          /\ withdrawing' = Closure({n \in gone : active[n]})
          /\ permanent' = gone
          /\ registered' = [n \in Nodes |->
                              IF n \in gone /\ ~active[n] THEN FALSE
                              ELSE registered[n]]
    /\ pc' = "withdraw"
    /\ afterWithdraw' = "check"
    /\ initCall' = {}
    /\ StartTxn
    /\ UNCHANGED <<active, blocked, committed, failures, disposeFailures,
                   neutral, unsettled, holdVars>>

DisposeScope(s) ==
    /\ scopeState[s] = "initialized"
    /\ ~HoldOpen(s)
    /\ DisposeMutation(s)

\* The disposal request of the held child scope. The scope is requested at
\* once; its nodes stay active and start no activation, and its disposal
\* waits for the hold outside the transaction queue.
HeldRequest ==
    /\ pc = "idle"
    /\ held
    /\ scopeState["child"] = "initialized"
    /\ scopeState' = [scopeState EXCEPT !["child"] = "requested"]
    /\ UNCHANGED <<registered, active, blocked, committed, withdrawing,
                   permanent, pc, afterWithdraw, failedNow, initCall, passes,
                   diverged, failures, disposeFailures, removed, neutral,
                   unsettled, holdVars>>

\* The hold closes; the mutations of the root run before and after it.
CloseHold ==
    /\ held
    /\ held' = FALSE
    /\ UNCHANGED <<scopeState, registered, active, blocked, committed,
                   withdrawing, permanent, pc, afterWithdraw, failedNow,
                   initCall, passes, diverged, failures, disposeFailures,
                   removed, neutral, unsettled, lateAct>>

\* The last hold closed: the waiting disposal of the child enters the queue
\* and runs as a disposal mutation.
ReleaseHolds ==
    /\ scopeState["child"] = "requested"
    /\ ~held
    /\ DisposeMutation("child")

(***************************************************************************)
(* Transaction steps                                                       *)
(***************************************************************************)
\* Release one withdrawing node. Conforming: none of its dependents is
\* still active, so its release runs while every value read from it lives.
ReleaseOne(n) ==
    /\ pc = "withdraw"
    /\ n \in withdrawing
    /\ Fault # "PublisherFirst" =>
         ~\E m \in withdrawing : m # n /\ active[m]
                                  /\ \E k \in Keys : committed[m][k] = n
    /\ active' = [active EXCEPT ![n] = FALSE]
    /\ committed' = [committed EXCEPT ![n] = EmptyView]
    /\ withdrawing' = withdrawing \ {n}
    /\ registered' = IF n \in permanent
                     THEN [registered EXCEPT ![n] = FALSE] ELSE registered
    /\ \/ /\ blocked' = blocked /\ disposeFailures' = disposeFailures
       \/ /\ disposeFailures < MaxDisposeFailures /\ n \notin permanent
          /\ blocked' = [blocked EXCEPT ![n] = TRUE]
          /\ disposeFailures' = disposeFailures + 1
    /\ UNCHANGED <<scopeState, permanent, pc, afterWithdraw, failedNow,
                   initCall, passes, diverged, failures, removed, neutral, unsettled,
                   holdVars>>

FinishWithdraw ==
    /\ pc = "withdraw"
    /\ withdrawing = {}
    /\ pc' = afterWithdraw
    /\ permanent' = {}
    /\ UNCHANGED <<scopeState, registered, active, blocked, committed,
                   withdrawing, afterWithdraw, failedNow, initCall, passes,
                   diverged, failures, disposeFailures, removed, neutral,
                   unsettled, holdVars>>

\* Recheck: rebuild one active node whose target changed.
CheckChanged(n) ==
    /\ pc = "check"
    /\ active[n] /\ registered[n]
    /\ RtChanged(n) \/ Fault = "RebuildUnchanged"
    /\ neutral' = (neutral \/ ~Changed(n))
    /\ withdrawing' = Closure({n})
    /\ pc' = "withdraw"
    /\ afterWithdraw' = "check"
    /\ UNCHANGED <<scopeState, registered, active, blocked, committed,
                   permanent, failedNow, initCall, passes, diverged,
                   failures, disposeFailures, removed, unsettled, holdVars>>

FinishCheck ==
    /\ pc = "check"
    /\ ~\E n \in Nodes : active[n] /\ registered[n] /\ RtChanged(n)
    /\ pc' = "dormant"
    /\ UNCHANGED <<scopeState, registered, active, blocked, committed,
                   withdrawing, permanent, afterWithdraw, failedNow,
                   initCall, passes, diverged, failures, disposeFailures,
                   removed, neutral, unsettled, holdVars>>

ActivateDormant(n) ==
    /\ pc = "dormant"
    /\ RtEligible(n)
    /\ \/ /\ active' = [active EXCEPT ![n] = TRUE]
          /\ committed' = [committed EXCEPT ![n] = Commit(n)]
          /\ lateAct' = (lateAct \/ scopeState[T.scope[n]] = "requested")
          /\ UNCHANGED <<failedNow, failures, unsettled>>
       \/ /\ failures < MaxFailures /\ n \notin initCall
          /\ failedNow' = failedNow \cup {n}
          /\ failures' = failures + 1
          /\ UNCHANGED <<active, committed, unsettled, lateAct>>
    /\ UNCHANGED <<scopeState, registered, blocked, withdrawing, permanent,
                   pc, afterWithdraw, initCall, passes, diverged,
                   disposeFailures, removed, neutral, unsettled, held>>

\* The dormant loop is done. Recheck when an activation changed a target,
\* at most MaxPasses times; SkipRecheck stops at once. At the bound, a stale
\* member of the initialize in this transaction fails that call: its members
\* roll back and the scope stays declared, and the runtime reconciles again.
\* Stale nodes of other scopes are only reported (diverged).
FinishDormant ==
    /\ pc = "dormant"
    /\ ~\E n \in Nodes : RtEligible(n)
    /\ LET stale == {n \in Nodes : active[n] /\ registered[n] /\ RtChanged(n)}
           own == stale \cap initCall
           callScope == CHOOSE s \in Scopes : \A n \in initCall : T.scope[n] = s
       IN IF stale = {} \/ Fault = "SkipRecheck"
          THEN /\ pc' = "idle" /\ initCall' = {}
               /\ UNCHANGED <<scopeState, registered, withdrawing, permanent,
                              afterWithdraw, failedNow, passes, diverged,
                              unsettled>>
          ELSE IF passes + 1 < MaxPasses
          THEN /\ pc' = "check" /\ passes' = passes + 1
               /\ UNCHANGED <<scopeState, registered, withdrawing, permanent,
                              afterWithdraw, failedNow, diverged, unsettled,
                              initCall>>
          ELSE IF own # {} /\ Fault # "UnsettledSucceeds"
          THEN /\ withdrawing' = Closure({n \in initCall : active[n]})
               /\ permanent' = initCall
               /\ registered' = [n \in Nodes |->
                                   IF n \in initCall /\ ~active[n] THEN FALSE
                                   ELSE registered[n]]
               /\ scopeState' = [scopeState EXCEPT ![callScope] = "declared"]
               /\ pc' = "withdraw"
               /\ afterWithdraw' = "check"
               /\ failedNow' = {} /\ passes' = 0 /\ diverged' = FALSE
               /\ initCall' = {}
               /\ UNCHANGED unsettled
          ELSE /\ pc' = "idle" /\ diverged' = TRUE
               /\ unsettled' = own /\ initCall' = {}
               /\ UNCHANGED <<scopeState, registered, withdrawing, permanent,
                              afterWithdraw, failedNow, passes>>
    /\ UNCHANGED <<active, blocked, committed, failures, disposeFailures,
                   removed, neutral, holdVars>>

Next ==
    \/ \E s \in Scopes : InitScope(s) \/ DisposeScope(s)
    \/ HeldRequest \/ CloseHold \/ ReleaseHolds
    \/ \E n \in Nodes : DisposeNode(n) \/ ReleaseOne(n) \/ CheckChanged(n)
                         \/ ActivateDormant(n)
    \/ FinishWithdraw \/ FinishCheck \/ FinishDormant

Spec == Init /\ [][Next]_vars

Fairness ==
    /\ WF_vars(FinishWithdraw) /\ WF_vars(FinishCheck)
    /\ WF_vars(FinishDormant)
    /\ WF_vars(CloseHold) /\ WF_vars(ReleaseHolds)
    /\ \A n \in Nodes : WF_vars(ReleaseOne(n)) /\ WF_vars(CheckChanged(n))
                         /\ WF_vars(ActivateDormant(n))

FairSpec == Spec /\ Fairness

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)
TypeOK ==
    /\ scopeState \in [Scopes -> {"declared", "initialized", "requested", "disposed"}]
    /\ held \in BOOLEAN
    /\ lateAct \in BOOLEAN
    /\ registered \in [Nodes -> BOOLEAN]
    /\ active \in [Nodes -> BOOLEAN]
    /\ blocked \in [Nodes -> BOOLEAN]
    /\ committed \in [Nodes -> [Keys -> Nodes \cup {NoNode}]]
    /\ withdrawing \subseteq Nodes /\ permanent \subseteq Nodes
    /\ pc \in {"idle", "withdraw", "check", "dormant"}
    /\ passes \in 0..MaxPasses
    /\ removed \subseteq Nodes
    /\ unsettled \subseteq Nodes

Quiescent == pc = "idle"

\* A read edge n -> m: n reads the key that m publishes.
\* The structural edge ignores membership changes: it uses every candidate.
StaticReads(n) ==
    T.req[n] \cup T.opt[n] \cup
    UNION {MemKeys(Candidates(n, c)) : c \in ColReq(n) \cup ColOpt(n)}
ReadsFrom(n, m) == T.pub[m] # NoNode /\ T.pub[m] \in StaticReads(n)
RECURSIVE Reach(_, _)
Reach(n, seen) ==
    LET next == {m \in Nodes : \E x \in seen \cup {n} : ReadsFrom(x, m)}
    IN IF next \subseteq seen THEN seen ELSE Reach(n, seen \cup next)
\* The read graph has a cycle: the spec does not promise convergence.
HasFeedback == \E n \in Nodes : n \in Reach(n, {})

\* At quiescence, active committed views equal the resolved targets, and
\* every eligible node that did not fail is active. Only a structure with
\* feedback may stop at MaxPasses without that (reported as diverged).
StableTargets ==
    (Quiescent /\ ~(diverged /\ HasFeedback)) =>
        /\ \A n \in Nodes : (active[n] /\ registered[n]) => ~Changed(n)
        /\ \A n \in Nodes : ~Eligible(n)

\* An absent optional read alone never keeps a node dormant.
OptionalEligibility ==
    Quiescent =>
        \A n \in Nodes :
            (/\ registered[n] /\ ~active[n] /\ ~blocked[n]
             /\ Live(T.scope[n]) /\ n \notin failedNow
             /\ \A k \in ReqKeys(n) : Resolve(T.scope[n], k, n) # NoNode)
            => FALSE

\* Every value an active node read is still alive: a publisher releases
\* only after its dependents.
DependentFirst ==
    \A n \in Nodes : active[n] =>
        \A k \in Keys : committed[n][k] \in {NoNode} \cup {m \in Nodes : active[m]}

\* A reader sees only publishers of its own scope or an ancestor, so a
\* contribution of a child scope never reaches a reader of the parent.
VisibleBinding ==
    \A n \in Nodes, k \in Keys :
        committed[n][k] = NoNode \/
        T.scope[committed[n][k]] \in Ancestors(T.scope[n])

UniqueBinding ==
    \A s \in Scopes, k \in Keys :
        Cardinality({n \in Nodes : T.scope[n] = s /\ T.pub[n] = k
                                    /\ registered[n] /\ active[n]}) <= 1

NoResurrection ==
    \A n \in removed : (n \in withdrawing) \/ (~registered[n] /\ ~active[n])

NoNeutralReload == ~neutral

\* A member of an initialize never stays stale at the bound: that call
\* fails and rolls back instead of succeeding.
UnsettledFailsInit == (Quiescent /\ diverged) => unsettled = {}

\* No node of a scope whose disposal was requested activates, also while the
\* hold delays the disposal and a publisher of the parent withdraws and returns.
NoActivationWhileRequested == ~lateAct

\* Liveness: every transaction finishes.
Settles == []<>Quiescent

\* Liveness with the hold, under FairSpec: a requested child scope is disposed
\* once the hold closes.
HeldDisposalCompletes ==
    (scopeState["child"] = "requested") ~> (scopeState["child"] = "disposed")
=============================================================================
