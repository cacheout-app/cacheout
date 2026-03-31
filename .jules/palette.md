# Palette's Journal - Critical Learnings

## 2024-05-20 - Expanded List Row Hit Targets
**Learning:** List rows in SwiftUI that contain an `HStack` with a small, nested `Button` (like a checkbox) result in a very small clickable hit target and fragmented VoiceOver focus.
**Action:** Always wrap the entire list row (e.g., `HStack`) inside a `Button`, replace inner nested buttons with static images, and apply `.contentShape(Rectangle())`, `.buttonStyle(.plain)`, and `.accessibilityElement(children: .combine)` to expand the hit target to the entire row and unify VoiceOver reading.
