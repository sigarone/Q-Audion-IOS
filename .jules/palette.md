## 2026-08-17 - [SwiftUI tap-to-copy rows a11y traits]
**Learning:** For custom tap-to-copy rows built with `onTapGesture`, VoiceOver does not natively know they are interactive elements or read them concisely. Using `.accessibilityElement(children: .combine)` prevents reading text and icons separately, while `.accessibilityAddTraits(.isButton)` and `.accessibilityHint` explain what the tap interaction will do.
**Action:** When implementing custom rows or UI cells meant to be copied on tap, actively combine their accessibility elements, apply the `.isButton` trait, and provide an `.accessibilityHint` (e.g., "Tocca due volte per copiare").

## 2026-10-13 - [SwiftUI custom controls a11y traits]
**Learning:** VoiceOver does not automatically announce state or interactive roles when standard elements are not used natively. `onTapGesture` requires `.accessibilityAddTraits(.isButton)` so users know they can interact with the element. Toggle-style buttons built from scratch require `.accessibilityAddTraits(isActive ? .isSelected : [])` to communicate their active vs inactive state.
**Action:** When evaluating or creating custom controls in SwiftUI that deviate from standard `Button()` or `Toggle()`, actively audit that correct interaction traits are supplied manually.

## 2026-08-15 - [SwiftUI Expandable Components a11y]
**Learning:** For custom expandable components built with `onTapGesture`, adding `.accessibilityElement(children: .combine)` prevents VoiceOver from reading every sub-element separately (e.g., lock icon, dot, text). Additionally, providing an `.accessibilityHint` explaining what tapping does (expand/collapse) makes the interaction discoverable.
**Action:** When building custom expandable views, combine elements for a cleaner readout, ensure it has the `.isButton` trait, and provide state-aware `.accessibilityHint` strings.