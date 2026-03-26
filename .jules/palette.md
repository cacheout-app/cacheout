## 2024-03-26 - SwiftUI List Row Hit Targets
**Learning:** In custom SwiftUI list rows, if only a small element like a checkbox is wrapped in a `Button`, the rest of the row space is unclickable and the VoiceOver experience is fragmented.
**Action:** Always wrap the entire row structure (e.g., `HStack`) in a `Button`, apply `.contentShape(Rectangle())` so empty spaces register clicks, use `.buttonStyle(.plain)` to prevent default styling, and add `.accessibilityElement(children: .combine)` so screen readers announce the row content cohesively.
