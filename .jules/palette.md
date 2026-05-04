## 2024-04-30 - Clickable List Rows and Accessibility
**Learning:** In SwiftUI lists, adding a `Button` only around a checkbox creates a tiny hit target that is hard to tap and poorly reported by VoiceOver.
**Action:** Wrap the entire row's `HStack` in a `Button`, apply `.contentShape(Rectangle())` to make empty space clickable, use `.buttonStyle(.plain)` to prevent unintended text styling, and apply `.accessibilityElement(children: .combine)` along with `.accessibilityAddTraits(.isSelected)` for optimal VoiceOver experience.
## 2024-05-04 - Icon-only Control Accessibility
**Learning:** Icon-only `Menu` and `Button` controls in SwiftUI require both an explicit `.accessibilityLabel` for VoiceOver support and a `.help` modifier for mouse hover tooltips, as they lack textual context.
**Action:** Always apply `.accessibilityLabel` and `.help` modifiers to interactive controls that only use an `Image` label.
