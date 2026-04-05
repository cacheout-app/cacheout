## 2024-05-24 - Make List Rows Completely Clickable
**Learning:** In SwiftUI, nested buttons inside rows often lead to poor VoiceOver experiences and narrow hit targets. Users expect the entire row to be clickable.
**Action:** Wrap the entire row contents (e.g., `HStack`) in a `Button`, apply `.contentShape(Rectangle())` to make empty space clickable, use `.buttonStyle(.plain)` to prevent unintended text styling, and add `.accessibilityElement(children: .combine)` along with state-appropriate traits like `.accessibilityAddTraits(.isSelected)`.
