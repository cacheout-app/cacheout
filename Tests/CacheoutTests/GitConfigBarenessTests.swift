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

    /// **AN INCLUDE CAN OVERRIDE core.bare, SO WE REFUSE TO GUESS**
    /// (PR #461 codex r3).
    ///
    /// `[core] bare = true` followed by `[include] path = …` whose included
    /// file sets `core.bare = false` is a NON-bare repository to git. Reading
    /// the included file is not available to this scanner, so an include that
    /// could reach `core.bare` makes the answer "not bare".
    ///
    /// Getting this wrong is not a silent miss: the directory is admitted as
    /// `.bareRepository`, git's own listing then disagrees, `crossValidate`
    /// fails, and a recurring `unreadable` issue is published for a healthy
    /// repository the scanner intends not to cover.
    ///
    /// MUTATION, measured: delete the include guard and exactly THREE cells
    /// red — this one, `…AnIncludeIfIsRefusedTheSameWay` and
    /// `…AnIncludeBeforeTheValueIsAlsoRefused`. The fourth,
    /// `…AnIncludeSectionWithoutAPathDoesNotSuppressBareness`, stays green,
    /// which is what shows the guard is keyed on the `path` key that git
    /// actually acts on rather than on the section name alone.
    func testAnIncludeThatCouldOverrideBarenessIsRefused() {
        XCTAssertFalse(bare("""
        [core]
        \tbare = true
        [include]
        \tpath = ../shared.config
        """))
    }

    func testAnIncludeIfIsRefusedTheSameWay() {
        XCTAssertFalse(bare("""
        [core]
        \tbare = true
        [includeIf "gitdir:~/work/"]
        \tpath = ~/work/.gitconfig
        """))
    }

    /// Conservative in the safe direction: an include BEFORE the explicit
    /// value is refused too, even though git would let the later explicit
    /// `true` win. That costs a silent non-discovery, never a false claim.
    func testAnIncludeBeforeTheValueIsAlsoRefused() {
        XCTAssertFalse(bare("[include]\n\tpath = x\n[core]\n\tbare = true\n"))
    }

    /// But only a REAL include directive counts — `path` is the only key git
    /// acts on, so an include section without one pulls in nothing and must
    /// not suppress a genuine answer.
    func testAnIncludeSectionWithoutAPathDoesNotSuppressBareness() {
        XCTAssertTrue(bare("[include]\n\tcomment = none\n[core]\n\tbare = true\n"))
    }

    /// **`extensions.worktreeConfig` LETS `config.worktree` OVERRIDE core.bare**
    /// (PR #461 codex r4). With the extension on, git reads a second file
    /// after the primary, so `bare = true` here can be `bare = false` there.
    /// Same shape as an include, same answer: the extension being ON makes
    /// the answer "not bare", and every spelling git reads as true counts,
    /// including the valueless key the `=`-only loop used to skip.
    ///
    /// MUTATION, measured: delete the extensions guard (both the valued arm
    /// and the valueless arm) and exactly THREE cells red — this one,
    /// `…EverySpellingGitReadsAsTrue…` (all five of its spellings) and
    /// `…AValuelessWorktreeConfigKey…` — 7 assertions, 3/3 runs. The
    /// `false`-and-subsection cell stays green, which is what shows the
    /// guard is keyed on the value and the exact section rather than on the
    /// key name alone. (A first draft of this note said "four"; there are
    /// three refusal cells, and the count is now the measured one.)
    func testAnEnabledWorktreeConfigExtensionRefusesBareness() {
        XCTAssertFalse(bare("[core]\n\tbare = true\n[extensions]\n\tworktreeConfig = true\n"))
    }

    func testEverySpellingGitReadsAsTrueEnablesTheExtension() {
        for spelling in ["yes", "on", "1", "TRUE", "\"true\""] {
            XCTAssertFalse(
                bare("[extensions]\n\tworktreeConfig = \(spelling)\n[core]\n\tbare = true\n"),
                "git reads `\(spelling)` as true, so the extension is on"
            )
        }
    }

    /// A key with no `=` is TRUE to git. The parse loop only reads
    /// `key = value` lines, so this spelling had to be caught before the
    /// `=` requirement dropped it.
    func testAValuelessWorktreeConfigKeyIsTrueAndRefuses() {
        XCTAssertFalse(bare("[extensions]\n\tworktreeConfig\n[core]\n\tbare = true\n"))
    }

    func testTheExtensionSetToFalseDoesNotSuppressBareness() {
        XCTAssertTrue(bare("[extensions]\n\tworktreeConfig = false\n[core]\n\tbare = true\n"))
        XCTAssertTrue(
            bare("[extensions \"other\"]\n\tworktreeConfig = true\n[core]\n\tbare = true\n"),
            "a subsection is not the extensions section"
        )
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
