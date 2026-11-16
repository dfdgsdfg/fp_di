---------------------------- MODULE Cancellation ----------------------------
(***************************************************************************)
(* Cancellation of activation episodes.                                    *)
(*                                                                         *)
(* This module models the design in specs/runtime/lifecycle/spec.md        *)
(* "Cancellation", which the runtime implements (cancellation.dart,        *)
(* runtime.dart). The model is more general than the runtime: its          *)
(* composite regions that catch a failure have no runtime counterpart,     *)
(* whose regions are the episode root and each Lazy creation.              *)
(* `Fault = "NoSignal"` is the behavior before cancellation existed.       *)
(*                                                                         *)
(* A mutation queue serializes transactions. An `init` transaction runs    *)
(* activation episodes (initialize and reconcile). A `dispose` transaction  *)
(* deactivates and removes nodes. A host disposal request completes the     *)
(* episode signals at once and only then enqueues its transaction.         *)
(*                                                                         *)
(* Holds of a disposal (R-UC-RT-LC-034). A request of a target that holds  *)
(* an open hold of its subtree cancels the episodes of the target at once  *)
(* and then waits outside the queue. The queue runs other transactions     *)
(* during the wait, and the setups of other owners enqueue and run. When   *)
(* the last hold of the subtree closes, ReleaseHolds enqueues the disposal *)
(* transaction, and the transaction takes its id at that point. The wait   *)
(* starts no setup of the target and no activation of its nodes.          *)
(*                                                                         *)
(* Code correspondence (abstraction map, not a refinement proof):          *)
(*   Initialize         Scope.initialize call (scope.dart)                 *)
(*   RequestDispose     ComponentNode.dispose / Scope.dispose, before       *)
(*                      _RuntimeMutationQueue.run (scope.dart,              *)
(*                      _disposeNode); with an open hold the request ends   *)
(*                      in the wait (HoldWait)                              *)
(*   CloseHold,         DisposeHold.close, _Runtime.holdClosed; the last    *)
(*   ReleaseHolds       close of the subtree queues the waiting disposal    *)
(*   StartInit,         _RuntimeMutationQueue.run: the queued action        *)
(*   StartDispose       starts (runtime_mutation_queue.dart)                *)
(*   StartEpisode       _Runtime.activate (runtime.dart); one episode is   *)
(*                      one _RuntimeActivation (runtime_activation.dart)   *)
(*   StartStep          interpreter checkpoint and the next step of a      *)
(*                      Dependency chain (dependency.dart)                 *)
(*   Land / Fail /      the future of DiContext.acquire settles            *)
(*   Abort              (runtime_activation.dart, dependency.dart)         *)
(*   ChildEnd,          a Dependency chain with owned steps, the           *)
(*   Resolve            composite failure region (dependency.dart)         *)
(*   Commit             activate: publish staging, set active              *)
(*   ToRollback, Close  activate error path and runCleanups                *)
(*   Release            one DisposeFunction of a lease: rollback in        *)
(*                      activate, or                                       *)
(*                      node.cleanups in deactivate (runtime.dart)         *)
(*   DeactDone,         deactivate, dependents before publishers           *)
(*   FinishDispose      (runtime.dart)                                     *)
(*   FinishInit         end of the init transaction after reconcile        *)
(*                                                                         *)
(* Vocabulary. A "region" is a failure region of the signal tree: the       *)
(* episode root or one child region of a composite chain. The property      *)
(* SignalBeforeInverse speaks of the signal of the region that acquired     *)
(* the lease. It does not mean a Scope. A Scope appears only as the         *)
(* owner set of a disposal request.                                         *)
(*                                                                         *)
(* Abstractions and limits.                                                *)
(*   - One acquisition step is one lease slot. A node runs MaxLeases steps  *)
(*     in order. With Composite, step 1 runs in a child failure region;    *)
(*     step 2 is then the fallback after a caught failure.                 *)
(*   - Every node publishes one key; Reads relates readers to publishers.  *)
(*   - A dispose transaction does not reconcile. Reconcile runs only in an *)
(*     init transaction.                                                   *)
(*   - Release callbacks always succeed (no Blocked state). An activation  *)
(*     failure suppresses retry; the state is collapsed into `supp`.       *)
(*   - Monotonicity of a signal holds by construction: no action resets a  *)
(*     signal inside an episode.                                           *)
(*   - Deactivation keeps the guard "dependents release first". The        *)
(*     lifecycle property DependentFirst is not restated here.             *)
(*   - Quiescent states stutter, so TLC still reports a real deadlock.     *)
(*   - Lazy memoized resources are modeled in Lazy.tla, not here.          *)
(*                                                                         *)
(* Fault selects at most one deliberate defect (negative controls).        *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    NumNodes,    \* nodes 1..NumNodes
    ChildScopes, \* node sets of the child scopes; the root scope owns every node
    ReadPairs,   \* set of {m, p}, m > p: node m requires a key that node p publishes
    MaxEp,       \* activation episodes per node
    MaxLeases,   \* acquisition steps (lease slots) per episode
    MaxTx,       \* host requests (queued transactions) per run
    HeldTargets, \* targets with an open hold at the start; a request that contains one waits
    Kinds,       \* acquisition kinds that occur: subset of {"coop", "uncoop"}
    CanFail,     \* a primitive or a region may fail
    Composite,   \* step 1 runs in a child region of the episode root
    Catch,       \* the composite stage catches its failure (fallback is step 2)
    Fault        \* "none" or one deliberate defect below

Faults == {
    "none",
    "NoSignal",              \* complete the signal only when the disposal transaction runs
    "CommitAfterCancel",     \* commit an activation that settles after the signal
    "SetupAfterCancel",      \* start queued setup for a disposed owner
    "OnlyOwnEpisode",        \* withdrawal signals only the publisher's own episode
    "ChildRollbackFirst",    \* composite stage rolls back before its scope signal
    "RootRollbackFirst",     \* episode root rolls back before its signal
    "KeepEligible",          \* a withdrawal-cancelled node stays eligible
    "CaughtLeaksParent",     \* a caught child failure completes the parent signal
    "SkipCheckpoint",        \* no checkpoint between composition steps
    "SetupWhileHeld",        \* a setup of the held owner starts during the wait
    "OverlapSetup",          \* the next setup does not wait for the queue
    "AbandonUncoop"          \* rollback does not wait for an uncooperative lease
}

ASSUME Fault \in Faults
ASSUME NumNodes \in Nat \ {0}
ASSUME \A s \in ChildScopes : s \subseteq 1..NumNodes
ASSUME \A r \in ReadPairs : r \subseteq 1..NumNodes /\ Cardinality(r) = 2
ASSUME MaxEp \in Nat \ {0} /\ MaxLeases \in Nat \ {0} /\ MaxTx \in Nat \ {0}
ASSUME Kinds \subseteq {"coop", "uncoop"} /\ Kinds # {}
ASSUME CanFail \in BOOLEAN /\ Composite \in BOOLEAN /\ Catch \in BOOLEAN
ASSUME Composite => MaxLeases = 2

Nodes == 1..NumNodes
Slots == 1..MaxLeases
Txs == 1..MaxTx
Leases == Nodes \X (0..MaxEp) \X Slots

NodePhases == {"unreg", "dormant", "setup", "rollback", "active", "deact",
               "awaitW", "removed"}
LeaseStates == {"none", "flight", "held", "released", "void"}
RegionStates == {"none", "open", "ok", "failing", "caught", "failed"}
Causes == {"none", "dispose", "withdraw", "fail"}

VARIABLES
    ph,       \* node phase, see NodePhases
    ep,       \* current episode number of the node (0: none yet)
    rsig,     \* root signal of the current episode is completed
    csig,     \* child region signal is completed (own failure only)
    cst,      \* state of the child region of the current episode
    rcause,   \* why the root signal completed
    supp,     \* retry suppression after an activation failure
    awaitTx,  \* withdrawal transaction a node waits for (0: none)
    wcnt,     \* wcnt[n][d]: cancellations of n by withdrawal request d
    epTx,     \* init transaction that runs the current episode of the node
    rfail,    \* defect only: root failure seen, signal not yet completed
    ls,       \* lease state per <<node, episode, slot>>
    lk,       \* acquisition kind per lease
    rel,      \* release attempts per lease
    tkind,    \* transaction kind: "none" | "init" | "dispose"
    ttgt,     \* transaction target: the node set of the request
    tstat,    \* "none" | "queued" | "running" | "done"
    running,  \* running transactions (one, unless the OverlapSetup defect)
    nextTx,   \* next transaction id
    initReq,  \* nodes with an initialize request
    reqd,     \* nodes whose owner disposal was requested
    held,     \* the open holds, each named by its target
    waiting,  \* requested targets whose disposal waits for a hold, outside the queue
    commitAfterCancel,    \* history: an episode committed after its signal
    setupAfterCancel,     \* history: setup started for a disposed owner
    stepAfterCancel,      \* history: a step started after its region signal
    inverseBeforeSignal,  \* history: a release ran before its region signal
    landedLate            \* history: leases that landed after their signal

nodeVars == <<ph, ep, rsig, csig, cst, rcause, supp, awaitTx, wcnt, epTx, rfail>>
leaseVars == <<ls, lk, rel>>
holdVars == <<held, waiting>>
txVars == <<tkind, ttgt, tstat, running, nextTx, initReq, reqd, held, waiting>>
histVars == <<commitAfterCancel, setupAfterCancel, stepAfterCancel,
              inverseBeforeSignal, landedLate>>
vars == <<nodeVars, leaseVars, txVars, histVars>>

-----------------------------------------------------------------------------
(* Static structure. *)

\* The reader is the larger node of a pair, so readers follow publishers.
Reads == {<<CHOOSE a \in r : \A b \in r : a >= b,
            CHOOSE a \in r : \A b \in r : a <= b>> : r \in ReadPairs}

Direct(S) == {m \in Nodes : \E p \in S : <<m, p>> \in Reads}

\* The set S and every node that reads it, directly or through readers.
Up(S) ==
    LET F[i \in 0..NumNodes] == IF i = 0 THEN S ELSE F[i - 1] \cup Direct(F[i - 1])
    IN F[NumNodes]

\* A disposal request names one node, a child scope, or the root scope
\* (which owns every node).
Targets == ({{n} : n \in Nodes} \cup ChildScopes \cup {Nodes}) \ {{}}

ASSUME HeldTargets \subseteq Targets

\* A hold of a target H delays the request of every target that contains H.
Blocked(T) == \E H \in held : H \subseteq T

\* The nodes of the requests that wait for a hold.
WaitCover == UNION waiting

RegionOf(k) == IF Composite /\ k = 1 THEN "child" ELSE "root"

-----------------------------------------------------------------------------
(* Derived state. *)

L(n, k) == <<n, ep[n], k>>

\* A child signal completes when its parent signal completes.
SigDone(n, r) == IF r = "root" THEN rsig[n] ELSE rsig[n] \/ csig[n]

InFlight(n) == \E k \in Slots : ls[L(n, k)] = "flight"
HeldAny(n) == \E k \in Slots : ls[L(n, k)] = "held"
Settled(n) == ~InFlight(n)

InitNode(id) == CHOOSE x \in ttgt[id] : TRUE

Eligible(n) ==
    /\ ph[n] = "dormant"
    /\ ~supp[n]
    /\ ep[n] < MaxEp
    /\ (n \notin reqd \/ Fault = "SetupAfterCancel"
        \/ (Fault = "SetupWhileHeld" /\ n \in WaitCover))
    /\ \A p \in Nodes : <<n, p>> \in Reads => ph[p] = "active"

\* The previous steps of the episode are done.
PrevDone(n, k) ==
    \A j \in 1..(k - 1) :
        ls[L(n, j)] = "held" \/ (Composite /\ j = 1 /\ cst[n] = "caught")

StepReady(n, k) ==
    IF ~Composite THEN TRUE
    ELSE IF k = 1 THEN cst[n] = "open"
    ELSE cst[n] \in {"ok", "caught"}

AllStepsDone(n) ==
    /\ ls[L(n, MaxLeases)] = "held"
    /\ PrevDone(n, MaxLeases)
    /\ cst[n] \in {"none", "ok", "caught"}

\* An inverse may start when the region signal is completed. Each
\* rollback-first defect lets the inverse start earlier.
CanInverse(n, r) ==
    \/ SigDone(n, r)
    \/ (Fault = "RootRollbackFirst" /\ rfail[n])
    \/ (Fault = "ChildRollbackFirst" /\ r = "child" /\ cst[n] = "failing")

-----------------------------------------------------------------------------
TypeOK ==
    /\ ph \in [Nodes -> NodePhases]
    /\ ep \in [Nodes -> 0..MaxEp]
    /\ rsig \in [Nodes -> BOOLEAN]
    /\ csig \in [Nodes -> BOOLEAN]
    /\ cst \in [Nodes -> RegionStates]
    /\ rcause \in [Nodes -> Causes]
    /\ supp \in [Nodes -> BOOLEAN]
    /\ awaitTx \in [Nodes -> 0..MaxTx]
    /\ wcnt \in [Nodes -> [Txs -> 0..MaxEp]]
    /\ epTx \in [Nodes -> 0..MaxTx]
    /\ rfail \in [Nodes -> BOOLEAN]
    /\ ls \in [Leases -> LeaseStates]
    /\ lk \in [Leases -> {"coop", "uncoop"}]
    /\ rel \in [Leases -> 0..2]
    /\ tkind \in [Txs -> {"none", "init", "dispose"}]
    /\ ttgt \in [Txs -> SUBSET Nodes]
    /\ tstat \in [Txs -> {"none", "queued", "running", "done"}]
    /\ running \subseteq Txs
    /\ nextTx \in 1..(MaxTx + 1)
    /\ initReq \subseteq Nodes
    /\ reqd \subseteq Nodes
    /\ held \subseteq HeldTargets
    /\ waiting \subseteq Targets
    /\ commitAfterCancel \in BOOLEAN
    /\ setupAfterCancel \in BOOLEAN
    /\ stepAfterCancel \in BOOLEAN
    /\ inverseBeforeSignal \in BOOLEAN
    /\ landedLate \subseteq Leases

Init ==
    /\ ph = [n \in Nodes |-> "unreg"]
    /\ ep = [n \in Nodes |-> 0]
    /\ rsig = [n \in Nodes |-> FALSE]
    /\ csig = [n \in Nodes |-> FALSE]
    /\ cst = [n \in Nodes |-> "none"]
    /\ rcause = [n \in Nodes |-> "none"]
    /\ supp = [n \in Nodes |-> FALSE]
    /\ awaitTx = [n \in Nodes |-> 0]
    /\ wcnt = [n \in Nodes |-> [d \in Txs |-> 0]]
    /\ epTx = [n \in Nodes |-> 0]
    /\ rfail = [n \in Nodes |-> FALSE]
    /\ ls = [l \in Leases |-> "none"]
    /\ lk = [l \in Leases |-> "coop"]
    /\ rel = [l \in Leases |-> 0]
    /\ tkind = [d \in Txs |-> "none"]
    /\ ttgt = [d \in Txs |-> {}]
    /\ tstat = [d \in Txs |-> "none"]
    /\ running = {}
    /\ nextTx = 1
    /\ initReq = {}
    /\ reqd = {}
    /\ held = HeldTargets
    /\ waiting = {}
    /\ commitAfterCancel = FALSE
    /\ setupAfterCancel = FALSE
    /\ stepAfterCancel = FALSE
    /\ inverseBeforeSignal = FALSE
    /\ landedLate = {}

-----------------------------------------------------------------------------
(* Host requests. They are the bounded input dimension (MaxTx). *)

NewTx(kind, tgt) ==
    /\ tkind' = [tkind EXCEPT ![nextTx] = kind]
    /\ ttgt' = [ttgt EXCEPT ![nextTx] = tgt]
    /\ tstat' = [tstat EXCEPT ![nextTx] = "queued"]
    /\ nextTx' = nextTx + 1

Initialize(n) ==
    /\ nextTx + Cardinality(waiting) <= MaxTx
    /\ ph[n] = "unreg" /\ n \notin initReq /\ n \notin reqd
    /\ initReq' = initReq \cup {n}
    /\ NewTx("init", {n})
    /\ UNCHANGED <<nodeVars, leaseVars, running, reqd, histVars, holdVars>>

\* The request completes the signals now, before the transaction is queued.
\* It signals the owner episodes, and the in-flight episodes that read a
\* publisher being withdrawn, transitively. A request that contains an open
\* hold signals the owner episodes only and waits (HoldWait): no transaction
\* exists yet, so its id and the dependents' signals follow at ReleaseHolds.
RequestDispose(T) ==
    /\ T \in Targets
    /\ ~(T \subseteq reqd)
    /\ nextTx + Cardinality(waiting) <= MaxTx
    /\ LET d == nextTx
           W == IF Fault = "OnlyOwnEpisode" \/ Blocked(T) THEN T ELSE Up(T)
           hit(n) == Fault # "NoSignal" /\ n \in W /\ ph[n] = "setup" /\ ~rsig[n]
           dep(n) == hit(n) /\ n \notin T
       IN /\ rsig' = [n \in Nodes |-> IF hit(n) THEN TRUE ELSE rsig[n]]
          /\ rcause' = [n \in Nodes |->
                          IF hit(n) THEN (IF n \in T THEN "dispose" ELSE "withdraw")
                          ELSE rcause[n]]
          /\ awaitTx' = [n \in Nodes |-> IF dep(n) THEN d ELSE awaitTx[n]]
          /\ wcnt' = [n \in Nodes |->
                        IF dep(n) THEN [wcnt[n] EXCEPT ![d] = @ + 1] ELSE wcnt[n]]
    /\ reqd' = reqd \cup T
    /\ IF Blocked(T)
       THEN /\ waiting' = waiting \cup {T}
            /\ UNCHANGED <<tkind, ttgt, tstat, nextTx>>
       ELSE /\ NewTx("dispose", T)
            /\ UNCHANGED waiting
    /\ UNCHANGED <<ph, ep, csig, cst, supp, epTx, rfail, leaseVars, running,
                   initReq, held, histVars>>

