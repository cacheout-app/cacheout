/// # DevTreeWalkMeasurementTests — fn-4.18's measurement, kept as the record
///
/// Codex (PR #460, P2) claimed the two dev-root scanners' separate
/// `ProjectTreeWalker` runs cost "nearly double filesystem I/O and latency".
/// The task's first acceptance criterion was MEASURE FIRST, and the
/// measurement CORRECTS the claim, so it is kept executable rather than
/// summarized:
///
/// On an artifact-bearing tree (two populated node_modules, one populated
/// Rust target, one repository with a worktree — 5772 entries):
///
///   build WALK      249 probes   0.004 s   (its consumer PRUNES matched dirs)
///   build SCAN     5772 probes   0.230 s   (walk 249 + sizing census 5523)
///   git   SCAN     5772 probes   0.212 s   (its walk prunes NOTHING — by
///                                           design: nested repos are quarry)
///   union WALK     5772 probes   0.132 s   (zero consumers = fused reach)
///
/// The two walks are wildly ASYMMETRIC: the duplicated enumeration is their
/// INTERSECTION, which is the build walk — 249 of the session's 11544 entry
/// probes (2.2%). A fused walk must carry the git walk's unpruned reach and
/// the build scanner still pays its sizing census either way, so the fan-in
/// saves ~2% of entry probes on the tree class these scanners exist for.
/// The claim's true half is the tree with NO artifacts and NO repository:
/// there both walks enumerate everything (496 probes each on an 8-project
/// tree) and fusing halves them — of a cost measured in single-digit
/// milliseconds.
///
/// The cells below PIN the two facts the correction rests on (the pruned
/// build walk is strictly smaller than the git walk; the git walk equals
/// the zero-consumer union reach) and print fresh figures for the record.
/// See the fn-4.18 disposition note at `GitWorktreeScanner.scan`'s walk
/// step for why the fan-in was recorded rather than built.

import XCTest
@testable import Cacheout

private final class ProbeCountingProvider: FileSystemIdentityProvider {
    private let lock = NSLock()
    private var count = 0

    var probes: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func reset() {
        lock.lock()
        count = 0
        lock.unlock()
    }

    override func probeKind(
        inDirectory parent: Int32, named name: String, logical url: URL
    ) -> DescriptorKindProbe {
        lock.lock()
        count += 1
        lock.unlock()
        return super.probeKind(inDirectory: parent, named: name, logical: url)
    }
}

final class DevTreeWalkMeasurementTests: XCTestCase {

