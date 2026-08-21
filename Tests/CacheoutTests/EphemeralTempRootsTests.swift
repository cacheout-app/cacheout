import XCTest
import Darwin
@testable import Cacheout

/// Hermetic tests for the fn-6.1 temp-root declaration/resolution layer and
/// the ephemeral-temp sweep config (R2/R3/R7/R14).
///
/// House rules: the confstr(3) lookup is INJECTED for every behavioural case
/// (failure, alternative spellings, trailing slashes, `…/0`), so nothing
/// depends on the machine's real containers; the handful of live-Mac
/// integration assertions are conditionally SKIPPED when confstr cannot
/// answer (sandboxed test host, dirhelper down). UserDefaults work runs
/// against a UUID-named suite that teardown removes — zero standard-suite
/// writes.
final class EphemeralTempRootsTests: XCTestCase {

    private var base: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("EphemeralTempRootsTests-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        suiteName = "EphemeralTempRootsTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        if let base {
            try? fm.removeItem(at: base)
        }
    }

    // MARK: - Helpers

    /// Injected confstr(3): answers only for the names it was given, and
    /// records every name the resolver asked about. An ABSENT key is the
    /// production failure shape (confstr returned 0 / truncated).
    private final class ConfstrStub {
        private let paths: [Int32: String]
        private(set) var requestedNames: [Int32] = []

        init(_ paths: [Int32: String]) { self.paths = paths }

        func resolve(_ name: Int32) -> String? {
            requestedNames.append(name)
            return paths[name]
        }
    }

