## 2024-05-18 - Clickable List Rows Area
**Learning:** In SwiftUI lists, placing a small button (like a checkmark circle) inside an `HStack` restricts the hit area and creates a poor VoiceOver experience. Users must click the tiny icon specifically, rather than the row itself.
**Action:** When creating selectable list rows, wrap the entire `HStack` inside a `Button`, change the visual toggle to a simple `Image`, apply `.contentShape(Rectangle())` so empty spaces are clickable, use `.buttonStyle(.plain)` to prevent text recoloring, and add `.accessibilityElement(children: .combine)`.
