#!/bin/bash
# Release gates, SHARED (PR #460 codex r20).
#
# This lived inside bundle.sh, which meant it gated only the paths bundle.sh
# owns. The repository's DOCUMENTED distribution command is
# `bash scripts/build-dmg.sh` (docs/v1/BUILD-AND-DISTRIBUTION.md), and that
# script independently produces a distributable DMG and prints the signing,
# notarization and `gh release upload` steps — so a release could follow the
# documented path while a RELEASE-BLOCKING status was still open, which is
# exactly the guarantee the gate exists to make.
#
# Sourced, never executed. Every script that can produce a distributable
# artifact must call `check_release_gates` before producing it; a new such
# script that does not is the same defect again.

# Set by the sourcing script when it has its own; otherwise derived here so
# the helper is correct on its own terms rather than depending on its caller.
: "${PROJECT_DIR:="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"}"

check_release_gates() {
    changelog="$PROJECT_DIR/CHANGELOG.md"
    if [ ! -f "$changelog" ]; then
        echo "❌ CHANGELOG.md not found — release gates cannot be verified"
        return 1
    fi
    if ! grep -qE '^## \[Unreleased\]' "$changelog"; then
        echo "❌ CHANGELOG.md has no [Unreleased] section — release gates cannot be verified"
        return 1
    fi
    # The [Unreleased] section only: gates in shipped sections are history,
    # not preconditions.
    unreleased=$(awk '/^## \[Unreleased\]/{inside=1; next} /^## \[/{inside=0} inside' "$changelog")

    # (a) STRUCTURE — each gate marker is followed by exactly one status line
    # before the next marker. Counting markers against statuses is NOT
    # equivalent: two gates where one carries two statuses and the other none
    # would balance out, leaving an unverified gate. Positional pairing is
    # what the recorded form actually claims, so that is what is checked.
    #
    # A STATUS LINE IS ANY `Status:` LINE, well-formed or not. Recognizing
    # only the well-formed spelling here would let a typo'd line
    # (`Status: *NOT SATISFIED*`) be skipped as prose, so a valid status
    # beneath it would close a gate the typo was trying to hold open.
    # Structure first over every candidate, spelling second — a malformed
    # status is then either an ORPHAN (two under one gate) or refused by
    # name in pass (b).
    pairing=$(printf '%s\n' "$unreleased" | awk '
        /\*\*RELEASE-BLOCKING/ {
            if (awaiting) { print "MISSING_STATUS"; exit }
            awaiting = 1; gates++; next
        }
        /^[ \t]*Status:/ {
            if (!awaiting) { print "ORPHAN_STATUS\t" $0; exit }
            awaiting = 0; next
        }
        END { if (awaiting) print "MISSING_STATUS"; else print "OK\t" gates+0 }
    ')
    case "$pairing" in
        MISSING_STATUS*)
            echo "❌ CHANGELOG.md [Unreleased]: a RELEASE-BLOCKING gate has no status line."
            echo "   Every gate carries EXACTLY ONE 'Status: **…**' line beneath it."
            echo "   An unverifiable gate never passes."
            return 1
            ;;
        ORPHAN_STATUS*)
            echo "❌ CHANGELOG.md [Unreleased]: a gate status line belongs to no gate:"
            echo "  ${pairing#ORPHAN_STATUS	}"
            echo "   A duplicate or stray status means the record is broken, so the"
            echo "   gate it claims to describe cannot be verified."
            return 1
            ;;
    esac

    gate_count=${pairing#OK	}
    if [ "$gate_count" = "0" ]; then
        echo "✅ No release-blocking gates recorded in CHANGELOG.md [Unreleased]"
        return 0
    fi

    # (b) SPELLING — every paired status is one of the two admissible forms.
    #
    # COUNTED, not iterated. A `while read` fed by a heredoc needs a writable
    # temporary file, and a shell that cannot create one SKIPS the loop
    # silently — the body never runs, no status is ever rejected, and the
    # function falls through to "satisfied". A gate that passes because the
    # filesystem was full is the fail-open this whole check exists to
    # prevent, so the validation uses only pipes and arithmetic: any grep
    # that cannot run yields a count of 0, which fails the equality below and
    # blocks.
    status_lines=$(printf '%s\n' "$unreleased" | grep -E '^[[:space:]]*Status:' || true)
    open_count=$(printf '%s\n' "$status_lines" |
        grep -cE '^[[:space:]]*Status: \*\*NOT SATISFIED\*\*' || true)
    satisfied_count=$(printf '%s\n' "$status_lines" |
        grep -cE '^[[:space:]]*Status: \*\*SATISFIED at [0-9a-f]{7,40}\*\*([[:space:]].*)?$' || true)

    if [ "$open_count" -gt 0 ]; then
        echo "❌ An open release-blocking gate in CHANGELOG.md [Unreleased]:"
        printf '%s\n' "$status_lines" | grep -E '^[[:space:]]*Status: \*\*NOT SATISFIED\*\*'
        echo "   Run the gate's recorded verification, then replace that line's"
        echo "   **NOT SATISFIED** with **SATISFIED at <commit-hash>**."
        return 1
    fi
    if [ "$satisfied_count" -ne "$gate_count" ]; then
        echo "❌ Malformed release-gate status in CHANGELOG.md [Unreleased]"
        echo "   ($gate_count gate(s), $satisfied_count well-formed status line(s)):"
        printf '%s\n' "$status_lines" |
            grep -vE '^[[:space:]]*Status: \*\*SATISFIED at [0-9a-f]{7,40}\*\*([[:space:]].*)?$' || true
        echo "   Admissible: 'Status: **NOT SATISFIED**' or"
        echo "   'Status: **SATISFIED at <commit-hash>**' (7-40 hex characters)."
        echo "   Anything else is unverifiable and therefore blocks."
        return 1
    fi

    echo "✅ Every release-blocking gate in CHANGELOG.md [Unreleased] is satisfied"
}