    @discardableResult
    private func mkdir(_ url: URL) throws -> URL {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func root(
        _ roots: [EphemeralTempRoot], labelled definition: EphemeralTempRoots.Definition
    ) -> EphemeralTempRoot? {
        roots.first { $0.label == definition.label }
    }

    private func canonicalPath(_ url: URL) -> String {
        FileSystemIdentityProvider().canonicalize(url).path
    }

    /// The spelling resolution emits for a root: canonical PARENT chain plus
    /// the leaf UNRESOLVED. For a symlink leaf this is deliberately NOT
    /// `canonicalPath` — that would resolve the link away, which is the very
    /// thing this layer refuses to do.
    private func declaredPath(_ url: URL) -> String {
        canonicalPath(url.deletingLastPathComponent())
            + "/" + url.lastPathComponent
    }

    // MARK: - R2: the closed root set

    func testDeclaredRootsAreExactlyPrivateTmpPlusTheTwoConfstrContainers() {
        XCTAssertEqual(EphemeralTempRoots.definitions.count, 3)
        XCTAssertEqual(
            EphemeralTempRoots.definitions.map(\.source),
            [
                .absolute("/private/tmp"),
                .confstrName(_CS_DARWIN_USER_CACHE_DIR),
                .confstrName(_CS_DARWIN_USER_TEMP_DIR),
            ],
            "closed set, in D7 yield/risk order: durable payload before the "
                + "OS-reaped per-user temp container"
        )
        XCTAssertFalse(
            EphemeralTempRoots.definitions.contains {
                $0.source == .confstrName(_CS_DARWIN_USER_DIR)
            },
            "_CS_DARWIN_USER_DIR (…/0) is out of scope by declaration"
        )
    }

    func testDarwinUserDirIsNeverRequestedAndNeverResolved() throws {
        let temp = try mkdir(base.appendingPathComponent("T"))
        let cache = try mkdir(base.appendingPathComponent("C"))
        let zero = try mkdir(base.appendingPathComponent("0"))
        // The stub WOULD answer for …/0 — proving the omission is the
        // resolver's, not the stub's.
        let stub = ConfstrStub([
            _CS_DARWIN_USER_TEMP_DIR: temp.path,
            _CS_DARWIN_USER_CACHE_DIR: cache.path,
            _CS_DARWIN_USER_DIR: zero.path,
        ])

        let roots = EphemeralTempRoots.resolve(confstrPath: stub.resolve(_:)).roots

        XCTAssertFalse(stub.requestedNames.contains(_CS_DARWIN_USER_DIR),
                       "…/0 is never even asked for")
        XCTAssertEqual(stub.requestedNames.sorted(),
                       [_CS_DARWIN_USER_CACHE_DIR, _CS_DARWIN_USER_TEMP_DIR].sorted())
        XCTAssertEqual(roots.count, 3)
        XCTAssertFalse(roots.contains { $0.url.path == canonicalPath(zero) })
        XCTAssertFalse(roots.contains { $0.url.lastPathComponent == "0" })
    }

    func testFailedConfstrRootIsSilentlyAbsentWithNoHardcodedSubstitute() throws {
        // Both lookups fail (confstr returned 0 / truncated).
        let stub = ConfstrStub([:])

        let roots = EphemeralTempRoots.resolve(confstrPath: stub.resolve(_:)).roots

        XCTAssertEqual(roots.map(\.url.path), ["/private/tmp"],
                       "a failed lookup drops the root — never a guessed "
                           + "/var/folders/<bucket> path")
        XCTAssertFalse(roots.contains { $0.url.path.contains("var/folders") })
        let shared = try XCTUnwrap(roots.first)
        XCTAssertEqual(shared.label, EphemeralTempRoots.sharedTemp.label)
        XCTAssertEqual(shared.writability, .worldWritable)
    }

    func testUnusableConfstrOutputIsRejectedNotRegistered() {
        for unusable in ["", "   ", "relative/T", "/", "//", "///"] {
            let stub = ConfstrStub([
                _CS_DARWIN_USER_TEMP_DIR: unusable,
                _CS_DARWIN_USER_CACHE_DIR: unusable,
            ])
            let roots = EphemeralTempRoots.resolve(confstrPath: stub.resolve(_:)).roots
            XCTAssertEqual(roots.map(\.url.path), ["/private/tmp"],
                           "unusable confstr output \"\(unusable)\" is dropped")
        }
    }

    // MARK: - R3: one canonical spelling, inode de-dupe

    func testTrailingSlashesAreStrippedBeforeCanonicalization() {
        let provider = FileSystemIdentityProvider()
        XCTAssertEqual(
            EphemeralTempRoots.canonicalRoot(
                fromRawPath: "/private/tmp/", provider: provider
            )?.path,
            "/private/tmp"
        )
        XCTAssertEqual(
            EphemeralTempRoots.canonicalRoot(
                fromRawPath: "/private/tmp///", provider: provider
            )?.path,
            "/private/tmp"
        )
        // The LEAF is never followed: `/tmp` is itself a symlink, so the
        // declared spelling keeps the link and fn-6.2's no-follow root gate
        // refuses it visibly instead of silently adopting its destination.
        // Production never feeds this input — the shared root is DECLARED as
        // `/private/tmp` (EphemeralTempRoots.sharedTemp) precisely so the
        // canonical spelling is the one that ships.
        XCTAssertEqual(
            EphemeralTempRoots.canonicalRoot(
                fromRawPath: "/tmp", provider: provider
            )?.path,
            "/tmp",
            "a symlink LEAF stays unresolved — resolving it would register "
                + "the destination as a trusted container root"
        )
        XCTAssertNil(
            EphemeralTempRoots.canonicalRoot(fromRawPath: "/", provider: provider),
            "the filesystem root can never be a temp container"
        )
    }

    func testAliasSpellingWithTrailingSlashCollapsesOntoOneCanonicalRoot() throws {
        let real = try mkdir(base.appendingPathComponent("real-container"))
        let alias = base.appendingPathComponent("alias-container")
        try fm.createSymbolicLink(at: alias, withDestinationURL: real)

        // The REAL directory is declared first here (as C) and the alias
        // second (as T, with the live trailing slash): the alias must
        // collapse onto it by INODE identity. The reversed order — alias
        // first — is the sibling cell below, and the outcome is the same,
        // because the choice is made on which spelling is a real directory
        // and never on declaration order.
        let stub = ConfstrStub([
            _CS_DARWIN_USER_CACHE_DIR: real.path,
            _CS_DARWIN_USER_TEMP_DIR: alias.path + "/",
        ])

        let resolved = EphemeralTempRoots.resolve(confstrPath: stub.resolve(_:))
        let roots = resolved.roots

        XCTAssertEqual(roots.count, 2, "two spellings of one directory ⇒ one root")
        XCTAssertEqual(roots.map(\.url.path),
                       ["/private/tmp", canonicalPath(real)])
        XCTAssertEqual(roots.last?.label, EphemeralTempRoots.userCache.label,
                       "the real-directory spelling is the one kept")
        XCTAssertNil(root(roots, labelled: EphemeralTempRoots.userTemp))
        XCTAssertEqual(resolved.issues.map(\.kind), [.symlinkRoot],
                       "the dropped alias is DISCLOSED, never silent")
        XCTAssertEqual(resolved.issues.first?.url?.path, declaredPath(alias),
                       "the disclosed spelling keeps the LINK's own name")
    }

    /// D1 (PR #459 codex r8) — the ALIAS is dropped, never the real root.
    ///
    /// The regression this pins was introduced by the round-7 commit that
    /// added canonical-key de-dupe (b4c84d8): it kept the FIRST declaration
    /// unconditionally, with no check that the kept spelling was a real
    /// directory. `C` is declared BEFORE `T`, so a symlink standing at `C`
    /// and pointing at the genuine `T` directory kept the LINK and dropped
    /// `T` outright — `T` never reached the scanner, its stale entries were
    /// never listed, and nothing anywhere named it as dropped. (Before that
    /// commit the same layout scanned `T` normally, so it was a behavioural
    /// loss, not merely a missing disclosure.)
    ///
    /// `SpaceScannerRuntime.suppressingAliasShadows` cannot repair it: the
    /// dropped root never reaches the runtime to be repaired.
    func testAliasDeclaredFirstIsDroppedAndTheRealRootSurvives() throws {
        let realTemp = try mkdir(base.appendingPathComponent("real-T"))
        // `C` is a symlink ONTO the real `T` directory, and C is declared
        // first (`EphemeralTempRoots.definitions` order).
        let aliasCache = base.appendingPathComponent("alias-C")
        try fm.createSymbolicLink(at: aliasCache, withDestinationURL: realTemp)

        let stub = ConfstrStub([
            _CS_DARWIN_USER_CACHE_DIR: aliasCache.path + "/",
            _CS_DARWIN_USER_TEMP_DIR: realTemp.path,
        ])

        let resolved = EphemeralTempRoots.resolve(confstrPath: stub.resolve(_:))

        let temp = try XCTUnwrap(
            root(resolved.roots, labelled: EphemeralTempRoots.userTemp),
            "the REAL root must survive — it is the only spelling anything "
                + "under it can be scanned or cleaned through"
        )
        XCTAssertEqual(temp.url.path, canonicalPath(realTemp))
        XCTAssertNil(
            root(resolved.roots, labelled: EphemeralTempRoots.userCache),
            "the ALIAS must be the one dropped"
        )
        XCTAssertEqual(resolved.roots.map(\.url.path),
                       ["/private/tmp", canonicalPath(realTemp)])

        let issue = try XCTUnwrap(resolved.issues.first)
        XCTAssertEqual(resolved.issues.count, 1)
        XCTAssertEqual(issue.kind, .symlinkRoot)
        XCTAssertEqual(issue.url?.path, declaredPath(aliasCache),
                       "the issue names the DROPPED spelling")
        XCTAssertTrue(
            issue.detail.contains(canonicalPath(realTemp)),
            "the disclosure names the root that covers it: \(issue.detail)"
        )
    }

    func testVarAndPrivateVarSpellingsCollapseToThePrivateCanonicalRoot() throws {
        let container = try mkdir(base.appendingPathComponent("var-alias-container"))
        try XCTSkipUnless(
            container.path.hasPrefix("/var/"),
            "temporaryDirectory not under /var — alias probe not applicable"
        )
        let privateSpelling = "/private" + container.path

        let stub = ConfstrStub([
            _CS_DARWIN_USER_CACHE_DIR: container.path,
            _CS_DARWIN_USER_TEMP_DIR: privateSpelling,
        ])

        let roots = EphemeralTempRoots.resolve(confstrPath: stub.resolve(_:)).roots

        XCTAssertEqual(roots.count, 2)
        XCTAssertEqual(roots.last?.url.path, privateSpelling,
                       "/var/… canonicalizes to /private/var/…")
        XCTAssertEqual(roots.last?.label, EphemeralTempRoots.userCache.label)
    }

    /// A symlink standing where a per-user container should be must be
    /// declared AT THE LINK, never replaced by its destination.
    ///
    /// This is the resolution half of the round-7 symlink-root defect: a
    /// leaf-resolving `realpath` here registers the link's target as a
    /// TRUSTED CONTAINER ROOT, and the container-root policy refuses only
    /// `/`, volume roots and `$HOME` itself — so an ordinary directory such
    /// as `~/Documents` is admitted, walked and deleted. Keeping the leaf is
    /// what lets fn-6.2's no-follow root gate see the link at all; the
    /// end-to-end consequence is pinned by
    /// `EphemeralTempScannerTests.testResolvedSymlinkContainerIsRefusedAndItsTargetSurvives`.
    func testSymlinkContainerLeafIsDeclaredAtTheLinkNotItsDestination() throws {
        let destination = try mkdir(base.appendingPathComponent("victim-tree"))
        let container = base.appendingPathComponent("bucket-C")
        try fm.createSymbolicLink(at: container, withDestinationURL: destination)

        let stub = ConfstrStub([_CS_DARWIN_USER_CACHE_DIR: container.path + "/"])
        let roots = EphemeralTempRoots.resolve(confstrPath: stub.resolve(_:)).roots

        let cache = try XCTUnwrap(root(roots, labelled: EphemeralTempRoots.userCache))
        XCTAssertEqual(
            cache.url.path, canonicalPath(container.deletingLastPathComponent())
                + "/bucket-C",
            "the declared root keeps the LINK's own name — the parent chain "
                + "is canonical, the leaf is not followed"
        )
        XCTAssertNotEqual(
            cache.url.path, canonicalPath(destination),
            "resolving the leaf would register the symlink's destination as "
                + "a trusted container root"
        )
        XCTAssertFalse(
            roots.map(\.url.path).contains(canonicalPath(destination)),
            "no resolved root may be the destination of a container symlink"
        )
    }

    func testResolvedRootsAreCanonicalIdempotentAndDistinct() {
        let provider = FileSystemIdentityProvider()
        let roots = EphemeralTempRoots.resolve(provider: provider).roots

        XCTAssertFalse(roots.isEmpty)
        for root in roots {
            XCTAssertTrue(root.url.path.hasPrefix("/"), root.url.path)
            XCTAssertFalse(root.url.path.hasSuffix("/"), root.url.path)
            // MEASURED, not contractual: none of the three shipped roots has
            // a symlink LEAF on a stock Mac (the link into the containers is
            // `/var` → `private/var`, an ancestor), so the leaf-preserving
            // spelling this layer emits is also fully canonical here. If this
            // ever fails, the machine has a relocated container — and the
            // scan-time root gate, not this layer, is what must refuse it.
            XCTAssertEqual(
                provider.canonicalize(root.url).path, root.url.path,
                "the exposed spelling is already canonical on this machine — "
                    + "fn-6.2 declares, stamps and derives identity from "
                    + "exactly this URL"
            )
        }
        XCTAssertEqual(Set(roots.map(\.url.path)).count, roots.count,
                       "no duplicate roots survive resolution")
    }

    // MARK: - R2: live-Mac integration (conditionally skipped)

    func testLiveConfstrResolvesPerUserContainersUnderPrivateVarFolders() throws {
        let roots = EphemeralTempRoots.resolve().roots
        XCTAssertEqual(roots.first?.url.path, "/private/tmp")

        guard let temp = root(roots, labelled: EphemeralTempRoots.userTemp),
              let cache = root(roots, labelled: EphemeralTempRoots.userCache)
        else {
            throw XCTSkip(
                "confstr(_CS_DARWIN_USER_{TEMP,CACHE}_DIR) unavailable "
                    + "(sandboxed host or dirhelper down)"
            )
        }

        XCTAssertTrue(temp.url.path.hasPrefix("/private/var/folders/"), temp.url.path)
        XCTAssertTrue(cache.url.path.hasPrefix("/private/var/folders/"), cache.url.path)
        XCTAssertEqual(temp.url.lastPathComponent, "T")
        XCTAssertEqual(cache.url.lastPathComponent, "C")
        // confstr asks dirhelper for the container and CREATES it when
        // absent — the documented side effect.
        XCTAssertTrue(fm.fileExists(atPath: temp.url.path))
        XCTAssertTrue(fm.fileExists(atPath: cache.url.path))
    }

    func testLiveConfstrAgreesWithGetconfGroundTruth() throws {
        guard let resolved = EphemeralTempRoots.confstrPath(_CS_DARWIN_USER_TEMP_DIR),
              let getconf = try getconfValue("DARWIN_USER_TEMP_DIR")
        else {
            throw XCTSkip("confstr or getconf unavailable on this host")
        }
        XCTAssertEqual(
            canonicalPath(URL(fileURLWithPath: resolved)),
            canonicalPath(URL(fileURLWithPath: getconf)),
            "the confstr wrapper returns the live per-user dir — same value "
                + "the getconf(1) twin reports"
        )
    }

    /// `getconf(1)` — the CLI twin of the confstr call, used as independent
    /// ground truth. `nil` when the tool is absent or fails.
    private func getconfValue(_ name: String) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/getconf")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: - R2/D7: per-root evidence wording (non-contractual)

    func testPerRootEvidenceMatchesTheNonContractualD7Wording() {
        XCTAssertEqual(
            EphemeralTempRoots.userCache.cleanupEvidence,
            "macOS does not routinely prune this location during normal operation",
            "EXACT D7-revised wording — never a 'never prunes' absolute"
        )
        XCTAssertFalse(
            EphemeralTempRoots.userCache.cleanupEvidence.lowercased()
                .contains("never"),
            "an absolute claim would contradict the safe-boot removal"
        )

        let tempEvidence = EphemeralTempRoots.userTemp.cleanupEvidence
        XCTAssertEqual(
            tempEvidence,
            "macOS may reap older untouched files here; this age gate is more conservative"
        )
        for banned in ["dirhelper", "3-day", "3 day", "three-day", "three day",
                       "atime", "access time", "daily", "03:35"] {
            XCTAssertFalse(
                tempEvidence.lowercased().contains(banned),
                "shipped copy must carry no OS-mechanics claim (\"\(banned)\") — "
                    + "Apple disclaims those values as non-API"
            )
        }
        XCTAssertFalse(tempEvidence.contains(where: \.isNumber),
                       "no numeric behavioral claim in shipped copy")

        XCTAssertEqual(EphemeralTempRoots.sharedTemp.cleanupEvidence,
                       "no periodic reaper on modern macOS")
    }

    func testResolvedRootsCarryTheirDeclaredEvidenceVerbatim() throws {
        let temp = try mkdir(base.appendingPathComponent("T"))
        let cache = try mkdir(base.appendingPathComponent("C"))
        let stub = ConfstrStub([
            _CS_DARWIN_USER_TEMP_DIR: temp.path,
            _CS_DARWIN_USER_CACHE_DIR: cache.path,
        ])

        let roots = EphemeralTempRoots.resolve(confstrPath: stub.resolve(_:)).roots

        XCTAssertEqual(roots.map(\.cleanupEvidence), [
            EphemeralTempRoots.sharedTempEvidence,
            EphemeralTempRoots.userCacheEvidence,
            EphemeralTempRoots.userTempEvidence,
        ])
    }

    // MARK: - R14: declared writability classes

    func testWritabilityClassesAreDeclaredPerRoot() throws {
        let temp = try mkdir(base.appendingPathComponent("T"))
        let cache = try mkdir(base.appendingPathComponent("C"))
        let stub = ConfstrStub([
            _CS_DARWIN_USER_TEMP_DIR: temp.path,
            _CS_DARWIN_USER_CACHE_DIR: cache.path,
        ])

        let roots = EphemeralTempRoots.resolve(confstrPath: stub.resolve(_:)).roots

        let shared = try XCTUnwrap(root(roots, labelled: EphemeralTempRoots.sharedTemp))
        XCTAssertEqual(shared.url.path, "/private/tmp")
        XCTAssertEqual(shared.writability, .worldWritable,
                       "sticky, multi-writer ⇒ fn-6.2's D12 ownership gate applies")
        XCTAssertEqual(
            try XCTUnwrap(root(roots, labelled: EphemeralTempRoots.userTemp)).writability,
            .perUser
        )
        XCTAssertEqual(
            try XCTUnwrap(root(roots, labelled: EphemeralTempRoots.userCache)).writability,
            .perUser,
            "0700 ⇒ the ownership gate is vacuous here"
        )
        // Declared, never probed: the fixture dirs standing in for T/C are
        // ordinary 0755 test dirs, and the class is unaffected by their mode.
        XCTAssertEqual(EphemeralTempRoots.definitions.map(\.writability),
                       [.worldWritable, .perUser, .perUser])
    }

    // MARK: - R7: thresholds config

    func testConfigKeysAndDefaultsAreTenMBSevenDaysDecimal() {
        XCTAssertEqual(EphemeralTempSweepConfig.minSizeMBKey,
                       "cacheout.ephemeralTmp.minSizeMB")
        XCTAssertEqual(EphemeralTempSweepConfig.ageDaysKey,
                       "cacheout.ephemeralTmp.ageDays")
        XCTAssertEqual(EphemeralTempSweepConfig.defaultMinSizeMB, 10)
        XCTAssertEqual(EphemeralTempSweepConfig.defaultAgeDays, 7)
        XCTAssertEqual(
            EphemeralTempSweepConfig.defaultThresholds.sizeFloorBytes,
            10_000_000, "decimal MB — base-10, matching display convention"
        )
        XCTAssertEqual(EphemeralTempSweepConfig.defaultThresholds.staleAge,
                       7 * 86_400)
    }

    func testConfigConversionsAreOverflowCheckedNeverTrapping() {
        XCTAssertEqual(EphemeralTempSweepConfig.sizeFloorBytes(fromMB: 1),
                       1_000_000, "boundary-valid: 1 MB")
        XCTAssertEqual(EphemeralTempSweepConfig.staleAge(fromDays: 1),
                       86_400, "boundary-valid: 1 day")
        XCTAssertNil(EphemeralTempSweepConfig.sizeFloorBytes(fromMB: 0))
        XCTAssertNil(EphemeralTempSweepConfig.sizeFloorBytes(fromMB: -10))
        XCTAssertNil(EphemeralTempSweepConfig.sizeFloorBytes(fromMB: .max),
                     "overflow is nil, never a trap")
        XCTAssertNil(EphemeralTempSweepConfig.staleAge(fromDays: 0))
        XCTAssertNil(EphemeralTempSweepConfig.staleAge(fromDays: -1))
        XCTAssertNil(EphemeralTempSweepConfig.staleAge(fromDays: .max))
    }

    func testEmptyDefaultsYieldTheDefaultsAndWriteNothing() {
        let resolved = EphemeralTempSweepConfig.resolvedThresholds(defaults: defaults)

        XCTAssertEqual(resolved, EphemeralTempSweepConfig.defaultThresholds)
        XCTAssertNil(defaults.object(forKey: EphemeralTempSweepConfig.minSizeMBKey))
        XCTAssertNil(defaults.object(forKey: EphemeralTempSweepConfig.ageDaysKey))
    }

    func testPersistedValuesHonoredAndInvalidOnesFallBackWithoutRewrite() {
        defaults.set(25, forKey: EphemeralTempSweepConfig.minSizeMBKey)
        defaults.set(3, forKey: EphemeralTempSweepConfig.ageDaysKey)
        var resolved = EphemeralTempSweepConfig.resolvedThresholds(defaults: defaults)
        XCTAssertEqual(resolved.sizeFloorBytes, 25_000_000)
        XCTAssertEqual(resolved.staleAge, 3 * 86_400)

        // A numeric STRING persists fine (the template's accepted shape).
        defaults.set("40", forKey: EphemeralTempSweepConfig.minSizeMBKey)
        resolved = EphemeralTempSweepConfig.resolvedThresholds(defaults: defaults)
        XCTAssertEqual(resolved.sizeFloorBytes, 40_000_000)

        // `true`/`false` bridge to NSNumber(1)/NSNumber(0): a Bool is NOT a
        // positive-integer threshold, and `true` must never become a 1 MB /
        // 1 day gate (the CFBoolean guard).
        let invalids: [Any] = [0, -5, "garbage", "", 50.5, Int64.max, true, false]
        for invalid in invalids {
            defaults.set(invalid, forKey: EphemeralTempSweepConfig.minSizeMBKey)
            defaults.set(invalid, forKey: EphemeralTempSweepConfig.ageDaysKey)
            resolved = EphemeralTempSweepConfig.resolvedThresholds(defaults: defaults)
            XCTAssertEqual(
                resolved, EphemeralTempSweepConfig.defaultThresholds,
                "invalid persisted value \(invalid) falls back to BOTH defaults"
            )
            XCTAssertEqual(
                defaults.object(forKey: EphemeralTempSweepConfig.minSizeMBKey)
                    as? NSObject,
                invalid as? NSObject,
                "never rewritten — the stored value survives unchanged"
            )
            XCTAssertEqual(
                defaults.object(forKey: EphemeralTempSweepConfig.ageDaysKey)
                    as? NSObject,
                invalid as? NSObject
            )
        }
    }

    func testEachKnobResolvesIndependently() {
        defaults.set(true, forKey: EphemeralTempSweepConfig.minSizeMBKey)
        defaults.set(30, forKey: EphemeralTempSweepConfig.ageDaysKey)

        let resolved = EphemeralTempSweepConfig.resolvedThresholds(defaults: defaults)

        XCTAssertEqual(resolved.sizeFloorBytes,
                       EphemeralTempSweepConfig.defaultThresholds.sizeFloorBytes,
                       "the boolean half falls back")
        XCTAssertEqual(resolved.staleAge, 30 * 86_400,
                       "the valid half is still honored")
    }

    func testCLIOverrideWinsForInvocationOnlyAndIsNeverPersisted() {
        defaults.set(25, forKey: EphemeralTempSweepConfig.minSizeMBKey)

        let resolved = EphemeralTempSweepConfig.resolvedThresholds(
            defaults: defaults, minSizeMBOverride: 5, ageDaysOverride: 2
        )

        XCTAssertEqual(resolved.sizeFloorBytes, 5_000_000,
                       "the invocation-scoped override beats the persisted value")
        XCTAssertEqual(resolved.staleAge, 2 * 86_400)
        XCTAssertEqual(defaults.integer(forKey: EphemeralTempSweepConfig.minSizeMBKey),
                       25, "the override is never persisted")
        XCTAssertNil(defaults.object(forKey: EphemeralTempSweepConfig.ageDaysKey),
                     "an override never creates a persisted value either")
    }

    /// The config is a deliberate CLONE of `OrphanedCachesSweepConfig`; this
    /// pins the clone's validity verdicts to the template's, input by input,
    /// so the two can never drift apart silently.
    func testPersistedGuardMatchesTheOrphanedCachesTemplateVerdicts() {
        let inputs: [Any?] = [
            nil, 0, 1, -5, 7, 10, "25", "0", "-3", "garbage", "",
            50.5, 2.0, Int64.max, Double.nan, Double.infinity, true, false,
            NSNumber(value: 3), NSNumber(value: true), NSNumber(value: 1.5),
        ]
        for input in inputs {
            XCTAssertEqual(
                EphemeralTempSweepConfig.persistedPositiveInteger(input),
                OrphanedCachesSweepConfig.persistedPositiveInteger(input),
                "clone drift on input \(String(describing: input))"
            )
        }
        XCTAssertNil(EphemeralTempSweepConfig.persistedPositiveInteger(true),
                     "CFBoolean guard: true never becomes 1")
        XCTAssertEqual(EphemeralTempSweepConfig.persistedPositiveInteger(7), 7)
    }
}
