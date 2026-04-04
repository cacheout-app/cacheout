## 2024-05-24 - Clickable List Rows in SwiftUI
**Learning:** When creating clickable list rows with checkboxes in SwiftUI, wrapping only the checkbox in a button makes the hit target too small and fragments VoiceOver focus.
**Action:** Wrap the entire row contents (e.g., `HStack`) in a `Button`, apply `.contentShape(Rectangle())` to make empty space clickable, use `.buttonStyle(.plain)` to prevent unintended styling, and add `.accessibilityElement(children: .combine)` and state-appropriate traits like `.accessibilityAddTraits(.isSelected)`.
