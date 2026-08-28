import XCTest
@testable import Cacheout

/// `GitWorktreeGitdirResolver.declaresBare` — the EFFECTIVE `core.bare`
/// (PR #461 codex r2).
///
/// The function shipped with no cell of any kind, and it matched any line
/// whose key was `bare` anywhere in the file. Two config shapes git reads
/// the other way slipped through, and both make the scanner claim a
/// repository it deliberately does not cover: it then runs `worktree list`
/// against a healthy non-bare admin directory and publishes a
/// cross-validation `unreadable` issue on EVERY scan.
///
/// MUTATION, both directions, MEASURED rather than asserted:
///
/// - restoring the any-line matcher reds 7 cells / 8 assertions, including
///   both cells written for the finding — `…AnUnrelatedSectionsBareKey…`
///   and `…ALaterFalseTurnsBarenessOff` — plus subsection, header-line,
///   comment, quoted-value and no-section coverage;
/// - replacing the last-wins assignment with a first-wins one reds exactly
///   2 cells, `…ALaterFalseTurnsBarenessOff` and
///   `…TheLastValueWinsInTheOtherDirectionToo`, and nothing else.
///
/// Both measured on the shipped tree, 12/12 green unmutated.
final class GitConfigBarenessTests: XCTestCase {

    private func bare(_ text: String) -> Bool {
        GitWorktreeGitdirResolver.declaresBare(text)
    }

    func testGitsOwnWriterSpellingIsRecognised() {
        XCTAssertTrue(bare("[core]\n\tbare = true\n"))
        XCTAssertTrue(bare("[core]\n\trepositoryformatversion = 0\n\tbare = true\n"))
    }

    func testAHealthySeparateGitDirIsNotBare() {
        XCTAssertFalse(bare("[core]\n\tbare = false\n\tworktree = /Users/x/p\n"))
    }

    /// THE FINDING. A `--separate-git-dir` repository is `core.bare = false`,
    /// but any other section may carry its own `bare` key — `[remote]` and
    /// `[submodule]` both do in the wild.
    func testAnUnrelatedSectionsBareKeyIsNotCoreBare() {
        XCTAssertFalse(bare("""
        [core]
        \tbare = false
        [remote "origin"]
        \tbare = true
        """))
        XCTAssertFalse(bare("""
        [submodule "vendor"]
        \tbare = true
        """))
    }

    /// THE OTHER HALF OF THE FINDING: an override must be able to turn
    /// bareness OFF, not merely fail to turn it on. git takes the last
    /// value. (Renamed off `…AValuelessOverride…`, which named something
    /// this cell does not contain — the valueless key is pinned below.)
    func testALaterFalseTurnsBarenessOff() {
        XCTAssertFalse(bare("[core]\n\tbare = true\n[core]\n\tbare = false\n"))
    }

    func testTheLastValueWinsInTheOtherDirectionToo() {
        XCTAssertTrue(bare("[core]\n\tbare = false\n[core]\n\tbare = true\n"))
    }

    /// `[core "sub"]` is `core.sub.bare`, a different key entirely.
    func testASubsectionIsNotTheCoreSection() {
        XCTAssertFalse(bare("[core \"weird\"]\n\tbare = true\n"))
    }

    func testAVariableOnTheSectionHeaderLineIsRead() {
        XCTAssertTrue(bare("[core] bare = true\n"))
    }

    func testCommentsAreNotConfiguration() {
        XCTAssertFalse(bare("[core]\n\t#bare = true\n"))
        XCTAssertFalse(bare("[core]\n\t;bare = true\n"))
        XCTAssertTrue(bare("[core]\n\tbare = true # was false\n"))
    }

    func testAQuotedValueIsTheValueItQuotes() {
        XCTAssertTrue(bare("[core]\n\tbare = \"true\"\n"))
    }

    func testCaseAndWhitespaceDoNotChangeTheAnswer() {
        XCTAssertTrue(bare("[CORE]\n   BARE   =   TRUE   \n"))
    }

    func testNothingIsNotBare() {
        XCTAssertFalse(bare(""))
        XCTAssertFalse(bare("\n\n"))
        XCTAssertFalse(bare("bare = true\n"), "no section: not core.bare")
    }

    /// THE DISCLOSED RESIDUAL, PINNED so it cannot change in silence. Only
    /// git's writer spelling of the value counts; these three leave the
    /// repository undiscovered, which is the same silence every bare
    /// repository had before fn-4.28 — never a refusal dressed as retryable.
    func testTheNarrowValueSpellingIsDeliberateAndStillNarrow() {
        XCTAssertFalse(bare("[core]\n\tbare = yes\n"))
        XCTAssertFalse(bare("[core]\n\tbare = 1\n"))
        XCTAssertFalse(bare("[core]\n\tbare\n"), "valueless key: git says true")
    }
}
