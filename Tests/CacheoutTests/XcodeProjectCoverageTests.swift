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
/// MUTATION: delete any file's entry from the project and this reds, naming
/// it. Regenerating with `xcodegen generate` is the fix.
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

        let absent = paths.filter { path in
            guard let name = path.split(separator: "/").last else { return false }
            return !project.contains(String(name))
        }
        XCTAssertEqual(
            absent, [],
            "these tracked sources are not in the checked-in Xcode project, "
                + "so a release build on a machine without xcodegen cannot "
                + "resolve them. Run `xcodegen generate` and commit the result"
        )
    }
}
