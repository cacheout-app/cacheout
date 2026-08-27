import Foundation
import XCTest
@testable import Cacheout

/// The refusal-TAG gate for `WorktreeReclaimPerformer` (fn-4.23).
///
/// ## THE DECISION THIS FILE RECORDS
///
/// The tag is the discriminator the reclaim architecture rests on —
/// `CacheCleaner` maps tags to log categories and the GUI/CLI surface the
/// refusals — yet before this gate only 4 of the performer's 33 distinct
/// tags were asserted by any cell (`worktree-locked`, `worktree-replaced`,
/// `worktree-lock-unreadable`, `prune-admin-lock-unreadable`), so a fixer
/// could swap two tags between arms with the whole suite green. The task
/// offered two designs:
///
///   (a) a FULL per-tag gate — every production tag pinned to its arm;
///   (b) a SET gate (no tag added or removed unnoticed) plus behavioral
///       assertions for the arms that reach a user.
///
/// **This file chooses (a)**, and implements it as a SOURCE CENSUS rather
/// than 29 new behavioral cells, because (b) cannot meet the task's own
/// mutation bar: swapping two tags between arms leaves the SET unchanged,
/// so a set gate alone can never redden on the exact rot this task is
/// about. The census pins the ORDERED sequence of tag literals at their
/// definition sites, so any swap of two different tags changes the pinned
/// sequence in at least two positions — and a tag added or removed changes
/// it too, which is why no separate set gate exists (the spec's "do not
/// add both"): sequence equality subsumes set equality. The user-reaching
/// wording is the DETAIL, not the tag (the r17 lesson), and details keep
/// their behavioral assertions in `WorktreeReclaimPerformerTests`; this
/// gate protects the routing layer underneath them.
///
/// ## HOW THE CENSUS ASSERTS A PROPERTY, NOT A BLOCKLIST
///
/// Two layers, on the comment-blanked production source:
///
/// 1. **Position census** (`testEveryRefusalTagArmCarriesItsPinnedTag`):
///    every whole-literal hyphenated token in tag position — after `tag:`,
///    `replaced:`, `unreadable:`, `logRefusal(`, `return` / `return (`, or
///    alone on a continuation line — must match the pinned sequence, in
///    file order.
/// 2. **Lexicon sweep** (`testNoTagShapedLiteralEscapesTheCensus`): every
///    whole-literal hyphenated token ANYWHERE in the file is either
///    captured by layer 1 or on the pinned non-tag allowlist. A tag
///    introduced through a spelling layer 1 does not know — a `let`
///    binding, a new argument label — fails HERE rather than silently
///    joining the population unfenced.
///
/// Mutation-proven at introduction: swapping `worktree-deregistered` with
/// `worktree-not-linked` reddens layer 1; swapping the two
/// `prunedAdminBinding` literals reddens layer 1; adding
/// `let t = "brand-new-tag"` reddens layer 2.
final class WorktreeRefusalTagGateTests: XCTestCase {

    // MARK: - The pinned population

    /// Every refusal-tag literal in `WorktreeReclaimPerformer.swift`, in
    /// file order. 42 occurrences of 33 distinct tags at this commit. A
    /// legitimate new arm, removed arm, or renamed tag updates THIS list in
    /// the same commit, which is the point: the gate makes tag changes loud.
    private static let pinnedTagSequence: [String] = [
        "malformed-item",
        "worktree-ignored-appeared",
        "prune-recompute-failed",
        "prune-set-changed",
        "prune-measurement-denied",
        "prune-final-check-failed",
        "prune-set-grew",
        "prune-checkout-revived",
        "prune-checkout-revived",
        "prune-checkout-revived",
        "worktree-head-unwitnessable",
        "parent-repo-unresolvable",
        "parent-repo-unresolvable",
        "parent-repo-unresolvable",
        "parent-repo-unresolvable",
        "parent-repo-rebound",
        "worktree-registry-unreadable",
        "worktree-registry-unreadable",
        "worktree-registry-unreadable",
        "worktree-registry-unreadable",
        "worktree-deregistered",
        "worktree-not-linked",
        "worktree-locked",
        "worktree-identity-unresolvable",
        "worktree-identity-unreadable",
        "worktree-identity-rebound",
        "worktree-identity-unbound",
        "worktree-identity-recreated",
        "worktree-replaced",
        "worktree-unreadable",
        "prune-admin-replaced",
        "prune-admin-unreadable",
        "worktree-locked",
        "worktree-lock-unreadable",
        "worktree-head-unreadable",
        "worktree-head-moved",
        "prune-admin-locked",
        "prune-admin-lock-unreadable",
        "worktree-unmerged",
        "worktree-ancestry-unanswered",
        "worktree-dirty",
        "worktree-recheck-failed",
    ]

