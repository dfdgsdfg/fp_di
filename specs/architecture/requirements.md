---
type: requirement
title: "Project Architecture Requirements"
description: "Project-wide package separation, ownership, paper adoption, and interoperability."
tags: [architecture, dart, flutter]
id_prefix: "AR-DI"
legacy_id_prefixes: [AR-UI]
---

# Project Architecture Requirements

[Spec](spec.md) · [Decisions](log.md)

## Problem Statement

The project needs one shared architecture explaining why the Dart runtime and
Flutter adapter are separate packages, how they cooperate, and which ideas from
the paper belong in this library. Package boundaries do not require separate
architecture topics. Detailed lifecycle semantics remain in the runtime topic.

## Scope

- Rationale for the fp_di / fp_di_flutter split, public API direction, and ownership.
- Scope publication to the widget tree, subscriptions, and replacement.
- A widget that creates, initializes, publishes, and disposes the scope of one widget subtree, and builds from the state of that scope.
- The lifecycles that meet in the adapter: the frames of Flutter, the mounting of widgets and of routes, the replacement of the published scope, and the transitions of the runtime.
- Host execution boundary and canonical documentation responsibilities.
- The paper-inspired subset and host-side interoperability with `fpdart`.

## Out of Scope

- Lifecycle algorithms, test methodology, and formal model internals owned by linked topics.
- New platforms, services, generated code, publishing infrastructure, or package relocation.

The existing AR-DI and AR-UI identifiers remain stable after consolidation;
AR-UI is a retained identifier namespace, not a separate document domain.

## User Stories

- <a id="r-us-ar-di-001"></a>**R-US-AR-DI-001** — As a Dart application author, I want the core usable without Flutter runtime imports, so that lifecycle composition works outside widget applications.

- <a id="r-us-ar-ui-001"></a>**R-US-AR-UI-001** — As a host application author, I want to publish a root dependency context through the widget tree without transferring its ownership, so that application shutdown remains explicit.
- <a id="r-us-ar-ui-003"></a>**R-US-AR-UI-003** — As a widget author, I want to choose between non-listening and key-based lookup, so that only publisher identity or availability changes rebuild dependent widgets.
- <a id="r-us-ar-ui-004"></a>**R-US-AR-UI-004** — As a host application author, I want to replace a scope from any callback of Flutter and to give a route its own scope, so that a route transition and an unmount show no lookup error.
- <a id="r-us-ar-ui-005"></a>**R-US-AR-UI-005** — As a widget author, I want one widget that creates the scope of a page or a route, shows its loading and its failure, and disposes it when the widget leaves, so that each page does not repeat that lifecycle.

## Use Cases

- <a id="r-uc-ar-di-001"></a>**R-UC-AR-DI-001** — Consume the package boundary
  - Actor: host application or adapter
  - Trigger: importing components and initializing a scope with them
  - Preconditions: compatible Dart SDK
  - Main flow: `fp_di` MUST own the platform-independent runtime; `fp_di_flutter` MUST depend only on its public core entry point for DI behavior. The core MUST NOT import Flutter or the Flutter adapter.
  - Alternative flows: UI-only resources remain under Flutter State ownership.
  - Postcondition: package dependency direction is acyclic.

- <a id="r-uc-ar-di-002"></a>**R-UC-AR-DI-002** — Locate the canonical contract
  - Actor: maintainer
  - Trigger: architecture or verification work
  - Preconditions: repository checkout
  - Main flow: each contract MUST have one owning topic with linked requirements, design, and decision log.
  - Alternative flows: verified divergence belongs in the owning topic's gap document.
  - Postcondition: tool instructions and indexes link to those owners instead of defining a second contract.

- <a id="r-uc-ar-di-003"></a>**R-UC-AR-DI-003** — Compose with functional application code
  - Actor: host author
  - Trigger: using `fpdart` values or lazy computations with DI
  - Preconditions: host-selected compatible `fpdart` version
  - Main flow: the core MUST remain independent of `fpdart`; integrations MUST preserve the core's node/resource ownership and explicit dependency tracking.
  - Alternative flows: a domain `Left` is returned as a value unless the host explicitly converts it to activation failure.
  - Postcondition: using functional containers does not silently acquire ownership, trigger rollback, or discharge runtime dependencies.

