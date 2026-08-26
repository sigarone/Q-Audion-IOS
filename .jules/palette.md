## 2026-08-17 - [SwiftUI tap-to-copy rows a11y traits]
**Learning:** For custom tap-to-copy rows built with `onTapGesture`, VoiceOver does not natively know they are interactive elements or read them concisely. Using `.accessibilityElement(children: .combine)` prevents reading text and icons separately, while `.accessibilityAddTraits(.isButton)` and `.accessibilityHint` explain what the tap interaction will do.
**Action:** When implementing custom rows or UI cells meant to be copied on tap, actively combine their accessibility elements, apply the `.isButton` trait, and provide an `.accessibilityHint` describing the result of the action only (e.g., "Copia negli appunti"). VoiceOver already announces the interaction method for `.isButton`-trait elements — don't prefix the hint with "Tocca per"/"Tocca due volte per", it's redundant (fixed repo-wide 2026-08-22, PR #80).

## 2026-10-13 - [SwiftUI custom controls a11y traits]
**Learning:** VoiceOver does not automatically announce state or interactive roles when standard elements are not used natively. `onTapGesture` requires `.accessibilityAddTraits(.isButton)` so users know they can interact with the element. Toggle-style buttons built from scratch require `.accessibilityAddTraits(isActive ? .isSelected : [])` to communicate their active vs inactive state.
**Action:** When evaluating or creating custom controls in SwiftUI that deviate from standard `Button()` or `Toggle()`, actively audit that correct interaction traits are supplied manually.

## 2026-08-15 - [SwiftUI Expandable Components a11y]
**Learning:** For custom expandable components built with `onTapGesture`, adding `.accessibilityElement(children: .combine)` prevents VoiceOver from reading every sub-element separately (e.g., lock icon, dot, text). Additionally, providing an `.accessibilityHint` explaining what tapping does (expand/collapse) makes the interaction discoverable.
**Action:** When building custom expandable views, combine elements for a cleaner readout, ensure it has the `.isButton` trait, and provide state-aware `.accessibilityHint` strings.

## 2026-08-20 - [Accessibility on custom tappable views (Image/Error states)]
**Learning:** Custom interactive components like images with `onTapGesture` (e.g. to open full screen) or error state boxes (e.g. tap to retry) are not inherently identified as buttons by VoiceOver. Screen reader users won't know they are interactive.
**Action:** Always add `.accessibilityAddTraits(.isButton)`, an `.accessibilityLabel()`, and an `.accessibilityHint()` explaining the action to any `Image`, `Rectangle`, or custom view modifier that uses an `onTapGesture` to trigger logic. For composite error boxes, group with `.accessibilityElement(children: .combine)`.
## 2026-08-26 - [Removing dead UI components]
**Learning:** When evaluating a custom UI component for enhancements (e.g. `TapCopyRow.swift`), it's crucial to check if the component is actually instantiated anywhere in the codebase. Even if it exists, it might be obsolete code. Applying fixes to dead code introduces risk and wastes CI cycles.
**Action:** Before applying UX or accessibility improvements to a component, grep the codebase to verify it has actual call sites. If a component has zero references (e.g. `TapCopyRow` had none, its logic was inlined at the call sites), strongly recommend or directly perform its deletion instead of patching it.
