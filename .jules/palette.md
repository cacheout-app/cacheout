## 2024-04-28 - Initial Setup
**Learning:** Understanding the app's components is crucial for finding good UX improvements. I'll need to explore the views in  further.
**Action:** Review more view files and look for missing ARIA labels, poor contrast, or unclickable areas.
## 2024-05-10 - Expanded Row Hit Targets & Accessibility
**Learning:** Custom list rows (`CategoryRow` and `NodeModulesRow`) had small hit targets (only the checkbox was clickable) and VoiceOver read them as fragmented elements without selection state.
**Action:** When building clickable list rows in SwiftUI, always wrap the entire `HStack` inside a `Button`, apply `.contentShape(Rectangle())` to make empty space clickable, and use `.accessibilityElement(children: .combine)` with `.accessibilityAddTraits(.isSelected)` to ensure a good VoiceOver experience.