\* A hold closes. It only changes the set of open holds.
CloseHold(H) ==
    /\ H \in held
    /\ held' = held \ {H}
    /\ UNCHANGED <<nodeVars, leaseVars, tkind, ttgt, tstat, running, nextTx,
                   initReq, reqd, waiting, histVars>>

\* The last hold of the subtree closed: the waiting disposal enters the queue
\* and takes its id now. As at a request without a hold, the enqueue signals
\* the in-flight episodes that read the target, transitively.
ReleaseHolds(T) ==
    /\ T \in waiting /\ ~Blocked(T)
    /\ LET d == nextTx
           W == IF Fault = "OnlyOwnEpisode" THEN {} ELSE Up(T) \ T
           hit(n) == Fault # "NoSignal" /\ n \in W /\ ph[n] = "setup" /\ ~rsig[n]
       IN /\ rsig' = [n \in Nodes |-> IF hit(n) THEN TRUE ELSE rsig[n]]
          /\ rcause' = [n \in Nodes |-> IF hit(n) THEN "withdraw" ELSE rcause[n]]
          /\ awaitTx' = [n \in Nodes |-> IF hit(n) THEN d ELSE awaitTx[n]]
          /\ wcnt' = [n \in Nodes |->
                        IF hit(n) THEN [wcnt[n] EXCEPT ![d] = @ + 1] ELSE wcnt[n]]
    /\ waiting' = waiting \ {T}
    /\ NewTx("dispose", T)
    /\ UNCHANGED <<ph, ep, csig, cst, supp, epTx, rfail, leaseVars, running,
                   initReq, reqd, held, histVars>>

