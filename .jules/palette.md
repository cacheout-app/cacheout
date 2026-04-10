## 2024-04-10 - Clickable List Rows
**Learning:** Checkbox-only buttons in list rows create poor hit targets and VoiceOver reads row contents fragmentally.
**Action:** Wrapped list rows in Button with contentShape(Rectangle()), buttonStyle(.plain), accessibilityElement(children: .combine), and .accessibilityAddTraits(.isSelected) to make the entire row clickable and improve VoiceOver experience.
