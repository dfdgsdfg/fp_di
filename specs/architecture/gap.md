---
type: gap
title: "Project Architecture — Known Gaps"
description: "Verified open differences between the accepted architecture spec and the implementation."
tags: [architecture, flutter, gap]
---

# Project Architecture — Known Gaps

## <a id="g-ar-ui-001"></a>G-AR-UI-001 — No ScopeBoundary

- Spec: [`spec.md#flutter-integration`](spec.md#flutter-integration), R-UC-AR-UI-006, R-UC-AR-UI-007, and rule 6 of [`spec.md#host-rule-for-routes`](spec.md#host-rule-for-routes) require a `ScopeBoundary` that holds the disposal of a caller-owned scope, a `ScopeBuilder` without the constructor `value`, builders that run in the phase `disposeRequested`, an empty subtree in the phases `disposing` and `disposed`, and a `ScopeProvider` that compares the watched keys until the disposal mutation starts.
- Implementation: [`scope_builder.dart`](../../packages/fp_di_flutter/lib/src/scope_builder.dart) defines `ScopeBuilder.value`, and its build returns the widgets of the last build while `isDisposed` is true. `packages/fp_di_flutter/lib` has no `ScopeBoundary` symbol. `_compare` in [`scope_provider.dart`](../../packages/fp_di_flutter/lib/src/scope_provider.dart) returns when `isDisposed` is true, which is from the request on. The core has no hold ([G-RT-LC-015](../runtime/lifecycle/gap.md#g-rt-lc-015)).
- Impact: A host that disposes a scope outside the widget tree removes the widgets that read it before the disposal, with its own code, or lets an exiting route read a disposed scope.
- Resolution condition: The adapter implements the linked design and V-T-AR-UI-013 and V-T-AR-UI-014 pass, or the accepted spec is revised.
- Evidence: Inspected `packages/fp_di_flutter/lib/src/scope_builder.dart`; searched `packages/fp_di_flutter/lib` for `ScopeBoundary`.