\* Serialized mutation queue: first queued transaction starts when none runs.
\* The OverlapSetup defect lets a queued init bypass the queue.
CanStart(id) ==
    /\ tstat[id] = "queued"
    /\ \/ /\ running = {}
          /\ \A j \in Txs : tstat[j] = "queued" => id <= j
       \/ /\ Fault = "OverlapSetup"
          /\ tkind[id] = "init"
          /\ running # {}

\* Queued setup for a disposed owner never runs; initialize fails with
\* ActivationCanceledException.
StartInit(id) ==
    /\ CanStart(id) /\ tkind[id] = "init"
    /\ LET n == InitNode(id) IN
       IF n \in reqd /\ Fault # "SetupAfterCancel"
          /\ ~(Fault = "SetupWhileHeld" /\ n \in WaitCover)
       THEN /\ tstat' = [tstat EXCEPT ![id] = "done"]
            /\ UNCHANGED <<ph, running>>
       ELSE /\ tstat' = [tstat EXCEPT ![id] = "running"]
            /\ running' = running \cup {id}
            /\ ph' = [ph EXCEPT ![n] = "dormant"]
    /\ UNCHANGED <<ep, rsig, csig, cst, rcause, supp, awaitTx, wcnt, epTx, rfail,
                   leaseVars, tkind, ttgt, nextTx, initReq, reqd, histVars,
                   holdVars>>

