## 2024-05-30 - Make SwiftUI List Rows Fully Clickable
**Learning:** In SwiftUI, just having a button in an HStack restricts the clickable area. Furthermore, wrapping an HStack in a button requires `.contentShape(Rectangle())` to make whitespace clickable and specific `.accessibilityElement(children: .combine)` and `.accessibilityAddTraits` to ensure proper VoiceOver behavior.
**Action:** Always wrap the entire row contents in a Button, apply `.contentShape(Rectangle())`, and apply proper accessibility traits when building custom list rows.
