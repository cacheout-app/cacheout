## 2024-04-30 - Clickable List Rows and Accessibility
**Learning:** In SwiftUI lists, adding a `Button` only around a checkbox creates a tiny hit target that is hard to tap and poorly reported by VoiceOver.
**Action:** Wrap the entire row's `HStack` in a `Button`, apply `.contentShape(Rectangle())` to make empty space clickable, use `.buttonStyle(.plain)` to prevent unintended text styling, and apply `.accessibilityElement(children: .combine)` along with `.accessibilityAddTraits(.isSelected)` for optimal VoiceOver experience.

## 2024-05-01 - Missing Accessibility Labels on Icon-Only Buttons
**Learning:** Icon-only buttons (like ellipsis menus or window icons) are completely opaque to VoiceOver users without explicit `.accessibilityLabel` modifiers, and lack hover context for mouse users without `.help` modifiers.
**Action:** Always verify that every `Button` or `Menu` with an `Image` label and no accompanying `Text` has an `.accessibilityLabel` and a `.help` tooltip.
