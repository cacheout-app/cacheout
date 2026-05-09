## 2024-05-24 - NodeModulesSection Header Accessibility
**Learning:** Disclosure groups built with custom `Button` and `Image` primitives in SwiftUI lack native expand/collapse semantics for VoiceOver, unlike the native `DisclosureGroup` component.
**Action:** When building custom expand/collapse headers, explicitly add `.accessibilityAddTraits(.isButton)`, an `.accessibilityLabel`, an `.accessibilityValue` (Expanded/Collapsed), and a `.help` tooltip.
