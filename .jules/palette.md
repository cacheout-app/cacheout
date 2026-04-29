## 2024-04-29 - Improve SwiftUI list row accessibility and hit target
**Learning:** List rows with only a small checkbox button are hard to tap and have poor VoiceOver experience.
**Action:** Wrap the entire row in a Button with .contentShape(Rectangle()), .buttonStyle(.plain), and add .accessibilityElement(children: .combine) and .accessibilityAddTraits(.isSelected).
