## 2024-04-09 - Full-row hit targets and VoiceOver support
**Learning:** Users expect to be able to click anywhere on a list row to toggle its state, and VoiceOver needs grouped elements with dynamic selection traits to properly announce list items.
**Action:** Wrap row components (like HStack) in a Button with `.buttonStyle(.plain)` and `.contentShape(Rectangle())` to make empty space clickable. Apply `.accessibilityElement(children: .combine)` and dynamic `.accessibilityAddTraits(.isSelected)` based on state.
