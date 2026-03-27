## 2026-03-27 - SwiftUI List Row Hit Targets and Accessibility
**Learning:** By default, placing a Button inside an HStack only makes the Button's icon clickable, creating a small hit target and causing VoiceOver to read elements separately.
**Action:** Wrap the entire HStack in a Button, add `.contentShape(Rectangle())` to make empty space clickable, use `.buttonStyle(.plain)` to prevent unintended styling, and add `.accessibilityElement(children: .combine)` to group the row content into a single accessible element.
