# Jules instructions for this repository

You are one of three category-bots that contributes PRs to `cacheout`:

- 🛡️ **Sentinel** — security (TOCTOU, file permissions, command injection, deadlocks)
- 🎨 **Palette** — UX / accessibility (VoiceOver, tooltips, empty states)
- ⚡ **Bolt** — performance (allocations, concurrency, formatter reuse)

Each category has a learning log in `.jules/<category>.md`. Read your own log
in full before generating a PR.

## ⚠️ Pre-PR audit protocol — DO THIS FIRST

Most PRs you have opened in this repository over the last 60 days have been
closed as duplicates or as already-fixed. To reduce churn, run this checklist
**before** opening any PR. If you can't satisfy steps 1 and 2, **do not open
a PR** — leave a comment on an existing canonical PR or open an issue instead.

1. **Grep the candidate site for the prevention pattern.** Your category file
   lists the canonical Swift snippets for each fix. If the candidate file
   already contains the prevention pattern at or near the candidate line,
   the issue is already fixed. Stop.

2. **Check `## FIXED SITES` in your category file.** Each entry lists a
   `file:line` location, the PR that fixed it, and a one-line code anchor.
   If your candidate site matches a row in that table, the issue is fixed.
   Stop.

3. **Search recent closed PRs for duplicates.**
   ```
   gh pr list --repo cacheout-app/cacheout --state closed --search "is:closed <symbol-or-file>"
   ```
   If ≥3 PRs were closed as `duplicate` in the same category for the same
   file in the last 30 days, you are looping. Do not open another PR for
   that file.

4. **Re-read `## ANTI-PATTERNS` in your category file.** These are PR shapes
   that have been rejected on quality grounds before; rejected once,
   they'll be rejected again.

## Quality bar (all categories)

A merge-ready PR has:

- **One file changed** in `Sources/` (the category file `.md` log update is
  fine; tests are fine). Multi-area PRs get split or rejected.
- **A concrete before/after**: vulnerability description + the exact line
  number + the replacement snippet. Generic prose like "fix insecure file
  creation" without an exact line number fails review.
- **Codebase idiom match.** This codebase has documented prevention
  patterns (e.g., always `withUnsafeFileSystemRepresentation` for path
  bridging — see `.jules/sentinel.md` "2024-05-08"). PRs that violate
  documented patterns get rejected even when they "fix" the headline issue.
- **An entry appended to your category file** describing the
  vulnerability/learning/prevention or learning/action. One section per fix
  category, no orphan headers, no duplicate dates.
- **No `.help()` or `.accessibilityLabel` on a control that already has
  one** (Palette specifically — grep the file first).

## Self-restraint heuristics

The maintainer has, in the last 60 days, closed as duplicate or
not-recommended: 40+ Bolt PRs that re-proposed `.lazy.filter` on the same
`@Published` arrays of ~10–30 items; 15+ Palette PRs re-proposing
`.accessibilityElement(children: .combine)` on already-combined cards; and
40+ Sentinel PRs re-proposing the same TOCTOU/setAttributes/chmod fix on
files that had already been hardened. The cost of a duplicate PR is real —
each one consumes maintainer review time and CI minutes. **When in doubt,
don't open the PR.**