\* Reconcile inside a running init transaction starts an episode.
\* A read of a publisher whose withdrawal is queued completes the reader's
\* root signal at once.
StartEpisode(n, id) ==
    /\ tstat[id] = "running" /\ tkind[id] = "init"
    /\ Eligible(n)
    /\ LET pend == {d \in Txs : /\ tkind[d] = "dispose" /\ tstat[d] = "queued"
                                /\ n \in Up(ttgt[d]) \ ttgt[d]}
           d0 == CHOOSE d \in pend : \A e \in pend : d <= e
           cancelNow == pend # {}
       IN /\ ph' = [ph EXCEPT ![n] = "setup"]
          /\ ep' = [ep EXCEPT ![n] = @ + 1]
          /\ rsig' = [rsig EXCEPT ![n] = cancelNow]
          /\ csig' = [csig EXCEPT ![n] = FALSE]
          /\ cst' = [cst EXCEPT ![n] = IF Composite THEN "open" ELSE "none"]
          /\ rcause' = [rcause EXCEPT ![n] = IF cancelNow THEN "withdraw" ELSE "none"]
          /\ awaitTx' = [awaitTx EXCEPT ![n] = IF cancelNow THEN d0 ELSE 0]
          /\ wcnt' = IF cancelNow THEN [wcnt EXCEPT ![n][d0] = @ + 1] ELSE wcnt
          /\ rfail' = [rfail EXCEPT ![n] = FALSE]
          /\ epTx' = [epTx EXCEPT ![n] = id]
          /\ setupAfterCancel' = (setupAfterCancel \/ n \in reqd)
    /\ UNCHANGED <<supp, leaseVars, txVars, commitAfterCancel, stepAfterCancel,
                   inverseBeforeSignal, landedLate>>

