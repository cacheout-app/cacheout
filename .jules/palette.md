## 2024-05-24 - Clickable List Rows in SwiftUI
**Learning:** In SwiftUI, placing a button inside an HStack for list rows often results in only the button's explicit frame (e.g., a tiny checkbox) being clickable, frustrating users and providing a poor VoiceOver experience.
**Action:** Wrap the entire row contents (like the HStack) inside the `Button` label. Apply `.contentShape(Rectangle())` to ensure whitespace is interactive, `.buttonStyle(.plain)` to prevent default styling, and `.accessibilityElement(children: .combine)` so VoiceOver reads the row as a single cohesive element.
