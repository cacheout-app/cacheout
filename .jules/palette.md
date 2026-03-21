## 2024-05-19 - Clickable List Rows
**Learning:** Inner buttons inside list rows in SwiftUI create tiny, hard-to-hit targets and poor VoiceOver experiences.
**Action:** Wrap the entire `HStack` representing the row in a `Button`, apply `.contentShape(Rectangle())` to ensure empty space is clickable, use `.buttonStyle(.plain)` to prevent text styling changes, and add `.accessibilityElement(children: .combine)` + `.accessibilityValue` to make the entire row a single cohesive accessibility element.