\* Checkpoint, then the next primitive. The interpreter checks the signal of
\* the enclosing region before each step.
StartStep(n) ==
    /\ ph[n] = "setup"
    /\ \E k \in Slots :
         /\ ls[L(n, k)] = "none"
         /\ PrevDone(n, k)
         /\ StepReady(n, k)
         /\ ~SigDone(n, RegionOf(k)) \/ (Fault = "SkipCheckpoint" /\ k > 1)
         /\ \E kind \in Kinds :
              /\ lk' = [lk EXCEPT ![L(n, k)] = kind]
              /\ ls' = [ls EXCEPT ![L(n, k)] = "flight"]
         /\ stepAfterCancel' = (stepAfterCancel \/ SigDone(n, RegionOf(k)))
    /\ UNCHANGED <<nodeVars, rel, txVars, commitAfterCancel, setupAfterCancel,
                   inverseBeforeSignal, landedLate>>

\* An acquisition returns a lease. The lease stays owned even after the signal.
Land(l) ==
    /\ ls[l] = "flight"
    /\ ls' = [ls EXCEPT ![l] = "held"]
    /\ landedLate' = IF l[2] # ep[l[1]] \/ SigDone(l[1], RegionOf(l[3]))
                       THEN landedLate \cup {l} ELSE landedLate
    /\ UNCHANGED <<nodeVars, lk, rel, txVars, commitAfterCancel, setupAfterCancel,
                   stepAfterCancel, inverseBeforeSignal>>

\* A cooperative acquisition unwinds its own partial work once its region
\* signal is completed. No lease results (atomic primitive).
Abort(l) ==
    /\ ls[l] = "flight" /\ lk[l] = "coop"
    /\ l[2] # ep[l[1]] \/ SigDone(l[1], RegionOf(l[3]))
    /\ ls' = [ls EXCEPT ![l] = "void"]
    /\ UNCHANGED <<nodeVars, lk, rel, txVars, histVars>>

\* A primitive fails. The failure completes its region signal, before any
\* inverse of that region. A failure in the child region propagates later.
Fail(l) ==
    LET n == l[1] IN
    /\ CanFail
    /\ ls[l] = "flight"
    /\ ls' = [ls EXCEPT ![l] = "void"]
    /\ IF l[2] = ep[n] /\ ph[n] = "setup"
       THEN IF RegionOf(l[3]) = "root"
            THEN IF Fault = "RootRollbackFirst"
                 THEN /\ rfail' = [rfail EXCEPT ![n] = TRUE]
                      /\ UNCHANGED <<rsig, csig, cst, rcause>>
                 ELSE /\ rsig' = [rsig EXCEPT ![n] = TRUE]
                      /\ rcause' = IF rsig[n] THEN rcause
                                   ELSE [rcause EXCEPT ![n] = "fail"]
                      /\ UNCHANGED <<csig, cst, rfail>>
            ELSE /\ IF cst[n] = "open"
                    THEN /\ cst' = [cst EXCEPT ![n] = "failing"]
                         /\ csig' = IF Fault = "ChildRollbackFirst" THEN csig
                                    ELSE [csig EXCEPT ![n] = TRUE]
                    ELSE UNCHANGED <<cst, csig>>
                 /\ UNCHANGED <<rsig, rcause, rfail>>
       ELSE UNCHANGED <<rsig, csig, cst, rcause, rfail>>
    /\ UNCHANGED <<ph, ep, supp, awaitTx, wcnt, epTx, lk, rel, txVars, histVars>>

