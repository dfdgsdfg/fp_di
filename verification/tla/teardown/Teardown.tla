------------------------------ MODULE Teardown ------------------------------
(***************************************************************************)
(* Concurrent teardown of a disposed scope.                                *)
(*                                                                         *)
(* The nodes of a disposed scope and its descendants release along the     *)
(* reverse of their committed read graph: a node starts its release once   *)
(* every node that read one of its values has finished its own. Nodes that *)
(* do not wait for each other release at the same time. The dispose        *)
(* functions of one node run one after another, last registered first.     *)
(*                                                                         *)
(* Paper basis: Theorem 16 reverts one accumulator in LIFO order with no   *)
(* hypothesis; Theorem 43 reverts pairwise independent effects in any      *)
(* order; across components a declared coeffect carries the order          *)
(* (dependents release before their provider, Theorem 70). The model       *)
(* checks the ordering mechanism only: that the key graph implies          *)
(* Definition 42 independence stays an author obligation, as for           *)
(* concurrent activation.                                                   *)
(*                                                                         *)
(* Code correspondence (abstraction map, not a refinement proof):          *)
(*   Start        the own runCleanups of a node begins. releaseAlongReads  *)
(*                (runtime_teardown.dart) calls deactivate on a node whose *)
(*                dependents have all finished, so the recursion of        *)
(*                deactivate over dependents does nothing                  *)
(*   FallbackRoot releaseAlongReads when nothing runs and no node is ready *)
(*                (a read cycle): deactivate on the first unstarted node,  *)
(*                the one installed last. Readiness is checked again only  *)
(*                when that call returns, so no other node starts          *)
(*   Walk         the recursion of deactivate: it releases the live        *)
(*                dependents of the node in descending id, depth first,    *)
(*                and skips a dependent on its path (`deactivating`)       *)
(*   BeginOwn     inside the walk, the own runCleanups of a node begins    *)
(*                once no live dependent is off its path                   *)
(*   BeginStep    runCleanups calls the next dispose function (LIFO)       *)
(*   EndStep      that dispose function returns or throws (a dispose       *)
(*                failure)                                                 *)
(*   Finish       deactivate returns: the node's publishers count it done; *)
(*                inside the walk, the recursion returns to the caller     *)
(*   Report       releaseAlongReads joins the dispose failures of each     *)
(*                started call in descending id, whatever order the calls  *)
(*                finished in. A call of the walk collects the dispose     *)
(*                failures of every node it released, in their release     *)
(*                order (owner, bucket)                                    *)
(*                                                                         *)
(* A release is a sequence of steps, not one atomic action, so two         *)
(* releases interleave at every await, as two Dart dispose functions do.   *)
(*                                                                         *)
(* Fault selects at most one deliberate defect (negative controls).        *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Graph,      \* "Diamond" | "Cycle" | "LowReadsHigh"
    Steps,      \* dispose functions per node
    MaxDisposeFailures,  \* dispose functions that may throw
    Fault       \* "none" or one deliberate defect below

Faults == {
    "none",
    "NoWait",          \* a node starts once its dependents have started
    "AnyFallback",     \* the cycle fallback begins any stuck node, unwalked
    "NoFallback",      \* no fallback: a read cycle never starts
    "ParallelSteps",   \* the dispose functions of one node overlap
    "CompletionOrder"  \* dispose failures are reported in the order that
                       \* nodes finish
}
ASSUME Fault \in Faults

(***************************************************************************)
(* Committed read graphs. Reads[n] is the set of nodes whose values node n *)
(* read when it committed. A higher id is a later install.                 *)
(***************************************************************************)
\* 1 publishes; 2 and 3 read 1; 4 reads 2 and 3; 5 is independent.
Diamond == [nodes |-> 1..5,
            reads |-> [n \in 1..5 |->
                         CASE n = 2 -> {1} [] n = 3 -> {1}
                           [] n = 4 -> {2, 3} [] OTHER -> {}]]

\* 1 and 2 read each other through optional reads; 3 reads 1; the cycle
\* reads the publisher 4.
Cycle == [nodes |-> 1..4,
          reads |-> [n \in 1..4 |->
                       CASE n = 1 -> {2, 4} [] n = 2 -> {1}
                         [] n = 3 -> {1} [] OTHER -> {}]]

\* The dependent 1 was installed before its publisher 3, so install order
\* and read order disagree; 2 is independent.
LowReadsHigh == [nodes |-> 1..3,
                 reads |-> [n \in 1..3 |->
                              IF n = 1 THEN {3} ELSE {}]]

G == CASE Graph = "Diamond" -> Diamond
       [] Graph = "Cycle" -> Cycle
       [] Graph = "LowReadsHigh" -> LowReadsHigh

Nodes == G.nodes
Reads(n) == G.reads[n]
Dependents(n) == {d \in Nodes : n \in Reads(d)}

RECURSIVE ReachFrom(_, _)
\* Nodes reachable from the set ns along dependent edges.
ReachFrom(ns, seen) ==
    LET next == seen \cup UNION {Dependents(m) : m \in ns}
    IN IF next = seen THEN seen ELSE ReachFrom(next \ seen, next)

Reach(n) == ReachFrom({n}, {})
\* The strongly connected component of n in the read graph.
Scc(n) == {m \in Nodes : m = n \/ (m \in Reach(n) /\ n \in Reach(m))}

VARIABLES
    state,    \* [Nodes -> {"live", "releasing", "released"}]
    done,     \* [Nodes -> 0..Steps] dispose functions that returned
    running,  \* [Nodes -> 0..Steps] dispose functions in flight
    failed,   \* nodes with at least one dispose failure, in the order that
              \* they failed
    disposeFailures,  \* number of dispose functions that threw
    path,     \* the walk of the cycle fallback, its root first (Seq)
    owner,    \* [Nodes -> Nodes \cup {0}] the call that reports a node
    bucket,   \* [Nodes -> Seq] the failed nodes that a call reports
    order,    \* the own releases, in the order they began (Seq)
    report    \* the dispose failure owners that the teardown reports (Seq)

vars == <<state, done, running, failed, disposeFailures, path, owner, bucket,
          order, report>>

Init ==
    /\ state = [n \in Nodes |-> "live"]
    /\ done = [n \in Nodes |-> 0]
    /\ running = [n \in Nodes |-> 0]
    /\ failed = <<>>
    /\ disposeFailures = 0
    /\ path = <<>>
    /\ owner = [n \in Nodes |-> 0]
    /\ bucket = [n \in Nodes |-> <<>>]
    /\ order = <<>>
    /\ report = <<>>

Releasing == {n \in Nodes : state[n] = "releasing"}
Live == {n \in Nodes : state[n] = "live"}
AllReleased == \A n \in Nodes : state[n] = "released"
Max(ns) == CHOOSE m \in ns : \A o \in ns : o <= m
OnPath(n) == \E i \in 1..Len(path) : path[i] = n
Top == path[Len(path)]

\* Conforming: every dependent has finished. NoWait: every dependent has
\* only started.
Ready(n) ==
    IF Fault = "NoWait"
    THEN \A d \in Dependents(n) : state[d] # "live"
    ELSE \A d \in Dependents(n) : state[d] = "released"

Begin(n, by) ==
    /\ state' = [state EXCEPT ![n] = "releasing"]
    /\ owner' = [owner EXCEPT ![n] = by]
    /\ order' = Append(order, n)

Start(n) ==
    /\ path = <<>>
    /\ state[n] = "live"
    /\ Ready(n)
    /\ Begin(n, n)
    /\ UNCHANGED <<done, running, failed, disposeFailures, path, bucket,
                   report>>

\* Nothing runs, nothing is ready, and no walk is in progress: a read cycle.
Stuck ==
    /\ path = <<>>
    /\ Releasing = {}
    /\ Live # {}
    /\ \A m \in Live : ~Ready(m)

FallbackRoot ==
    /\ Fault \notin {"NoFallback", "AnyFallback"}
    /\ Stuck
    /\ path' = <<Max(Live)>>
    /\ UNCHANGED <<state, done, running, failed, disposeFailures, owner,
                   bucket, order, report>>

\* AnyFallback: the fallback begins the own release of any stuck node.
AnyFallback(n) ==
    /\ Fault = "AnyFallback"
    /\ Stuck
    /\ n \in Live
    /\ Begin(n, n)
    /\ UNCHANGED <<done, running, failed, disposeFailures, path, bucket,
                   report>>

OffPath(t) == {d \in Dependents(t) : state[d] = "live" /\ ~OnPath(d)}

Walk ==
    /\ path # <<>>
    /\ state[Top] = "live"
    /\ OffPath(Top) # {}
    /\ path' = Append(path, Max(OffPath(Top)))
    /\ UNCHANGED <<state, done, running, failed, disposeFailures, owner,
                   bucket, order, report>>

BeginOwn ==
    /\ path # <<>>
    /\ state[Top] = "live"
    /\ OffPath(Top) = {}
    /\ Begin(Top, path[1])
    /\ UNCHANGED <<done, running, failed, disposeFailures, path, bucket,
                   report>>

BeginStep(n) ==
    /\ state[n] = "releasing"
    /\ done[n] + running[n] < Steps
    /\ Fault # "ParallelSteps" => running[n] = 0
    /\ running' = [running EXCEPT ![n] = @ + 1]
    /\ UNCHANGED <<state, done, failed, disposeFailures, path, owner, bucket,
                   order, report>>

InSeq(s, n) == \E i \in 1..Len(s) : s[i] = n

EndStep(n) ==
    /\ running[n] > 0
    /\ running' = [running EXCEPT ![n] = @ - 1]
    /\ done' = [done EXCEPT ![n] = @ + 1]
    /\ \/ UNCHANGED <<failed, disposeFailures, bucket>>
       \/ /\ disposeFailures < MaxDisposeFailures
          /\ disposeFailures' = disposeFailures + 1
          /\ failed' = IF InSeq(failed, n) THEN failed ELSE Append(failed, n)
          /\ bucket' = [bucket EXCEPT ![owner[n]] =
                          IF InSeq(@, n) THEN @ ELSE Append(@, n)]
    /\ UNCHANGED <<state, path, owner, order, report>>

RECURSIVE Desc(_)
\* The nodes of a set in reverse node order.
Desc(ns) == IF ns = {} THEN <<>>
            ELSE LET top == Max(ns) IN <<top>> \o Desc(ns \ {top})

RECURSIVE Cat(_)
\* The buckets of the calls in the sequence s, joined.
Cat(s) == IF s = <<>> THEN <<>> ELSE bucket[Head(s)] \o Cat(Tail(s))

\* What releaseAlongReads reports: the calls in descending id.
Grouped == Cat(Desc(Nodes))

FailedSet == {failed[i] : i \in 1..Len(failed)}

Finish(n) ==
    /\ state[n] = "releasing"
    /\ done[n] = Steps /\ running[n] = 0
    /\ state' = [state EXCEPT ![n] = "released"]
    /\ path' = IF path # <<>> /\ Top = n
               THEN SubSeq(path, 1, Len(path) - 1) ELSE path
    /\ report' = IF \A m \in Nodes \ {n} : state[m] = "released"
                 THEN IF Fault = "CompletionOrder" THEN failed ELSE Grouped
                 ELSE report
    /\ UNCHANGED <<done, running, failed, disposeFailures, owner, bucket,
                   order>>

Next ==
    \/ FallbackRoot \/ Walk \/ BeginOwn
    \/ \E n \in Nodes :
          Start(n) \/ AnyFallback(n) \/ BeginStep(n) \/ EndStep(n) \/ Finish(n)

Spec == Init /\ [][Next]_vars

FairSpec == Spec /\ WF_vars(Next)

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)
TypeOK ==
    /\ state \in [Nodes -> {"live", "releasing", "released"}]
    /\ done \in [Nodes -> 0..Steps]
    /\ running \in [Nodes -> 0..Steps]
    /\ disposeFailures \in 0..MaxDisposeFailures
    /\ owner \in [Nodes -> Nodes \cup {0}]

