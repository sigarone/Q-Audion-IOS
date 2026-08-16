## 2026-10-13 - [SwiftUI custom controls a11y traits]
**Learning:** VoiceOver does not automatically announce state or interactive roles when standard elements are not used natively. `onTapGesture` requires `.accessibilityAddTraits(.isButton)` so users know they can interact with the element. Toggle-style buttons built from scratch require `.accessibilityAddTraits(isActive ? .isSelected : [])` to communicate their active vs inactive state.
**Action:** When evaluating or creating custom controls in SwiftUI that deviate from standard `Button()` or `Toggle()`, actively audit that correct interaction traits are supplied manually.

## 2026-08-15 - [SwiftUI Expandable Components a11y]
**Learning:** For custom expandable components built with `onTapGesture`, adding `.accessibilityElement(children: .combine)` prevents VoiceOver from reading every sub-element separately (e.g., lock icon, dot, text). Additionally, providing an `.accessibilityHint` explaining what tapping does (expand/collapse) makes the interaction discoverable.
**Action:** When building custom expandable views, combine elements for a cleaner readout, ensure it has the `.isButton` trait, and provide state-aware `.accessibilityHint` strings.

## 2026-10-18 - [Settings Rows Hit Targets and Accessibility]
**Learning:** For settings rows containing toggle buttons, users often expect the entire row (not just the small `Toggle` control) to act as a hit target. However, adding `.onTapGesture` to a parent view like an `HStack` can break VoiceOver's natural parsing of the row.
**Action:** Always add `.contentShape(Rectangle())` before `.onTapGesture` to ensure the entire row acts as a hit target. Additionally, apply `.accessibilityElement(children: .combine)`, `.accessibilityAddTraits(.isButton)` and conditional `.isSelected` traits, and provide localized `.accessibilityValue` and `.accessibilityHint` to give VoiceOver users a unified and descriptive control.