    /// Whole-literal hyphenated tokens in the file that are NOT refusal
    /// tags, each with the exact number of occurrences it is allowed. An
    /// entry here is reviewed prose, not an escape hatch: layer 2 fails on
    /// a count drift in EITHER direction.
    private static let pinnedNonTagLiterals: [String: Int] = [
        "rev-parse": 1,   // a git subcommand in an argument vector
    ]

    // MARK: - Extraction

    private struct TagHit {
        let token: String
        let line: Int
        let inTagPosition: Bool
    }

    /// `WorktreeReclaimPerformer.swift`, comments blanked so a tag QUOTED
    /// in prose is never censused. String literals are NOT blanked — the
    /// tags are string literals.
    private func performerSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/CacheoutTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/Cacheout/Cleaner")
            .appendingPathComponent("WorktreeReclaimPerformer.swift")
        let raw = try String(contentsOf: url, encoding: .utf8)
        return StrandFenceTests.blankingComments(raw)
    }

    /// Every whole-literal hyphenated lowercase token — `"abc-def"`, the
    /// quotes immediately bracketing the token — classified by the code
    /// that precedes it on its own line.
    private func tagShapedLiterals(in source: String) -> [TagHit] {
        var hits: [TagHit] = []
        var cursor = source.startIndex
        while let match = source.range(
            of: #""[a-z0-9]+(-[a-z0-9]+)+""#,
            options: .regularExpression,
            range: cursor..<source.endIndex
        ) {
            let token = String(source[match].dropFirst().dropLast())
            let lineStart = source[..<match.lowerBound]
                .lastIndex(of: "\n")
                .map(source.index(after:)) ?? source.startIndex
            let prefix = String(source[lineStart..<match.lowerBound])
            let inTagPosition = prefix.range(
                of: #"(\btag:|\breplaced:|\bunreadable:|\blogRefusal\(|\breturn(\s*\()?)\s*$"#,
                options: .regularExpression
            ) != nil || prefix.range(
                of: #"^\s*$"#, options: .regularExpression
            ) != nil
            let line = source[source.startIndex..<match.lowerBound]
                .filter { $0 == "\n" }.count + 1
            hits.append(TagHit(
                token: token, line: line, inTagPosition: inTagPosition
            ))
            cursor = match.upperBound
        }
        return hits
    }

    // MARK: - Layer 1: every arm carries its pinned tag, in order

    func testEveryRefusalTagArmCarriesItsPinnedTag() throws {
        let source = try performerSource()
        XCTAssertGreaterThan(
            source.count, 10_000,
            "the gate must actually have read the performer source"
        )
        let censused = tagShapedLiterals(in: source)
            .filter { $0.inTagPosition }
        let sequence = censused.map(\.token)

        // Diff-friendly: name the first diverging position and its line
        // before asserting whole-sequence equality.
        for (position, pair) in zip(sequence, Self.pinnedTagSequence)
            .enumerated()
        where pair.0 != pair.1 {
            let hit = censused.dropFirst(position).first
            XCTFail(
                "refusal tag census diverges at position \(position) "
                    + "(source line \(hit.map(\.line) ?? -1)): production "
                    + "says '\(pair.0)', the pin says '\(pair.1)'. A "
                    + "legitimate tag change updates pinnedTagSequence in "
                    + "the same commit."
            )
            break
        }
        XCTAssertEqual(
            sequence, Self.pinnedTagSequence,
            "the performer's refusal tags, in file order, must match the "
                + "pinned census — a swap, insertion, or removal all "
                + "change this sequence"
        )
        XCTAssertEqual(
            Set(sequence).count, 33,
            "33 distinct tags at this commit; a rename or retirement "
                + "updates this count deliberately"
        )
    }

    // MARK: - Layer 2: no tag-shaped literal escapes the census

    func testNoTagShapedLiteralEscapesTheCensus() throws {
        let source = try performerSource()
        let escaped = tagShapedLiterals(in: source)
            .filter { !$0.inTagPosition }
        var counts: [String: Int] = [:]
        for hit in escaped {
            counts[hit.token, default: 0] += 1
        }
        XCTAssertEqual(
            counts, Self.pinnedNonTagLiterals,
            "every whole-literal hyphenated token the position census does "
                + "not capture must be pinned here as a NON-tag: a refusal "
                + "tag introduced through a new spelling (a let binding, a "
                + "new argument label) lands in this list's failure rather "
                + "than outside the fence. Escaped: "
                + "\(escaped.map { "\($0.token)@\($0.line)" })"
        )
    }

    // MARK: - The census reads the file the suite runs against

    func testTheCensusTotalsAreSelfConsistent() throws {
        let source = try performerSource()
        let hits = tagShapedLiterals(in: source)
        XCTAssertEqual(
            hits.count,
            Self.pinnedTagSequence.count
                + Self.pinnedNonTagLiterals.values.reduce(0, +),
            "position census plus non-tag allowlist must account for every "
                + "tag-shaped literal in the file — a drift here means one "
                + "of the two pinned lists rotted"
        )
    }
}
