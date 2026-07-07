# 🎨 Palette — UX / accessibility learning log

Read `.jules/README.md` first. Then re-read the **FIXED SITES** and
**ANTI-PATTERNS** sections below before considering any PR. Over 25 Palette
PRs have been closed as duplicates in the last 60 days — most of them
re-proposed `.accessibilityElement(children: .combine)` on views that
already had it, or stacked redundant `.help()` modifiers.

## ✅ FIXED SITES — do not re-propose

| File | Symbol | Modifier applied | By |
|---|---|---|---|
| `Sources/Cacheout/Views/NodeModulesSection.swift` | section-header button | `.accessibilityValue(isExpanded ? "Expanded" : "Collapsed")` | #394 |
| `Sources/Cacheout/Views/MemoryView.swift` | two stat-card views | `.accessibilityElement(children: .combine)` | #401 |
| `Sources/Cacheout/Views/DiskUsageBar.swift` | outer disk-usage bar | `.accessibilityElement(children: .combine)` | #409 |
| `Sources/Cacheout/Views/MenuBarView.swift` | `statPill` | `.accessibilityElement(children: .combine)` | #409 |
| `Sources/Cacheout/Views/MenuBarView.swift` | Scan, Quick Clean, Docker Prune buttons | `.help(...)` disabled-state tooltips | #379 |
| `Sources/Cacheout/Views/SettingsContentView.swift` | Docker Prune button | dynamic "Pruning…" label + `.help(...)` | #263 |
| `Sources/Cacheout/Views/ContentView.swift` | Scan, Clean buttons | dynamic labels + `.help(...)` | #259 |
| `Sources/Cacheout/Views/ContentView.swift` | per-process menu | `.help(...)` tooltip | merged pre-v2.1.0 |

**Before opening any Palette PR**, grep the candidate file:

```sh
# Already has accessibility combine?
grep -n "accessibilityElement(children" <candidate-file>
# Already has help tooltip?
grep -n "\.help(" <candidate-file>
# Already has accessibilityLabel/Value?
grep -nE "accessibilityLabel|accessibilityValue|accessibilityAddTraits" <candidate-file>
```

## 🚫 ANTI-PATTERNS — these PRs will be rejected

1. **`.accessibilityElement(children: .combine)` placed BEFORE `.padding()`
   and `.background()`.** Combine should be applied at the OUTERMOST
   modifier position so the combined element includes the visual frame.
   PR #405 was closed for this exact mistake — same modifier, wrong
   placement.

2. **Adding `.help()` or `.accessibilityLabel` to a control that already
   has one.** Grep first. Stacking two `.help()` calls only the last one
   wins; stacking two `.accessibilityLabel` is silently ambiguous.

3. **Adding `.accessibilityValue` to a control whose value is already
   conveyed by its text label.** Only add `.accessibilityValue` when the
   STATE is not part of the visible label — e.g., expand/collapse where
   only a chevron icon changes.

4. **Combining `.accessibilityElement(children: .combine)` with `.contain`
   on the same view.** Pick one. `.combine` flattens children into one
   element; `.contain` keeps children individually addressable. Conflating
   them produces broken VoiceOver output.

5. **Generic titles like "Improve accessibility of node_modules header" or
   "Add accessibility to dashboard".** Title must name the specific
   view/control. Generic titles read as a re-run of an earlier closed PR.

## Quality requirements for UX PRs

- Title format: `🎨 Palette: <verb> <specific-modifier> to <Control> in <File.swift>`
- Body must include: the specific symbol, the user-visible scenario that
  was confusing/broken (e.g., "VoiceOver reads 'Memory' and '8.2 GB' as
  two separate items"), the resulting one-line behavior.
- Test in VoiceOver (or describe the expected announcement) before
  submitting. A PR body that says only "improves accessibility" doesn't
  describe a tested outcome.
- Always update this file with an entry under `## Learning log`.

---

## Learning log

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

## 2024-05-26 - Accessibility for Custom Collapsible Sections
**Learning:** Custom buttons functioning as collapsible sections (like DisclosureGroups) rely on visual cues and lack implicit state readout.
**Action:** Explicitly add an `.accessibilityValue` (e.g., `isExpanded ? "Expanded" : "Collapsed"`) to announce their state to VoiceOver users.

## 2024-05-27 - Dashboard Stat Grouping
**Learning:** VoiceOver users have to swipe multiple times to hear a single statistic if its label and value are separate text elements in a dashboard card. This creates a fragmented and tedious reading experience.
**Action:** Always apply `.accessibilityElement(children: .combine)` to SwiftUI stat cards or metric views that group a title and a value. Apply it at the OUTERMOST modifier position (after `.padding()` and `.background()`) so the entire visible card is one element. Applying it inside the chrome is a common mistake.
## 2024-05-28 - Empty State Accessibility Grouping
**Learning:** VoiceOver reads the icon, headline, and subtext of an empty state as disjointed fragments, forcing the user to swipe multiple times to understand the full message.
**Action:** Always apply `.accessibilityElement(children: .combine)` to the container (e.g., `VStack`) wrapping an empty state so VoiceOver announces it as a single cohesive statement.