\* A node releases only after every dependent outside its read cycle has
\* finished, so its release runs while every value it read is alive.
DependentsFirst ==
    \A n \in Nodes : state[n] # "live" =>
        \A d \in Dependents(n) \ Scc(n) : state[d] = "released"

\* The same from the reader's side: while a node releases, every node it
\* read outside its read cycle has not started.
ValuesAlive ==
    \A n \in Releasing :
        \A p \in Reads(n) \ Scc(n) : state[p] = "live"

\* The dispose functions of one node run one at a time, so they run in the
\* reverse of their registration order.
OneStepPerNode == \A n \in Nodes : running[n] <= 1

\* Every dispose function runs exactly once.
EachStepOnce == \A n \in Nodes : state[n] = "released" => done[n] = Steps

\* The report lists the calls in descending id, each with the nodes it
\* released in their release order; it does not depend on the order in
\* which concurrent releases finished.
ReportOrder ==
    AllReleased => /\ report = Grouped
                   /\ {report[i] : i \in 1..Len(report)} = FailedSet

\* The Cycle graph has one schedule: 3 is ready first, then the fallback
\* starts 4 and walks 1 and 2. Its dispose failures report at the place of 4.
\* This is the order that teardown_scheduler_test.dart observes.
CycleSchedule ==
    (Graph = "Cycle" /\ AllReleased) =>
        /\ order = <<3, 2, 1, 4>>
        /\ FailedSet = {1, 4} => report = <<1, 4>>

\* Witness: two releases overlap (expected to be violated).
NoOverlap == Cardinality(Releasing) <= 1

\* Witness: the Cycle graph finishes with the dispose failures of 1 and 4, so
\* CycleSchedule constrains a reachable report (expected to be violated).
NoCycleDisposeFailurePair == ~(AllReleased /\ FailedSet = {1, 4})

TeardownCompletes == <>AllReleased

=============================================================================
