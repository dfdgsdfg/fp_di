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
