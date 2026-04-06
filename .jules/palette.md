## 2024-05-24 - Clickable List Rows
**Learning:** Wrapping an entire row (`HStack`) in a `Button` with `.contentShape(Rectangle())` provides a much larger hit target than a standalone checkbox, significantly improving mouse/touch UX. Combining accessibility elements and adding `.isSelected` ensures a proper VoiceOver experience.
**Action:** Use this pattern for all selectable list rows instead of small embedded toggle buttons.
