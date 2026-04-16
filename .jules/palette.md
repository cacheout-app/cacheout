## 2025-04-16 - Make list rows fully clickable and accessible
**Learning:** In SwiftUI lists, placing a small button (like a checkbox) inside an HStack creates a tiny tap target that is hard to hit, and VoiceOver reads each text element separately instead of describing the whole row.
**Action:** Wrap the entire `HStack` in a `Button`, apply `.contentShape(Rectangle())` to make empty space clickable, use `.buttonStyle(.plain)`, and add `.accessibilityElement(children: .combine)` with `.accessibilityAddTraits(.isSelected)` for a much better UX and VoiceOver experience.
