---
type: requirement
title: "DevTools Extension Requirements"
description: "Requirements for the DevTools extension of fp_di and the inspector protocol that a running app serves to it."
tags: [tooling, devtools, observation]
id_prefix: "TL-DT"
depends_on: ["specs/runtime/lifecycle/spec.md", "specs/architecture/spec.md"]
---

# DevTools Extension Requirements

[Design](spec.md) · [Decisions](log.md)

## Problem Statement

An application author who debugs a running app asks three questions: which
scopes and nodes exist now, why a value is missing or failed, and what
changed. The runtime already answers them in code. `Scope.state` returns the
state of each scope and node as an immutable value, `NodeState.missing` lists
the keys that a node waits for, the error of `get` names the failures behind a
key, and `ShapeGraph` draws the graph of a module. An author must still write
code to read those values, and must stop the app to read them again.

Dart DevTools lets a package add a tab that reads a running app through the
VM service. A DevTools extension of `fp_di` shows those answers while the app
runs, with one switch in the app. It must cost nothing in a release build, and
it must not make the core package depend on Flutter.

## Scope

- An inspector in the core package that a debug build of an app serves to DevTools after the app sets one switch.
- A versioned JSON protocol: the live roots, the state tree of a root, the details of one node, the shape of one scope, and events for transitions, errors, and slow mutations.
- A DevTools extension app that shows the scope tree, the nodes of a scope, the details of a node, a timeline of transitions, and the shape graph.
- A local build of the extension in the `fp_di` package folder, as the DevTools extension framework requires. The extension is experimental.
- An opt-in display of the values of nodes.

## Out of Scope

- Any change to the state of a running app from DevTools: no disposal, no new scope, no new value. The inspector reads only.
- An inspector in a release or profile build.
- An inspector in a debug build that did not set the switch.
- A separate extension for `fp_di_flutter`. The widget tree stays the business of the Flutter inspector.
- A stable public Dart API for the protocol. The protocol is a contract between the inspector and the extension of the same version.
- The built extension in a release of `fp_di`, while the extension is experimental.

## User Stories

- <a id="r-us-tl-dt-001"></a>**R-US-TL-DT-001** — As an application author, I want to see the scopes and nodes of a running app with their phases while it runs, so that I understand its state without adding code.
- <a id="r-us-tl-dt-002"></a>**R-US-TL-DT-002** — As an application author, I want to see why a value is missing or failed, with the keys that a node waits for and the failure behind a key, so that I find the cause without reading logs.
- <a id="r-us-tl-dt-003"></a>**R-US-TL-DT-003** — As an application author, I want to see the transitions, the errors, and the slow mutations in the order in which they happened, so that I can follow a startup, a logout, or a failure.
- <a id="r-us-tl-dt-004"></a>**R-US-TL-DT-004** — As an application author, I want to see the shape graph of a scope with the phase of each member, so that I see which member waits for which and where a chain is long.
- <a id="r-us-tl-dt-005"></a>**R-US-TL-DT-005** — As an application author, I want to turn the inspector on with one switch, and I want it to cost nothing when it is off or in a release build, so that a debug build serves it only when I ask.

## Use Cases

- <a id="r-uc-tl-dt-001"></a>**R-UC-TL-DT-001** — Serve the inspector in a debug build
  - Actor: runtime
  - Trigger: the creation of the first root scope in an isolate while `Scope.debugInspector` is true
  - Preconditions: Dart assertions are enabled, as in a Flutter debug build, `dart run --enable-asserts`, and `package:test`. The app set `Scope.debugInspector` to true before it created the root.
  - Main flow: `Scope.debugInspector` MUST be false by default. The runtime MUST read the switch only inside an assertion, when it creates a root. The runtime MUST register the service extensions of the inspector one time in the isolate, inside an assertion. It MUST keep each live root in a registry that holds a weak reference, so that the registry keeps no root alive. A root MUST leave the registry when its disposal ends. The creation and the disposal of a root MUST take constant time in the registry on average, also with many live roots.
  - Alternative flows: without assertions, or for a root created while the switch is false, the runtime MUST NOT register a service extension, MUST NOT add the root to a registry, and MUST NOT post an event for the root. A second root MUST NOT register the service extensions again. A later change of the switch MUST NOT remove a root that joined the registry.
  - Postcondition: a debug build serves the inspector only after the app sets the switch, and a release build carries no inspector work.

