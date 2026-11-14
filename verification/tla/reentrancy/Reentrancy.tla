----------------------------- MODULE Reentrancy -----------------------------
(***************************************************************************)
(* Transaction identity in the zone of a callback.                        *)
(*                                                                         *)
(* Mutations run one at a time on the runtime queue. A transaction may    *)
(* register a callback, such as a stream listener in a `create`, which    *)
(* keeps the identity of that transaction in its zone. The callback fires *)
(* at any later time and requests a mutation. The request is reentrant    *)
(* only while the callback's own transaction runs; a callback of a        *)
(* finished transaction queues, also when it fires during a later one.    *)
(*                                                                         *)
(* Code correspondence (abstraction map, not a refinement proof):          *)
(*   HostRequest   a host calls initialize or dispose:                     *)
(*                 _RuntimeMutationQueue.run                               *)
(*   Start         the queued action starts in a new _RuntimeMutation      *)
(*   Register      a create registers a callback in the mutation zone     *)
(*   Fire          the callback runs and calls initialize or dispose;     *)
(*                 _RuntimeMutationQueue.inMutation reads its             *)
(*                 _RuntimeMutation                                       *)
(*   Finish        the action returns; _RuntimeMutation.running = false    *)
(*                                                                         *)
(* Fault selects at most one deliberate defect (negative controls).        *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    MaxTx,  \* transactions that can exist, the host's and the callbacks'
    Fault   \* "none" or one deliberate defect below

Faults == {
    "none",
    "RuntimeIdentity", \* the zone marks the runtime: every callback is reentrant
    "NoCheck",         \* no callback is reentrant, even in its own transaction
    "RunNow"           \* a callback's mutation starts at once, not on the queue
}

ASSUME Fault \in Faults
ASSUME MaxTx \in Nat /\ MaxTx >= 2

Tx == 1..MaxTx
None == 0

VARIABLES
    tx,        \* [Tx -> "unused" | "queued" | "running" | "finished"]
    queue,     \* the queued transactions, in order
    cb,        \* [Tx -> "none" | "registered" | "fired"]: callback of t
    firedIn,   \* [Tx -> "none" | "own" | "later" | "during"]: when it fired,
               \* in its own transaction, idle, or during another one
    result,    \* [Tx -> "none" | "rejected" | "queued"]: its request
    awaits,    \* [Tx -> Tx \cup {None}]: t waits for the request it made
    nextTx     \* the next unused transaction

vars == <<tx, queue, cb, firedIn, result, awaits, nextTx>>

Running == {t \in Tx : tx[t] = "running"}

Init ==
    /\ tx = [t \in Tx |-> "unused"]
    /\ queue = <<>>
    /\ cb = [t \in Tx |-> "none"]
    /\ firedIn = [t \in Tx |-> "none"]
    /\ result = [t \in Tx |-> "none"]
    /\ awaits = [t \in Tx |-> None]
    /\ nextTx = 1

\* A new mutation joins the queue, or starts at once with RunNow.
Enqueue(n, now) ==
    /\ tx' = [tx EXCEPT ![n] = IF now THEN "running" ELSE "queued"]
    /\ queue' = IF now THEN queue ELSE Append(queue, n)
    /\ nextTx' = nextTx + 1

HostRequest ==
    /\ nextTx <= MaxTx
    /\ Enqueue(nextTx, FALSE)
    /\ UNCHANGED <<cb, firedIn, result, awaits>>

Start ==
    /\ Running = {}
    /\ queue # <<>>
    /\ tx' = [tx EXCEPT ![Head(queue)] = "running"]
    /\ queue' = Tail(queue)
    /\ UNCHANGED <<cb, firedIn, result, awaits, nextTx>>

Register(t) ==
    /\ tx[t] = "running"
    /\ cb[t] = "none"
    /\ cb' = [cb EXCEPT ![t] = "registered"]
    /\ UNCHANGED <<tx, queue, firedIn, result, awaits, nextTx>>

\* The callback of t fires. Its zone holds t; the request is reentrant when
\* t still runs. A transaction that fired its own callback may await the
\* result, as a create that awaits initialize() would.
Fire(t) ==
    /\ cb[t] = "registered"
    /\ LET own == tx[t] = "running"
           reentrant == CASE Fault = "RuntimeIdentity" -> TRUE
                          [] Fault = "NoCheck" -> FALSE
                          [] OTHER -> own
       IN /\ cb' = [cb EXCEPT ![t] = "fired"]
          /\ firedIn' = [firedIn EXCEPT ![t] =
                           CASE own -> "own"
                             [] Running # {} -> "during"
                             [] OTHER -> "later"]
          /\ IF reentrant
             THEN /\ result' = [result EXCEPT ![t] = "rejected"]
                  /\ UNCHANGED <<tx, queue, awaits, nextTx>>
             ELSE /\ nextTx <= MaxTx
                  /\ result' = [result EXCEPT ![t] = "queued"]
                  /\ Enqueue(nextTx, Fault = "RunNow" /\ Running # {})
                  /\ \E wait \in BOOLEAN :
                       awaits' = [awaits EXCEPT ![t] =
                                    IF own /\ wait THEN nextTx ELSE None]

\* A transaction returns once nothing it awaits is still pending.
Finish(t) ==
    /\ tx[t] = "running"
    /\ IF awaits[t] = None THEN TRUE ELSE tx[awaits[t]] = "finished"
    /\ tx' = [tx EXCEPT ![t] = "finished"]
    /\ UNCHANGED <<queue, cb, firedIn, result, awaits, nextTx>>

Next ==
    \/ HostRequest \/ Start
    \/ \E t \in Tx : Register(t) \/ Fire(t) \/ Finish(t)

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)
TypeOK ==
    /\ tx \in [Tx -> {"unused", "queued", "running", "finished"}]
    /\ cb \in [Tx -> {"none", "registered", "fired"}]
    /\ firedIn \in [Tx -> {"none", "own", "later", "during"}]
    /\ result \in [Tx -> {"none", "rejected", "queued"}]
    /\ awaits \in [Tx -> Tx \cup {None}]

\* A callback that fires while its own transaction runs is rejected.
RunningRejected ==
    \A t \in Tx : firedIn[t] = "own" => result[t] = "rejected"

\* A callback of a finished transaction may request a mutation, also while
\* another transaction runs.
FinishedMayMutate ==
    \A t \in Tx : firedIn[t] \in {"later", "during"} => result[t] = "queued"

\* Mutations run one at a time: a later callback's request queues.
OneRunning == Cardinality(Running) <= 1

\* No running transaction waits for a request queued behind it.
NoSelfWait ==
    \A t \in Tx :
        (tx[t] = "running" /\ awaits[t] # None) => tx[awaits[t]] # "queued"
\* Witness: a finished transaction's callback fires during a later one.
\* Its expected violation shows that the case is reached.
WitnessDuring == \A t \in Tx : firedIn[t] # "during"
=============================================================================
