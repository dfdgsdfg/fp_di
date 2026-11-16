---
type: log
title: "DevTools Extension Decision Log"
description: "Accepted decisions that change the inspector protocol, its registration, or the DevTools extension of fp_di."
tags: [tooling, devtools, log]
---

# DevTools Extension Decision Log

Append accepted decisions only. Newest at the bottom.

## [2026-11-14] decision | Inspect a running app through a DevTools extension

- Context: The runtime answers what exists, why a value is missing, and what changed through `Scope.state`, `NodeState`, the error of `get`, and `ShapeGraph`, but only to code in the app. get_it ships a DevTools extension that lists its registrations. Dart DevTools loads an extension from the `extension/devtools/` folder of a package that the app depends on.
- Decision: A debug build serves an inspector of service extensions and events from the core package, with `dart:developer` only. A separate Flutter web package, `fp_di_devtools`, is the extension app, and its build lives in `packages/fp_di/extension/devtools/`. The inspector reads only. The protocol is versioned JSON, and the extension refuses another version.
- Consequences: An author sees scopes, nodes, causes, transitions, and the shape graph without code in the app. The core package keeps no Flutter import. The inspector reads internal tables of the runtime, so its tests run with the core tests. The built web app adds to the size of `fp_di` when it ships, which Q-TL-DT-001 decides.
- Alternatives: An inspector in `fp_di_flutter` would miss pure Dart apps and tests. A text dump through `describe` needs code and a restart. A public Dart API for the protocol would freeze internal names that the protocol hides.
- References: [requirements](requirements.md), [design](spec.md), [Dart DevTools extensions](https://docs.flutter.dev/tools/devtools/extensions).

## [2026-11-14] decision | Serve the inspector automatically in each debug build

- Context: get_it sends its events only after `debugEventsEnabled` is set. An author who needs the inspector during a failure must then have set it before.
- Decision: The constructor of the first root of an isolate registers the service extensions inside an `assert`, and each root joins a weak registry. Events start only after the extension calls `ext.fp_di.listen`. Values of nodes leave the app only on request.
- Consequences: The inspector is there whenever DevTools is, with no call in the app. A release build has no registration, no registry, and no event. A debug build pays one registration and a registry of weak references; it builds events only while the extension listens.
- Alternatives: An opt-in call is forgotten exactly when it is needed. Events from the start cost work in every debug build without DevTools.
- References: [registration](spec.md#registration), [R-UC-TL-DT-001](requirements.md#r-uc-tl-dt-001).

## [2026-11-14] decision | Post the transitions of a turn from a timer of the root zone

- Context: R-UC-TL-DT-003 combines the transitions of one event-loop turn into one event, and it forbade a timer of the inspector, to keep slow mutations measured only by a root with `onSlowMutation`. A flush in a microtask runs before the later microtasks of the turn, so an awaited `initialize` gave ten events in the recorded scenario.
- Decision: The first transition of a turn starts a timer of zero duration in the root zone, and the timer posts the event. The requirement now forbids a timer that measures a mutation, not every timer.
- Consequences: An awaited `initialize` gives one event. The timer exists only while the extension listens and a transition happened. The root zone keeps it out of the zones of tests that stop their timers or microtasks.
- References: [events](spec.md#events), [R-UC-TL-DT-003](requirements.md#r-uc-tl-dt-003).

## [2026-11-14] decision | Keep the DevTools extension experimental and out of the release

- Context: Q-TL-DT-001 asked whether a release of `fp_di` ships the built extension. The built web app is 43 MB, 36 MB of it CanvasKit. The extension app has passed only its widget tests, and V-Q-TL-DT-001 has not run. `dart pub publish` warns when `extension/devtools` exists without a build.
- Decision: Resolves Q-TL-DT-001. The extension is experimental. A release of `fp_di` contains no `extension/` folder. The repository tracks the config in `packages/fp_di_devtools`, and the root `.gitignore` excludes `packages/fp_di/extension/`. The inspector stays in the runtime of each debug build.
- Consequences: The package keeps its size, and publishing gives no extension warning. Only an author with a path dependency on the workspace sees the tab, after a local build. The protocol can change without a compatibility duty while the extension is experimental.
- References: [packaging](spec.md#packaging), [R-UC-TL-DT-006](requirements.md#r-uc-tl-dt-006).

## [2026-11-16] decision | Serve the inspector only after the app opts in

- Context: The decision of 2026-11-14 served the inspector in each debug build, with no way to turn it off. The application author wants the inspector off by default and on only when the app asks for it, and only in a debug build.
- Decision: Supersedes the decision "Serve the inspector automatically in each debug build". `Scope` has the static switch `debugInspector`, false by default. The constructor of a root reads it inside an `assert`. A root created while the switch is true registers the service extensions and joins the registry, as before. A root created while it is false does neither.
- Consequences: A debug build that does not set the switch registers no service extension, keeps no registry, and posts no event. A release build is unchanged. An author must set the switch before the first root, and must restart the app to inspect it after a forgotten switch. The inspector tests and the fixture dump set the switch.
- Alternatives: An opt-out switch keeps the old default and the risk of the 2026-11-14 decision in reverse. A `--dart-define` needs no code in the app, but a test process cannot change it.
- References: [registration](spec.md#registration), [R-UC-TL-DT-001](requirements.md#r-uc-tl-dt-001).
