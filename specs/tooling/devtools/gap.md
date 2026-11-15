---
type: gap
title: "DevTools Extension — Known Gaps"
description: "Verified open differences between the accepted DevTools extension spec and the implementation."
tags: [tooling, devtools, gap]
---

# DevTools Extension — Known Gaps

## <a id="g-tl-dt-002"></a>G-TL-DT-002 — No holds in the state answer

- Spec: [`spec.md#queries`](spec.md#queries) and R-UC-TL-DT-002 require `holds`, the labels of the open holds of a disposal, for each scope of the `state` answer.
- Implementation: the scope entries that [`runtime_inspector.dart`](../../../packages/fp_di/lib/src/runtime/runtime_inspector.dart) builds have no `holds` field, and the runtime has no hold ([G-RT-LC-015](../../runtime/lifecycle/gap.md#g-rt-lc-015)).
- Impact: A waiting disposal looks like any requested disposal in the extension, and an author cannot see which consumer delays it.
- Resolution condition: The inspector satisfies the linked design and V-T-TL-DT-006 passes, or the accepted spec is revised.
- Evidence: Inspected the scope entries of `packages/fp_di/lib/src/runtime/runtime_inspector.dart`; searched `packages/fp_di/lib` for `disposeHold`.