- <a id="r-uc-tl-dt-002"></a>**R-UC-TL-DT-002** — Answer a query of the extension
  - Actor: DevTools extension
  - Trigger: a call of `ext.fp_di.roots`, `ext.fp_di.state`, `ext.fp_di.node`, or `ext.fp_di.shape`
  - Preconditions: the inspector is served
  - Main flow: each answer MUST be a JSON object with `format` set to `fp_di.devtools` and the protocol `version`. `roots` MUST list each live root with its id, its label, and its `revision`. `state` MUST return the tree of scopes of one root: for each scope its id, its phase, the label of its module, its children, and the labels of its open holds ([R-UC-RT-LC-034](../../runtime/lifecycle/requirements.md#r-uc-rt-lc-034)); for each node its id, its label, its key, its phase, its missing keys, a summary of its last activation failure, its number of commits, and the origin of its component. `node` MUST return the details of one node: each key that it reads with the kind of the read, whether the key resolves, and the id of the node that publishes it; the ids of the nodes that read it; the cause and the stack trace of its last activation failure; and, when its key has no value, the search of [R-UC-RT-LC-030](../../runtime/lifecycle/requirements.md#r-uc-rt-lc-030) as a list of steps. `shape` MUST return the `ShapeGraph` JSON of one scope with the modules of its ancestors.
  - Alternative flows: an unknown id MUST give an error answer that names the id, and MUST NOT throw in the app. A disposed root MUST answer as unknown.
  - Postcondition: a query starts no mutation and changes no state, as the reads of the observation layer do.

- <a id="r-uc-tl-dt-003"></a>**R-UC-TL-DT-003** — Stream events to the extension
  - Actor: runtime, DevTools extension
  - Trigger: a transition, a report on `Scope.errors`, or a slow mutation, after the extension called `ext.fp_di.listen`
  - Preconditions: the inspector is served
  - Main flow: the inspector MUST post no event until the extension calls `ext.fp_di.listen`. After that call, it MUST post `fp_di:transition` with the id of the root, the `revision`, and the node states that changed since the last event of that root. It MUST combine the transitions of one event-loop turn into one event. It MUST post `fp_di:error` for each report on `Scope.errors`, and `fp_di:slowMutation` for each slow mutation that a root reports. A root reports one only when it was created with `onSlowMutation`, and the inspector MUST NOT start a timer to measure a mutation.
  - Alternative flows: a call of `ext.fp_di.listen` with `enabled: false` MUST stop the events. An event MUST NOT exceed a size bound; a longer stack trace or list is cut, and the event states that it is cut.
  - Postcondition: an app whose DevTools does not show the extension builds no event.

- <a id="r-uc-tl-dt-004"></a>**R-UC-TL-DT-004** — Show values only on request
  - Actor: application author
  - Trigger: the option that shows values, in the extension
  - Preconditions: the inspector is served
  - Main flow: answers and events MUST NOT contain the `toString` of a value unless the extension asked for values with `ext.fp_di.listen` or with the query. A value text MUST be cut at a bound.
  - Alternative flows: a `toString` that throws MUST give a placeholder text and MUST NOT fail the answer.
  - Postcondition: a value, which can hold a secret or be expensive to print, leaves the app only when the author asks for it.

- <a id="r-uc-tl-dt-005"></a>**R-UC-TL-DT-005** — Show the inspector in DevTools
  - Actor: application author
  - Trigger: the `fp_di` tab of DevTools, connected to an app that depends on `fp_di`
  - Preconditions: the author enabled the extension in DevTools
  - Main flow: the extension MUST show the roots and the scope tree with the phase of each scope; the nodes of the selected scope with their phases, missing keys, and commits, with a filter by phase and a search by key; the details of the selected node, where a key opens the node that publishes it; a timeline of the transitions, errors, and slow mutations since it connected; and the shape graph of the selected scope, colored by the phase of each member, with its cycles, its longest chain, and its undeclared and duplicate keys.
  - Alternative flows: without a connected app, the extension MUST state that it needs one. With an app that serves another protocol `version`, it MUST state the two versions and show nothing else.
  - Postcondition: the extension changes nothing in the app.

- <a id="r-uc-tl-dt-006"></a>**R-UC-TL-DT-006** — Package the extension with `fp_di`
  - Actor: package maintainer
  - Trigger: a build of the extension app
  - Preconditions: the extension app builds for the web
  - Main flow: a local build MUST put the extension in `packages/fp_di/extension/devtools/build/`, with a `config.yaml` whose `name` is `fp_di`, as the DevTools extension framework requires. `dart run devtools_extensions validate --package=packages/fp_di` MUST pass.
  - Alternative flows: the repository MUST NOT track the folder `packages/fp_di/extension/`, and a release of `fp_di` MUST NOT contain it, while the extension is experimental.
  - Postcondition: the core library code still imports no Flutter library, and a release of `fp_di` has no extension folder.

## Verification

- <a id="v-t-tl-dt-001"></a>**V-T-TL-DT-001** `[test]` Given a Dart VM test with assertions and a second run without them, both with `Scope.debugInspector` set to true, when two roots are created and one is disposed, then with assertions the service extensions are registered once and the registry lists only the live root, and 40000 roots are created and disposed within a time bound; without assertions nothing is registered, nothing is kept, and nothing is posted. With assertions and the switch at its default, a root registers nothing and posts nothing, and a root created after the switch is set registers the service extensions. Covers: R-US-TL-DT-005, R-UC-TL-DT-001.
- <a id="v-t-tl-dt-002"></a>**V-T-TL-DT-002** `[test]` Given a root with a child initialized before its parent, a waiting node, a node whose automatic activation failed, a node that reads a collection key, and a node disposed alone, when the handlers of `roots`, `state`, `node`, and `shape` are called directly, then each answer has the `format` and `version`, the tree, the node details, the readers, the failure, and the search steps match the runtime, an unknown id gives an error answer, and `revision` is unchanged by the calls. Covers: R-US-TL-DT-001, R-US-TL-DT-002, R-US-TL-DT-004, R-UC-TL-DT-002.
- <a id="v-t-tl-dt-003"></a>**V-T-TL-DT-003** `[test]` Given a root and a recorder of posted events, when transitions, an error, and a slow mutation happen before and after a call of `listen`, then nothing is posted before it, one transition event is posted for each event-loop turn with the changed node states, the error and the slow mutation are posted, a stack trace over the bound is cut and marked, and `listen` with `enabled: false` stops the events. Covers: R-US-TL-DT-003, R-UC-TL-DT-003.
- <a id="v-t-tl-dt-004"></a>**V-T-TL-DT-004** `[test]` Given nodes whose values have a `toString` that returns a secret, a long text, and a throw, when the handlers answer with and without the request for values, then no value text appears without the request, a long text is cut, and a throwing `toString` gives the placeholder. Covers: R-UC-TL-DT-004.
- <a id="v-t-tl-dt-005"></a>**V-T-TL-DT-005** `[test]` Given the extension app with a fake service that serves recorded answers and events, when it starts, a scope and a node are selected, a key is followed, and the phase filter is set, then each view shows the recorded data, following a key selects its publisher, a missing app shows the connection message, and another protocol version shows the version message. Covers: R-UC-TL-DT-005.
- <a id="v-t-tl-dt-006"></a>**V-T-TL-DT-006** `[test]` Given a root with a child scope whose disposal waits for two open holds, one with a `debugLabel` and one without, when the handler of `state` is called, then the child lists the label and `hold` in `holds`, the root lists no hold, and after both holds close and the disposal ends, the child is no longer in the tree. Covers: R-US-TL-DT-002, R-UC-TL-DT-002.
- <a id="v-l-tl-dt-001"></a>**V-L-TL-DT-001** `[lint]` Given the built extension in `packages/fp_di/extension/devtools/`, when `dart run devtools_extensions validate --package=packages/fp_di` runs and the imports of `packages/fp_di/lib` are checked, then the validation passes, no file of the core library imports Flutter, and `dart pub publish --dry-run` of `fp_di` lists no file of the folder. Covers: R-UC-TL-DT-006.
- <a id="v-q-tl-dt-001"></a>**V-Q-TL-DT-001** `[qa]` Given a Flutter example and a Dart example of `fp_di` run in debug mode with DevTools in a browser, when the `fp_di` tab is opened during startup, a logout, and a failed activation, then each view of R-UC-TL-DT-005 shows the state of the app, and a release build of the same app shows no `fp_di` service extension. Covers: R-US-TL-DT-001, R-US-TL-DT-002, R-US-TL-DT-003, R-US-TL-DT-004, R-US-TL-DT-005.

## References

- [Dart DevTools extensions](https://docs.flutter.dev/tools/devtools/extensions) and the [`devtools_extensions`](https://pub.dev/packages/devtools_extensions) package.
- [Runtime lifecycle requirements](../../runtime/lifecycle/requirements.md): [R-UC-RT-LC-016](../../runtime/lifecycle/requirements.md#r-uc-rt-lc-016) (observation) and [R-UC-RT-LC-030](../../runtime/lifecycle/requirements.md#r-uc-rt-lc-030) (the cause of an unavailable key), which the inspector reads.
