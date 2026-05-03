## 2024-04-30 - Clickable List Rows and Accessibility
**Learning:** In SwiftUI lists, adding a `Button` only around a checkbox creates a tiny hit target that is hard to tap and poorly reported by VoiceOver.
**Action:** Wrap the entire row's `HStack` in a `Button`, apply `.contentShape(Rectangle())` to make empty space clickable, use `.buttonStyle(.plain)` to prevent unintended text styling, and apply `.accessibilityElement(children: .combine)` along with `.accessibilityAddTraits(.isSelected)` for optimal VoiceOver experience.

## 2024-05-03 - Icon-Only Control Accessibility
**Learning:** In SwiftUI, `Button` or `Menu` components with an `Image` label and no `Text` do not provide sufficient context for VoiceOver or mouse hover. They are read simply as "Button" or the image name if available.
**Action:** Always explicitly include an `.accessibilityLabel` for VoiceOver support and a `.help` modifier for mouse hover context on any icon-only control.
