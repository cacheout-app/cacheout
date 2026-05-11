## 2024-04-30 - Clickable List Rows and Accessibility
**Learning:** In SwiftUI lists, adding a `Button` only around a checkbox creates a tiny hit target that is hard to tap and poorly reported by VoiceOver.
**Action:** Wrap the entire row's `HStack` in a `Button`, apply `.contentShape(Rectangle())` to make empty space clickable, use `.buttonStyle(.plain)` to prevent unintended text styling, and apply `.accessibilityElement(children: .combine)` along with `.accessibilityAddTraits(.isSelected)` for optimal VoiceOver experience.

## 2024-05-24 - Accessibility Modifiers on Icon-only Controls
**Learning:** SwiftUI icon-only controls (e.g. Button, Menu, Toggle) with just an Image label need an `.accessibilityLabel` to be correctly read by VoiceOver. The `.help` modifier only adds a mouse hover tooltip but does not set the accessibility label. Without an explicit accessibility label, VoiceOver may read nothing or read generic terms like "Button".
**Action:** Always add an `.accessibilityLabel` to any interactive control that uses an icon-only label in SwiftUI, particularly when standardizing or refactoring views.

## 2024-05-24 - Empty States in Process Lists
**Learning:** Users can misinterpret an empty dynamic list (like processes) as a broken UI or a frozen app if there's no visual feedback indicating that the list is intentionally empty.
**Action:** Always provide a clear, empty state with an icon and brief text for dynamic lists that might temporarily yield no results, preventing user confusion.

## 2024-05-25 - Consistency in Empty States
**Learning:** Standardizing visual empty states across an app creates a more predictable and polished experience. Plain text empty states (e.g. "No items found") feel unpolished compared to the rest of the application.
**Action:** When working on lists or dynamic content, ensure empty states match the established pattern (usually a centered VStack with a large tertiary icon and callout secondary text).