- <a id="r-uc-ar-di-004"></a>**R-UC-AR-DI-004** — Interpret paper-derived claims
  - Actor: maintainer
  - Trigger: design or documentation change
  - Preconditions: the supplied paper and source mapping
  - Main flow: claims MUST distinguish adopted mechanisms, Dart adaptations, and excluded features; proof claims MUST state their premises and implementation correspondence.
  - Alternative flows: a future capability changes its owning requirements before becoming part of conformance.
  - Postcondition: inspiration is not represented as full paper or Cordis compatibility.

- <a id="r-uc-ar-ui-001"></a>**R-UC-AR-UI-001** — Publish a host context
  - Actor: host application
  - Trigger: widget tree construction or scope replacement
  - Preconditions: a live caller-owned `Scope`, supplied as one scope or as the value of a `ValueListenable<Scope>`
  - Main flow: `ScopeProvider` listens for changes, publishes the supplied scope, and unsubscribes from the old scope when the host replaces it. With a listenable, a lookup MUST read the value of the listenable at the moment of the call. The host changes the value before it disposes the old scope.
  - Alternative flows: an unmounted widget ignores late notifications. The disposal of a scope MUST NOT rebuild a watching widget; only the change of a key or the replacement of the scope does.
  - Postcondition: the widget never disposes the supplied scope.

- <a id="r-uc-ar-ui-003"></a>**R-UC-AR-UI-003** — Read or watch a binding
  - Actor: descendant widget
  - Trigger: `di`, `maybeDi`, `watchDi`, `watchMaybeDi`, `maybeDiNode`, or `watchMaybeDiNode`
  - Preconditions: an ancestor `ScopeProvider` publishes a scope
  - Main flow: non-listening calls read without registering a dependency; watching calls register the selected `DiKeyBase` and rebuild for publisher identity or availability changes. A watching read of a node MUST also rebuild when the state, the failure, or the missing keys of that node change.
  - Alternative flows: missing required lookup reports the adapter's missing-scope or core lookup error; mutable fields inside a value do not notify the watcher. `ScopeProvider.maybeOf` MUST return null when no provider is above, and a listening call that found none MUST rebuild the widget when the widget moves below a provider.
  - Postcondition: rebuild scope matches the selected lookup mode.

