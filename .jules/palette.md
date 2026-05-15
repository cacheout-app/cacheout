## 2024-04-30 - Clickable List Rows and Accessibility
**Learning:** In SwiftUI lists, adding a `Button` only around a checkbox creates a tiny hit target that is hard to tap and poorly reported by VoiceOver.
**Action:** Wrap the entire row's `HStack` in a `Button`, apply `.contentShape(Rectangle())` to make empty space clickable, use `.buttonStyle(.plain)` to prevent unintended text styling, and apply `.accessibilityElement(children: .combine)` along with `.accessibilityAddTraits(.isSelected)` for optimal VoiceOver experience.

## 2024-05-24 - Accessibility Modifiers on Icon-only Controls
**Learning:** SwiftUI icon-only controls (e.g. Button, Menu, Toggle) with just an Image label need an `.accessibilityLabel` to be correctly read by VoiceOver. The `.help` modifier only adds a mouse hover tooltip but does not set the accessibility label. Without an explicit accessibility label, VoiceOver may read nothing or read generic terms like "Button".
**Action:** Always add an `.accessibilityLabel` to any interactive control that uses an icon-only label in SwiftUI, particularly when standardizing or refactoring views.

## 2024-05-24 - Empty States in Process Lists
**Learning:** Users can misinterpret an empty dynamic list (like processes) as a broken UI or a frozen app if there's no visual feedback indicating that the list is intentionally empty.
**Action:** Always provide a clear, empty state with an icon and brief text for dynamic lists that might temporarily yield no results, preventing user confusion.

## 2024-05-24 - Dynamic Labels and Disabled State Tooltips
**Learning:** Users can be confused when a primary action button is disabled without explanation, and static labels during async operations fail to provide immediate status feedback.
**Action:** Enhance button UX by using dynamic labels (e.g., 'Scanning...') during async operations, and add `.help()` tooltips to disabled buttons to explain the required state to enable them.