Settle(l) == Land(l) \/ Abort(l) \/ Fail(l)

\* The child region body ends. It completes or throws after its step landed.
ChildEnd(n) ==
    /\ Composite /\ ph[n] = "setup" /\ cst[n] = "open"
    /\ ls[L(n, 1)] = "held"
    /\ ~SigDone(n, "child")
    /\ \/ cst' = [cst EXCEPT ![n] = "ok"]
          /\ UNCHANGED csig
       \/ /\ CanFail
          /\ cst' = [cst EXCEPT ![n] = "failing"]
          /\ csig' = IF Fault = "ChildRollbackFirst" THEN csig
                     ELSE [csig EXCEPT ![n] = TRUE]
    /\ UNCHANGED <<ph, ep, rsig, rcause, supp, awaitTx, wcnt, epTx, rfail,
                   leaseVars, txVars, histVars>>

\* Defect only: the child scope signal completes after its inverse.
LateChildSignal(n) ==
    /\ Fault = "ChildRollbackFirst"
    /\ cst[n] = "failing" /\ ~csig[n]
    /\ csig' = [csig EXCEPT ![n] = TRUE]
    /\ UNCHANGED <<ph, ep, rsig, cst, rcause, supp, awaitTx, wcnt, epTx, rfail,
                   leaseVars, txVars, histVars>>

\* Defect only: the root signal completes after its inverse.
LateRootSignal(n) ==
    /\ Fault = "RootRollbackFirst"
    /\ rfail[n] /\ ~rsig[n]
    /\ rsig' = [rsig EXCEPT ![n] = TRUE]
    /\ rcause' = [rcause EXCEPT ![n] = "fail"]
    /\ UNCHANGED <<ph, ep, csig, cst, supp, awaitTx, wcnt, epTx, rfail,
                   leaseVars, txVars, histVars>>

\* After the child rollback, the stage either catches its failure or lets it
\* propagate. Only propagation completes the enclosing (root) signal.
Resolve(n) ==
    /\ ph[n] = "setup" /\ cst[n] = "failing" /\ ~rsig[n]
    /\ csig[n]
    /\ ls[L(n, 1)] \in {"void", "released"}
    /\ IF Catch
       THEN /\ cst' = [cst EXCEPT ![n] = "caught"]
            /\ IF Fault = "CaughtLeaksParent"
               THEN /\ rsig' = [rsig EXCEPT ![n] = TRUE]
                    /\ rcause' = [rcause EXCEPT ![n] = "fail"]
               ELSE UNCHANGED <<rsig, rcause>>
       ELSE /\ cst' = [cst EXCEPT ![n] = "failed"]
            /\ rsig' = [rsig EXCEPT ![n] = TRUE]
            /\ rcause' = [rcause EXCEPT ![n] = "fail"]
    /\ UNCHANGED <<ph, ep, csig, supp, awaitTx, wcnt, epTx, rfail, leaseVars,
                   txVars, histVars>>

\* The commit publishes. An activation with a completed signal never commits.
Commit(n) ==
    /\ ph[n] = "setup"
    /\ AllStepsDone(n)
    /\ ~rsig[n] \/ Fault = "CommitAfterCancel"
    /\ ph' = [ph EXCEPT ![n] = "active"]
    /\ commitAfterCancel' = (commitAfterCancel \/ rsig[n] \/ n \in reqd)
    /\ UNCHANGED <<ep, rsig, csig, cst, rcause, supp, awaitTx, wcnt, epTx, rfail,
                   leaseVars, txVars, setupAfterCancel, stepAfterCancel,
                   inverseBeforeSignal, landedLate>>

\* Rollback waits for every acquisition to settle, then starts.
ToRollback(n) ==
    /\ ph[n] = "setup"
    /\ rsig[n] \/ (Fault = "RootRollbackFirst" /\ rfail[n])
    /\ Settled(n)
       \/ (Fault = "AbandonUncoop"
           /\ \A k \in Slots : ls[L(n, k)] = "flight" => lk[L(n, k)] = "uncoop")
    /\ ph' = [ph EXCEPT ![n] = "rollback"]
    /\ UNCHANGED <<ep, rsig, csig, cst, rcause, supp, awaitTx, wcnt, epTx, rfail,
                   leaseVars, txVars, histVars>>

\* One release attempt per lease, in reverse slot order. The signal of the
\* region that acquired the lease comes first. Leases of a closing episode
\* are released in rollback, in a failing child region, or in deactivation.
\* Deactivation releases dependents before publishers. The lifecycle
\* property DependentFirst owns that order; this model only keeps the guard
\* so that cancellation runs in the accepted order.
Release(l) ==
    LET n == l[1] k == l[3] IN
    /\ ls[l] = "held" /\ l[2] = ep[n]
    /\ \A j \in Slots : j > k => ls[<<n, ep[n], j>>] \notin {"held", "flight"}
    /\ \/ ph[n] = "rollback"
       \/ /\ ph[n] = "setup" /\ RegionOf(k) = "child" /\ cst[n] = "failing"
       \/ /\ ph[n] = "deact"
          /\ \A m \in Nodes : <<m, n>> \in Reads => ph[m] # "deact"
    /\ CanInverse(n, RegionOf(k))
    /\ ls' = [ls EXCEPT ![l] = "released"]
    /\ rel' = [rel EXCEPT ![l] = @ + 1]
    /\ inverseBeforeSignal' = (inverseBeforeSignal \/ ~SigDone(n, RegionOf(k)))
    /\ UNCHANGED <<nodeVars, lk, txVars, commitAfterCancel, setupAfterCancel,
                   stepAfterCancel, landedLate>>

