---
type: gap
title: "DevTools Extension — Known Gaps"
description: "Verified open differences between the accepted DevTools extension spec and the implementation."
tags: [tooling, devtools, gap]
---

# DevTools Extension — Known Gaps

## <a id="g-tl-dt-001"></a>G-TL-DT-001 — No inspector and no extension app

- Spec: [`spec.md`](spec.md#overview) and R-UC-TL-DT-001 to R-UC-TL-DT-006 require an inspector in the core runtime, its JSON protocol and events, a DevTools extension app, and the built extension in `packages/fp_di/extension/devtools/`.
- Implementation: [`scope.dart`](../../../packages/fp_di/lib/src/runtime/scope.dart) registers no service extension, and no file under `packages/fp_di/lib` imports `dart:developer`. Neither `packages/fp_di/extension/` nor `packages/fp_di_devtools/` exists.
- Impact: An author reads the state of a running app only through code, such as `Scope.state`, `describe`, and `ShapeGraph`, and DevTools shows no `fp_di` tab.
- Resolution condition: The implementation satisfies the linked design and V-T-TL-DT-001 to V-T-TL-DT-005 and V-L-TL-DT-001 pass, or the accepted spec is revised.
- Evidence: Inspected `packages/fp_di/lib`: no `registerExtension` and no `postEvent` call. Inspected `packages/`: the folders are `fp_di`, `fp_di_flutter`, and `fp_di_fpdart`.