    private var base: URL!
    private var home: URL!
    private var dev: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("DevTreeWalkMeasurement-\(UUID().uuidString)")
        home = base.appendingPathComponent("home")
        dev = base.appendingPathComponent("dev")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: dev, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let base { try? fm.removeItem(at: base) }
    }

    private func file(_ url: URL, bytes: Int = 512) throws {
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    private func makeNodeProject(named name: String, packages: Int) throws {
        let project = dev.appendingPathComponent(name)
        let src = project.appendingPathComponent("src")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try file(project.appendingPathComponent("package.json"))
        for i in 0..<40 { try file(src.appendingPathComponent("mod\(i).ts")) }
        let nm = project.appendingPathComponent("node_modules")
        for p in 0..<packages {
            let pkg = nm.appendingPathComponent("pkg-\(p)")
            let lib = pkg.appendingPathComponent("lib")
            let dist = pkg.appendingPathComponent("dist")
            try fm.createDirectory(at: lib, withIntermediateDirectories: true)
            try fm.createDirectory(at: dist, withIntermediateDirectories: true)
            try file(pkg.appendingPathComponent("package.json"))
            for i in 0..<5 { try file(lib.appendingPathComponent("f\(i).js")) }
            for i in 0..<3 { try file(dist.appendingPathComponent("d\(i).js")) }
        }
    }

    private func makeRustProject(named name: String) throws {
        let project = dev.appendingPathComponent(name)
        let src = project.appendingPathComponent("src")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try file(project.appendingPathComponent("Cargo.toml"))
        for i in 0..<30 { try file(src.appendingPathComponent("m\(i).rs")) }
        let debug = project.appendingPathComponent("target/debug")
        let deps = debug.appendingPathComponent("deps")
        try fm.createDirectory(at: deps, withIntermediateDirectories: true)
        for i in 0..<400 { try file(deps.appendingPathComponent("lib\(i).rlib")) }
        for b in 0..<80 {
            let build = debug.appendingPathComponent("build/unit-\(b)")
            try fm.createDirectory(at: build, withIntermediateDirectories: true)
            for i in 0..<3 { try file(build.appendingPathComponent("out\(i)")) }
        }
    }

    func testMeasureDevRootDoubleWalk() async throws {
        // --- The realistic tree: two JS projects with populated
        // node_modules, one Rust project with a populated target, a plain
        // tools tree, and one real git repository with a linked worktree.
        try makeNodeProject(named: "webapp", packages: 220)
        try makeNodeProject(named: "api", packages: 180)
        try makeRustProject(named: "svc")
        let tools = dev.appendingPathComponent("tools/scripts")
        try fm.createDirectory(at: tools, withIntermediateDirectories: true)
        for i in 0..<120 { try file(tools.appendingPathComponent("t\(i).sh")) }
        let repo = dev.appendingPathComponent("repo")
        try GitFixture.makeRepository(at: repo, home: home)
        try fm.createDirectory(
            at: dev.appendingPathComponent("wts"), withIntermediateDirectories: true
        )
        XCTAssertEqual(
            try GitFixture.git(
                ["-C", repo.path, "worktree", "add",
                 dev.appendingPathComponent("wts/feature").path, "-b", "feature"],
                home: home
            ).status, 0
        )

        let provider = ProbeCountingProvider()
        let devRoots = DevRootsResolution(keptRoots: [dev], issues: [])
        let context = ScanContext(trigger: .userInitiated)

        // --- BuildArtifactsScanner: its consumer PRUNES matched artifact
        // directories, so its walk never enters node_modules/target interiors.
        let build = BuildArtifactsScanner(
            home: home, devRoots: devRoots, provider: provider
        )
        provider.reset()
        var start = Date()
        let buildOutcome = await build.scan(context: context)
        let buildWall = Date().timeIntervalSince(start)
        let buildProbes = provider.probes

        // --- GitWorktreeScanner: its consumer prunes NOTHING (nested
        // repositories are its quarry), so its walk enumerates everything.
        let git = GitWorktreeScanner(
            home: home, devRoots: devRoots,
            runner: GitCommandRunner(environment: GitFixture.environment(home: home)),
            provider: provider
        )
        provider.reset()
        start = Date()
        let gitOutcome = await git.scan(context: context)
        let gitWall = Date().timeIntervalSince(start)
        let gitProbes = provider.probes

        // --- The walker alone over the same roots, zero consumers =
        // nothing pruned = the union reach a fused walk would need.
        let walker = ProjectTreeWalker(
            home: home,
            pathGuard: PathGuard(home: home, containerRoots: [dev], provider: provider),
            provider: provider
        )
        provider.reset()
        start = Date()
        _ = walker.walk(
            roots: [dev], maxDepth: ProjectTreeWalker.defaultMaxDepth,
            includeProtectedRoots: true, consumers: []
        )
        let unionWall = Date().timeIntervalSince(start)
        let unionProbes = provider.probes

        // --- The walker with a prune verdict mimicking the build matcher:
        // what the BUILD WALK alone enumerates (its scan total above also
        // carries the sizing/valuables phases).
        provider.reset()
        start = Date()
        _ = walker.walk(
            roots: [dev], maxDepth: ProjectTreeWalker.defaultMaxDepth,
            includeProtectedRoots: true,
            consumers: [{ event in
                Set(event.entries.filter {
                    $0.kind == .directory
                        && ($0.name == "node_modules" || $0.name == "target")
                }.map(\.name))
            }]
        )
        let prunedWall = Date().timeIntervalSince(start)
        let prunedProbes = provider.probes
        print("MEASURED-FN4-18 pruned walk (build-shaped): probes=\(prunedProbes) wall=\(String(format: "%.3f", prunedWall))s")

        print("MEASURED-FN4-18 build scan: probes=\(buildProbes) wall=\(String(format: "%.3f", buildWall))s items=\(buildOutcome.items.count) errors=\(buildOutcome.errors.count)")
        print("MEASURED-FN4-18 git scan:   probes=\(gitProbes) wall=\(String(format: "%.3f", gitWall))s items=\(gitOutcome.items.count) errors=\(gitOutcome.errors.count)")
        print("MEASURED-FN4-18 union walk: probes=\(unionProbes) wall=\(String(format: "%.3f", unionWall))s")
        // The fused design replaces the two WALKS with one union-reach walk;
        // the build sizing census is paid either way. So the true saving is
        // the walks' intersection — the pruned build walk.
        print("MEASURED-FN4-18 today total probes=\(buildProbes + gitProbes); fan-in saving=\(prunedProbes) (\(String(format: "%.1f", 100.0 * Double(prunedProbes) / Double(buildProbes + gitProbes)))%)")

        // --- Codex's cited worst case: a dev root with NO artifacts and NO
        // repository — both walks enumerate everything and find nothing.
        let plain = base.appendingPathComponent("plain-dev")
        for p in 0..<8 {
            let src = plain.appendingPathComponent("proj-\(p)/src")
            try fm.createDirectory(at: src, withIntermediateDirectories: true)
            for i in 0..<60 { try file(src.appendingPathComponent("s\(i).c")) }
        }
        let plainRoots = DevRootsResolution(keptRoots: [plain], issues: [])
        let plainBuild = BuildArtifactsScanner(
            home: home, devRoots: plainRoots, provider: provider
        )
        provider.reset()
        start = Date()
        _ = await plainBuild.scan(context: context)
        let plainBuildWall = Date().timeIntervalSince(start)
        let plainBuildProbes = provider.probes
        let plainGit = GitWorktreeScanner(
            home: home, devRoots: plainRoots,
            runner: GitCommandRunner(environment: GitFixture.environment(home: home)),
            provider: provider
        )
        provider.reset()
        start = Date()
        _ = await plainGit.scan(context: context)
        let plainGitWall = Date().timeIntervalSince(start)
        let plainGitProbes = provider.probes
        print("MEASURED-FN4-18 plain tree build scan: probes=\(plainBuildProbes) wall=\(String(format: "%.3f", plainBuildWall))s")
        print("MEASURED-FN4-18 plain tree git scan:   probes=\(plainGitProbes) wall=\(String(format: "%.3f", plainGitWall))s")

        // THE TWO FACTS THE CORRECTION RESTS ON, pinned:
        // 1. The walks are asymmetric — the build walk prunes matched
        //    artifact directories, the git walk deliberately does not, so
        //    the duplicated enumeration is only their intersection (the
        //    build walk).
        XCTAssertLessThan(
            prunedProbes, gitProbes,
            "the build-shaped walk must enumerate strictly less than the "
                + "git walk on an artifact-bearing tree"
        )
        // 2. The git walk IS the union reach a fused walk would need — a
        //    fan-in cannot shrink it.
        XCTAssertEqual(
            gitProbes, unionProbes,
            "the git scan's walk prunes nothing, so its reach equals the "
                + "zero-consumer union walk"
        )
        // And the claim's true half: with no artifacts and no repository
        // the two walks really do double each other.
        XCTAssertEqual(plainBuildProbes, plainGitProbes)
    }
}