\* The rolled-back episode closes. A node cancelled by a withdrawal request
\* waits for that withdrawal; it is not eligible meanwhile.
Close(n) ==
    /\ ph[n] = "rollback"
    /\ ~HeldAny(n)
    /\ Settled(n) \/ Fault = "AbandonUncoop"
    /\ ~(rfail[n] /\ ~rsig[n])
    /\ ph' = [ph EXCEPT ![n] =
                IF rcause[n] = "withdraw" /\ n \notin reqd /\ Fault # "KeepEligible"
                THEN "awaitW" ELSE "dormant"]
    /\ supp' = [supp EXCEPT ![n] = @ \/ rcause[n] = "fail"]
    /\ UNCHANGED <<ep, rsig, csig, cst, rcause, awaitTx, wcnt, epTx, rfail,
                   leaseVars, txVars, histVars>>

\* The init transaction ends when reconcile is stable and no episode runs.
FinishInit(id) ==
    /\ tstat[id] = "running" /\ tkind[id] = "init"
    /\ \A n \in Nodes : ~(ph[n] \in {"setup", "rollback"} /\ epTx[n] = id)
    /\ \A n \in Nodes : ~Eligible(n)
    /\ tstat' = [tstat EXCEPT ![id] = "done"]
    /\ running' = running \ {id}
    /\ UNCHANGED <<nodeVars, leaseVars, tkind, ttgt, nextTx, initReq, reqd, histVars,
                   holdVars>>

\* The dispose transaction begins deactivation: the root signal of every
\* active episode completes before its first inverse. Dormant targets go away.
StartDispose(id) ==
    /\ CanStart(id) /\ tkind[id] = "dispose"
    /\ LET T == ttgt[id]
           W == Up(T)
           act(n) == n \in W /\ ph[n] = "active"
           rm(n) == n \in T /\ ph[n] \in {"unreg", "dormant", "awaitW"}
       IN /\ ph' = [n \in Nodes |-> IF act(n) THEN "deact"
                                    ELSE IF rm(n) THEN "removed" ELSE ph[n]]
          /\ rsig' = [n \in Nodes |-> IF act(n) THEN TRUE ELSE rsig[n]]
          /\ rcause' = [n \in Nodes |-> IF act(n) THEN "dispose" ELSE rcause[n]]
    /\ tstat' = [tstat EXCEPT ![id] = "running"]
    /\ running' = running \cup {id}
    /\ UNCHANGED <<ep, csig, cst, supp, awaitTx, wcnt, epTx, rfail, leaseVars,
                   tkind, ttgt, nextTx, initReq, reqd, histVars, holdVars>>

\* All leases of a deactivated episode were released.
DeactDone(n) ==
    /\ ph[n] = "deact"
    /\ ~HeldAny(n) /\ Settled(n)
    /\ ph' = [ph EXCEPT ![n] = IF n \in reqd THEN "removed" ELSE "dormant"]
    /\ UNCHANGED <<ep, rsig, csig, cst, rcause, supp, awaitTx, wcnt, epTx, rfail,
                   leaseVars, txVars, histVars>>

\* The withdrawal finishes: nodes it cancelled leave awaitingWithdrawal.
FinishDispose(id) ==
    /\ tstat[id] = "running" /\ tkind[id] = "dispose"
    /\ \A n \in Nodes : ph[n] # "deact"
    /\ tstat' = [tstat EXCEPT ![id] = "done"]
    /\ running' = running \ {id}
    /\ ph' = [n \in Nodes |-> IF ph[n] = "awaitW" /\ awaitTx[n] = id
                               THEN "dormant" ELSE ph[n]]
    /\ UNCHANGED <<ep, rsig, csig, cst, rcause, supp, awaitTx, wcnt, epTx, rfail,
                   leaseVars, tkind, ttgt, nextTx, initReq, reqd, histVars,
                   holdVars>>

Quiescent ==
    /\ waiting = {}
    /\ \A id \in Txs : tstat[id] \notin {"queued", "running"}
    /\ \A n \in Nodes : ph[n] \notin {"setup", "rollback", "deact"}

Runtime ==
    \/ \E id \in Txs : StartInit(id) \/ StartDispose(id)
                       \/ FinishInit(id) \/ FinishDispose(id)
    \/ \E T \in Targets : ReleaseHolds(T)
    \/ \E n \in Nodes : \E id \in Txs : StartEpisode(n, id)
    \/ \E n \in Nodes : StartStep(n) \/ ChildEnd(n) \/ Resolve(n)
                        \/ LateChildSignal(n) \/ LateRootSignal(n)
                        \/ Commit(n) \/ ToRollback(n) \/ Close(n) \/ DeactDone(n)
    \/ \E l \in Leases : Settle(l) \/ Release(l)

Host ==
    \/ \E n \in Nodes : Initialize(n)
    \/ \E T \in Targets : RequestDispose(T)
    \/ \E H \in HeldTargets : CloseHold(H)

Next ==
    \/ Host
    \/ Runtime
    \/ Quiescent /\ UNCHANGED vars

Spec == Init /\ [][Next]_vars

