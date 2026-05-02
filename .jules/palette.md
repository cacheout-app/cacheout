## 2024-04-30 - Clickable List Rows and Accessibility
**Learning:** In SwiftUI lists, adding a `Button` only around a checkbox creates a tiny hit target that is hard to tap and poorly reported by VoiceOver.
**Action:** Wrap the entire row's `HStack` in a `Button`, apply `.contentShape(Rectangle())` to make empty space clickable, use `.buttonStyle(.plain)` to prevent unintended text styling, and apply `.accessibilityElement(children: .combine)` along with `.accessibilityAddTraits(.isSelected)` for optimal VoiceOver experience.
## 2024-05-02 - Icon-Only Controls Accessibility in SwiftUI
**Learning:** In SwiftUI, icon-only controls (e.g., `Button` or `Menu` with an `Image` label and no `Text`) require explicit `.accessibilityLabel` modifiers for VoiceOver support, and `.help` modifiers for mouse hover context, as they lack semantic text content by default.
**Action:** When creating or reviewing icon-only interactive elements in SwiftUI, always ensure `.accessibilityLabel` and `.help` are included to provide context for screen readers and mouse users.
