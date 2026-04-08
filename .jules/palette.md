## 2024-04-08 - Clickable List Rows
**Learning:** In SwiftUI, wrapping an HStack in a Button and adding `.contentShape(Rectangle())` significantly increases the hit target for list items, while `.accessibilityElement(children: .combine)` ensures VoiceOver reads the entire row as a single actionable element.
**Action:** When creating clickable list rows, ensure the entire row contents are wrapped in a Button with a Rectangle content shape, and apply appropriate accessibility traits like `.isSelected`.
