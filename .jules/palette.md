## 2024-04-19 - Make entire list rows clickable

**Learning:** Using a small, dedicated checkbox button within a row forces users to target a tiny 20x20 area, causing a poor mouse/touch experience, and separates the row content from the interactive element for VoiceOver users.

**Action:** Wrap the entire row contents (e.g., `HStack`) in a single `Button`, apply `.contentShape(Rectangle())` so that empty spaces within the row are clickable, apply `.buttonStyle(.plain)` to prevent default button styling (like turning all text blue), and apply `.accessibilityElement(children: .combine)` alongside `.accessibilityAddTraits(.isSelected)` so VoiceOver treats the entire row as a single actionable, selectable element.
