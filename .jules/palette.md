## 2024-04-23 - Clickable List Rows in SwiftUI
**Learning:** Wrapping individual components (like a checkbox) inside a list row creates a very small hit target, making it hard to tap. VoiceOver also reads elements separately.
**Action:** Wrap the entire row's contents (`HStack`) in a `Button`, apply `.contentShape(Rectangle())` to make empty space clickable, use `.buttonStyle(.plain)` to prevent text restyling, and apply `.accessibilityElement(children: .combine)` with `.accessibilityAddTraits(.isSelected)`.