- <a id="r-uc-ar-ui-005"></a>**R-UC-AR-UI-005** — Stay consistent across the lifecycles
  - Actor: Flutter framework, host application, runtime
  - Trigger: a frame, the mount or the unmount of a widget or of a route, a change of the listenable, or a transition of the runtime
  - Preconditions: the host follows the [host rule for routes](spec.md#host-rule-for-routes): it changes the listenable before it disposes the old scope, and a scope that a route owns lives until the `State` that owns it is disposed
  - Main flow: No build and no lookup of a mounted widget MUST throw because of the adapter. After the frames that a change asked for, each mounted watcher MUST show the value, the node state, or the scope that its lookup returns at that moment. The disposal of another scope MUST NOT rebuild a watcher, as R-UC-AR-UI-001 states. An unmounted `ScopeProvider` MUST schedule no frame and MUST hold no listener.
  - Alternative flows: The host MAY change the listenable while the framework builds or has locked the tree, for example from `State.dispose`. `ScopeProvider` MUST NOT call `setState` at that moment. It MUST move to the new scope after the frame, and a lookup MUST read the new scope at once. A change at any other moment MUST reach the listening widgets at the next frame. A transition MUST schedule no frame while no key was watched since the mount of the provider.
  - Postcondition: the widgets below a provider show one scope, and the adapter owns no scope that a caller supplied.

- <a id="r-uc-ar-ui-006"></a>**R-UC-AR-UI-006** — Own the scope of a subtree
  - Actor: host application, Flutter framework, runtime
  - Trigger: the mount of a `ScopeBuilder`, the replacement of the scope above it, a transition of the runtime, or the unmount of the widget
  - Preconditions: with `create`, a `ScopeProvider` is above the widget, and `create` returns a new scope that no code initialized. With `ScopeBuilder.value`, the caller owns the scope and does not dispose it while the widget is mounted.
  - Main flow: `ScopeBuilder` MUST call `create` once for each scope of the closest provider and MUST call `initialize` on the result. It MUST publish the scope to everything that its builder returns, from the first build. It builds from a snapshot that holds the scope, its phase, the state of each of its nodes, and the failure of its `initialize`. After a transition that changes the phase or a node state of its scope, it MUST build again at a later frame, and it MUST NOT call `setState` inside the transition. A transition of a child scope does not build it again. When the scope above is replaced, it MUST publish the new scope before it disposes the old one. At the unmount, it MUST dispose the scope that it created.
  - Alternative flows: While `isDisposed` of its scope is true, the widget MUST NOT call its builder, also for a rebuild from above. The failure of a disposal, the rollback failures of a canceled `initialize`, and the failure of an `initialize` that the widget no longer shows MUST go to `FlutterError.reportError`. A canceled `initialize` without rollback failures is not reported. `ScopeBuilder.value` MUST NOT call `initialize` or `dispose`, and its snapshot has no failure.
  - Postcondition: each scope that the widget created is disposed once, and a scope that the caller supplied stays with the caller.

- <a id="r-uc-ar-ui-004"></a>**R-UC-AR-UI-004** — Respect core ownership and interoperability boundaries
  - Actor: adapter maintainer
  - Trigger: adding or changing Flutter integration
  - Preconditions: the public core API and project architecture are available
  - Main flow: use only `package:fp_di/fp_di.dart` and keep result interoperability at the host boundary.
  - Alternative flows: a UI needs an `fpdart` result bridge, which follows the project interoperability contract without adding an adapter dependency.
  - Postcondition: the adapter remains a Flutter-facing layer over core contracts.

## Verification

- <a id="v-t-ar-di-001"></a>**V-T-AR-DI-001** `[test]` Given the core package, when its tests execute on the Dart VM, then the core suite runs without a Flutter test engine. Covers: R-US-AR-DI-001, R-UC-AR-DI-001.
- <a id="v-l-ar-di-001"></a>**V-L-AR-DI-001** `[lint]` Given manifests and source imports, when boundary checks run, then the core has no Flutter/adapter dependency and the adapter uses no core src import. Covers: R-UC-AR-DI-001.
- <a id="v-l-ar-di-002"></a>**V-L-AR-DI-002** `[lint]` Given canonical topics, when documentation validation runs, then topic triads, IDs, and cross-links are valid. Covers: R-UC-AR-DI-002.

- <a id="v-t-ar-di-002"></a>**V-T-AR-DI-002** `[test]` Given a host-side fpdart bridge, when lazy initialization is executed, domain failure is returned, or a node waits for a publisher, then scopes and nodes retain explicit disposal ownership, Left follows the selected host policy, and successful initialization does not imply active availability. Covers: R-UC-AR-DI-003.
- <a id="v-l-ar-di-003"></a>**V-L-AR-DI-003** `[lint]` Given architectural claims, when the topic is validated, then paper adoption rows link their source and owning contract without asserting an unexecuted proof. Covers: R-UC-AR-DI-004.
- <a id="v-t-ar-ui-001"></a>**V-T-AR-UI-001** `[test]` Given a caller-owned context published by `ScopeProvider`, when a publisher changes, then non-listening `di` widgets do not rebuild while `watchDi` rebuilds for the selected publisher identity and ignores an unrelated key. Covers: R-US-AR-UI-001, R-US-AR-UI-003, R-UC-AR-UI-001, R-UC-AR-UI-003.
- <a id="v-t-ar-ui-004"></a>**V-T-AR-UI-004** `[test]` Given two caller-owned scopes, when the parent rebuilds a fixed `ScopeProvider` with the other scope, then each listening lookup moves to that scope, a non-listening widget does not rebuild, and both scopes stay usable after the provider is removed. Covers: R-US-AR-UI-001, R-UC-AR-UI-001, R-UC-AR-UI-003.
- <a id="v-t-ar-ui-006"></a>**V-T-AR-UI-006** `[test]` Given a session scope that a listenable holds, when the host changes the value to the parent scope and disposes the session scope before the next frame, then a lookup from a widget that was not rebuilt reads the parent scope, watchers rebuild once in the replacement scope and follow its keys, and a widget that listens to the scope rebuilds once. Covers: R-US-AR-UI-001, R-UC-AR-UI-001, R-UC-AR-UI-003.
- <a id="v-t-ar-ui-007"></a>**V-T-AR-UI-007** `[test]` Given a watching widget below `ScopeProvider`, when the published scope or another scope of the same root is disposed, then the watcher does not rebuild and no lookup error occurs. Covers: R-US-AR-UI-003, R-UC-AR-UI-001, R-UC-AR-UI-003.
- <a id="v-t-ar-ui-008"></a>**V-T-AR-UI-008** `[test]` Given the examples of the adapter, when a widget test runs each example application, then each one shows its documented behaviour with no lookup error. Covers: R-UC-AR-UI-001, R-UC-AR-UI-003.
- <a id="v-t-ar-ui-009"></a>**V-T-AR-UI-009** `[test]` Given members of a child scope that wait for a key of the parent, when the parent initializes and one member activates and another fails, then each watching read of a node rebuilds once and reads the new state, a watching read of a key without a node and a non-listening read do not rebuild, and a scope replacement moves the watching read. Covers: R-US-AR-UI-003, R-UC-AR-UI-003.
- <a id="v-t-ar-ui-010"></a>**V-T-AR-UI-010** `[test]` Given a widget with no `ScopeProvider` above, when it calls `ScopeProvider.maybeOf` in each lookup mode, then each call returns null and `ScopeProvider.of` throws; given a provider above, then each call returns the scope that `of` returns; and given a listening call that found no provider, when the widget moves below a provider, then the widget rebuilds and reads the published scope. Covers: R-US-AR-UI-003, R-UC-AR-UI-003.
- <a id="v-t-ar-ui-011"></a>**V-T-AR-UI-011** `[test]` Given random histories with a fixed range of seeds that mix frames, parts of a route transition, a login and a logout through the listenable, a logout from `State.dispose`, the withdrawal of a watched member, the disposal of another scope, the push and the pop of a route that owns a scope, and the mount and the unmount of a watcher, when each history follows the host rule, then no build and no lookup throws, each mounted watcher shows the value of its scope after each step, the disposal of another scope rebuilds no watcher, and a transition after the unmount of the provider schedules no frame; and given one defect of the harness for each of the four checks, then the run reports that check. Covers: R-US-AR-UI-004, R-UC-AR-UI-005.
- <a id="v-t-ar-ui-012"></a>**V-T-AR-UI-012** `[test]` Given a provider with a listenable, when the host changes the value from `State.dispose`, from a build inside a frame, and from a build outside a frame, then no call throws, a lookup reads the new scope at once, the provider asks for a frame, and each listening widget shows the new scope after the frames that the provider asked for; given a `State.dispose` that changes the value and then disposes the old scope, then no read fails; and given a provider below which no key was watched, when a transition of the runtime occurs, then no frame is scheduled, while a transition below a provider with a watched key schedules one frame. Covers: R-US-AR-UI-004, R-UC-AR-UI-005.
- <a id="v-t-ar-ui-013"></a>**V-T-AR-UI-013** `[test]` Given a `ScopeBuilder` with `create` below a provider, when its scope initializes, when `initialize` fails, when the scope above is replaced, when a child of its scope initializes and leaves, when a `State.dispose` disposes a child of its scope and withdraws a key that it reads, when the owner disposes its scope and the tree above rebuilds, when a logout changes the scope above and disposes the old one in one turn during and after `initialize`, and when the widget unmounts during and after `initialize`, then the builder shows each phase and the failure, a lookup below reads the published scope, `create` runs once for each scope above and the old scope is disposed, the child scope calls no builder, the withdrawal builds again at a later frame with no error, the disposal calls no builder, the logout gives no error and a child of the new scope, the unmount disposes the scope, and the failures of the rollback and of the disposal are reported while a canceled `initialize` alone is not; and given `ScopeBuilder.value`, then the widget calls no `initialize` and no `dispose` and follows the state of the scope of the caller. Covers: R-US-AR-UI-005, R-UC-AR-UI-006.
- <a id="v-l-ar-ui-001"></a>**V-L-AR-UI-001** `[lint]` Given adapter production sources, when the documented analysis and boundary review run, then imports resolve through the public `package:fp_di/fp_di.dart` surface and the adapter introduces no direct `fpdart` dependency. Covers: R-UC-AR-UI-004.

