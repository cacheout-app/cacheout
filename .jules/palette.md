## 2024-04-30 - Clickable List Rows and Accessibility
**Learning:** In SwiftUI lists, adding a `Button` only around a checkbox creates a tiny hit target that is hard to tap and poorly reported by VoiceOver.
**Action:** Wrap the entire row's `HStack` in a `Button`, apply `.contentShape(Rectangle())` to make empty space clickable, use `.buttonStyle(.plain)` to prevent unintended text styling, and apply `.accessibilityElement(children: .combine)` along with `.accessibilityAddTraits(.isSelected)` for optimal VoiceOver experience.

## 2024-05-24 - Accessibility Modifiers on Icon-only Controls
**Learning:** SwiftUI icon-only controls (e.g. Button, Menu, Toggle) with just an Image label need an `.accessibilityLabel` to be correctly read by VoiceOver. The `.help` modifier only adds a mouse hover tooltip but does not set the accessibility label. Without an explicit accessibility label, VoiceOver may read nothing or read generic terms like "Button".
**Action:** Always add an `.accessibilityLabel` to any interactive control that uses an icon-only label in SwiftUI, particularly when standardizing or refactoring views.

## 2024-05-24 - Empty States in Process Lists
**Learning:** Users can misinterpret an empty dynamic list (like processes) as a broken UI or a frozen app if there's no visual feedback indicating that the list is intentionally empty.
**Action:** Always provide a clear, empty state with an icon and brief text for dynamic lists that might temporarily yield no results, preventing user confusion.

## 2024-05-25 - Tooltips on Icon-only Controls
**Learning:** While `.accessibilityLabel` is required for VoiceOver users on icon-only controls, sighted mouse users can also struggle to understand the purpose of these controls without visual feedback.
**Action:** Always add a `.help()` modifier to icon-only controls in SwiftUI to provide a hover tooltip for mouse users, complementing the `.accessibilityLabel()` for screen reader users.

## 2024-05-25 - Dynamic Labels and Disabled State Tooltips
**Learning:** Users can feel confused when a primary button is disabled without explanation or when a long-running action lacks immediate inline text feedback on the button itself.
**Action:** In SwiftUI, enhance button accessibility and UX by adding `.help()` tooltips to explain the required state when disabled, and using dynamic labels (e.g., 'Scanning...') to provide immediate feedback during async operations.
## 2024-05-25 - Custom Section Header Accessibility
**Learning:** When implementing custom section header buttons with mixed content (icons, text, dynamic counts/sizes), VoiceOver needs help to correctly present the state and read all content.
**Action:** Apply `.accessibilityElement(children: .combine)`, a dynamic `.accessibilityValue` (e.g., 'Expanded' or 'Collapsed'), and an `.accessibilityHint`. Crucially, do not apply an explicit `.accessibilityLabel` to the combined element, as it overrides and hides the natural concatenation of the child text values.
