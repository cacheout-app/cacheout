## 2024-04-18 - Expand row hit areas for accessibility

**Learning:** When making SwiftUI list items selectable via a checkbox or button, applying the button exclusively to the icon forces users into a tiny hit area, creating an annoying UX. Additionally, this scatters VoiceOver across multiple individual un-combined elements in the row.
**Action:** Always wrap the entire row's contents (e.g., `HStack`) in a single `Button`, apply `.contentShape(Rectangle())` so whitespace is clickable, use `.buttonStyle(.plain)` to preserve styling, and add `.accessibilityElement(children: .combine)` to create a cohesive screen reader experience.
