import XCTest
@testable import Cacheout

/// THE CHECKED-IN XCODE PROJECT LISTS EVERY TRACKED SOURCE (PR #461 codex r4).
///
/// `Cacheout.xcodeproj/project.pbxproj` is GENERATED from `project.yml`, and
/// it is also checked in — so it can silently go stale, and it had. Three
/// files were absent when this cell was written: `DepthSafeRemoval.swift`,
/// `TrashDisposal.swift` (both of them deletion primitives, missing since
/// mid-August) and `FirstWinsRendezvous.swift`, which carries `LaunchClaim`
/// and `ClaimedProcess`.
///
/// `swift build` never notices, because SPM globs the directory. The path
/// that notices is the one that SHIPS: `scripts/build-dmg.sh` regenerates the
/// project only `if command -v xcodegen`, and otherwise builds the stale
/// checked-in copy, where those symbols cannot resolve. The generated file
/// was last touched by a MERGE, which is what generated artifacts do when
/// nothing watches them.
///
/// The listing comes from `git ls-files`, not a directory walk: a walk would
/// sweep untracked scratch files and make the verdict a property of the
/// machine rather than of the repository.
///
/// MUTATION, measured on three shapes rather than asserted: removing the
/// three files `1bf97cd` restored reds it naming all three; removing the four
/// `ContentView.swift` lines reds it, where the substring version stayed
/// GREEN masked by `SettingsContentView.swift`; removing the helper's
/// `main.swift` reds it, where the substring version stayed GREEN masked by
/// the app's `main.swift`. `xcodegen generate` is the fix in every case.
final class XcodeProjectCoverageTests: XCTestCase {

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testEveryTrackedSourceFileIsInTheCheckedInXcodeProject() throws {
        let list = Process()
        list.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        list.arguments = [
            "git", "-C", repositoryRoot.path, "ls-files", "-z", "--",
            "Sources/*.swift",
        ]
        let out = Pipe()
        list.standardOutput = out
        try list.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        list.waitUntilExit()
        XCTAssertEqual(list.terminationStatus, 0, "git ls-files failed")

        let paths = String(decoding: data, as: UTF8.self)
            .split(separator: "\0").map(String.init).sorted()
        XCTAssertGreaterThan(
            paths.count, 50,
            "the listing came back with \(paths.count) entries — this cell is "
                + "checking almost nothing"
        )

        let project = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Cacheout.xcodeproj/project.pbxproj"
            ),
            encoding: .utf8
        )
        // A vacuity floor on the project too: an empty or truncated pbxproj
        // would otherwise "contain" nothing and fail every row for one reason.
        XCTAssertTrue(
            project.contains("PBXSourcesBuildPhase"),
            "the project file does not look like a pbxproj at all"
        )

        // MEMBERSHIP OF A SOURCES PHASE, not "this basename occurs
        // somewhere in the file" (PR #461 gate r5, P4). The first version
        // asked `project.contains(name)`, and its own claim that deleting any
        // entry would red it was measured FALSE twice: `ContentView.swift` is
        // a substring of `SettingsContentView.swift`, and `main.swift` exists
        // twice (the app and the helper daemon), so each masked the other's
        // absence. Those two are the app's root view and the helper's entry
        // point — the files whose absence breaks the bundle hardest were
        // precisely the ones the fence could not see. It passed for the three
        // files it was written for, which is why the vacuity was invisible.
        //
        // xcodegen emits `/* <name> in Sources */` TWICE per membership —
        // once declaring the `PBXBuildFile` and once listing it in the
        // phase's `files` array — and only the second ends in a comma. The
        // first version of this counter matched both, so a basename carried
        // by N files yielded 2N markers and the `found < N` test could never
        // fire; removing one of the two `main.swift` memberships left three
        // markers against a requirement of two and stayed GREEN. Measured,
        // not reasoned: that mutation is M2 in the list above.
        //
        // The `/* ` prefix stops a longer basename from satisfying a shorter
        // one; the trailing comma counts memberships rather than mentions; a
        // basename carried by N tracked files needs N of them. More than N is
        // fine — a file may legitimately belong to several targets.
        var required: [String: Int] = [:]
        for path in paths {
            guard let name = path.split(separator: "/").last else { continue }
            required[String(name), default: 0] += 1
        }
        let absent = required.compactMap { name, count -> String? in
            let marker = "/* \(name) in Sources */,"
            var found = 0
            var cursor = project.startIndex
            while let hit = project.range(
                of: marker, range: cursor..<project.endIndex
            ) {
                found += 1
                cursor = hit.upperBound
            }
            guard found < count else { return nil }
            return "\(name): \(count) tracked, \(found) in a Sources phase"
        }.sorted()

        XCTAssertEqual(
            absent, [],
            "these tracked sources are not in the checked-in Xcode project, "
                + "so a release build on a machine without xcodegen cannot "
                + "resolve them. Run `xcodegen generate` and commit the result"
        )
    }
}