\* Liveness assumptions: callbacks settle and enabled runtime steps run.
\* Host requests are finite (MaxTx) and receive no fairness. Every runtime
\* step advances a bounded measure, so one weak-fairness condition on the
\* whole runtime suffices.
FairSpec == Spec /\ WF_vars(Runtime)

\* A hold closes eventually, and the runtime then releases the wait.
HeldFairSpec == FairSpec /\ \A H \in HeldTargets : WF_vars(CloseHold(H))

-----------------------------------------------------------------------------
(* Safety properties (R-UC-RT-LC-008 unless noted). *)

\* A disposal request completes the episode signal in the request step.
CancelPrompt ==
    \A n \in reqd : ph[n] = "setup" => rsig[n]

NoCommitAfterCancel == ~commitAfterCancel

NoSetupAfterCancel == ~setupAfterCancel

\* A queued withdrawal has cancelled every in-flight episode that reads
\* the publisher, transitively.
CancelPropagatesToDependents ==
    \A d \in Txs :
        (tkind[d] = "dispose" /\ tstat[d] = "queued") =>
            \A n \in Up(ttgt[d]) : ph[n] = "setup" => rsig[n]

SignalBeforeInverse == ~inverseBeforeSignal

NoStepAfterCancel == ~stepAfterCancel

\* Each withdrawal cancels a node at most once while it is pending.
NoCancelLivelock ==
    \A n \in Nodes : \A d \in Txs : wcnt[n][d] <= 1

\* A caught failure leaves the parent signal alone. The parent signal may
\* complete after the catch only because a request cancelled the parent or
\* because the fallback step itself failed.
CaughtFailureIsolated ==
    \A n \in Nodes :
        (cst[n] = "caught" /\ rsig[n]) =>
            \/ rcause[n] \in {"dispose", "withdraw"}
            \/ ls[L(n, MaxLeases)] = "void"

\* A setup that enters the queue after a disposal transaction starts after that
\* disposal finished. A disposal waits for its holds outside the queue and takes
\* its id when it enters, so the setups of other owners that enqueued during the
\* wait have smaller ids and are not restricted.
CleanupBeforeNextSetup ==
    \A n \in Nodes :
        ph[n] \in {"setup", "rollback"} =>
            \A d \in Txs : (tkind[d] = "dispose" /\ d < epTx[n]) => tstat[d] = "done"

LiveOwner(l) ==
    /\ l[2] = ep[l[1]]
    /\ ph[l[1]] \in {"setup", "rollback", "active", "deact"}

\* Every acquired or in-flight lease belongs to a live episode and is
\* released exactly once.
LeaseAccounted ==
    \A l \in Leases :
        /\ ls[l] \in {"held", "flight"} => LiveOwner(l)
        /\ ls[l] = "released" => rel[l] = 1

ReleaseAtMostOnce == \A l \in Leases : rel[l] <= 1

\* The queue admits one transaction at a time.
SingleTransaction == Cardinality(running) <= 1

-----------------------------------------------------------------------------
(* Reachability witnesses. A witness is violated when the behavior occurs. *)

WitnessCommit == \A n \in Nodes : ph[n] # "active"

WitnessCancelledRollback ==
    \A n \in Nodes :
        ~(rcause[n] = "dispose" /\ ph[n] = "dormant"
          /\ \E k \in Slots : ls[L(n, k)] = "released")

WitnessLateLeaseReleased ==
    \A l \in landedLate : rel[l] = 0

WitnessAwaitingWithdrawal == \A n \in Nodes : ph[n] # "awaitW"

WitnessWithdrawalThenDormant ==
    \A n \in Nodes :
        ~(ph[n] = "dormant" /\ rcause[n] = "withdraw" /\ ep[n] > 0
          /\ awaitTx[n] > 0 /\ tstat[awaitTx[n]] = "done")

WitnessCaughtCommit == \A n \in Nodes : ~(ph[n] = "active" /\ cst[n] = "caught")

WitnessSkippedSetup ==
    \A id \in Txs :
        ~(tkind[id] = "init" /\ tstat[id] = "done" /\ ph[InitNode(id)] = "unreg")

\* A setup requested after a disposal ran, with that disposal finished.
WitnessSetupAfterDisposal ==
    \A n \in Nodes :
        ~(ph[n] = "setup" /\ \E d \in Txs : tkind[d] = "dispose" /\ d < epTx[n])

\* An in-flight episode was cancelled as a transitive dependent of a withdrawn
\* publisher: it reads the publisher through another node only.
WitnessTransitiveCancel ==
    \A n \in Nodes :
        ~(rcause[n] = "withdraw" /\ ep[n] > 0 /\ ls[L(n, 1)] # "none"
          /\ \E d \in Txs : /\ wcnt[n][d] > 0
                            /\ n \in Up(ttgt[d]) \ (ttgt[d] \cup Direct(ttgt[d])))

\* Liveness: a requested disposal finishes under FairSpec.
DisposalCompletes ==
    \A d \in Txs :
        (tkind[d] = "dispose" /\ tstat[d] = "queued") ~> (tstat[d] = "done")

\* Liveness with holds, under HeldFairSpec: a waiting request enters the queue
\* once its holds close, and every queued disposal finishes.
HeldDisposalCompletes ==
    /\ (waiting # {}) ~> (waiting = {})
    /\ DisposalCompletes

=============================================================================
