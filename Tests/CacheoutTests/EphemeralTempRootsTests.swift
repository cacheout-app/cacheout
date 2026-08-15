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

        let roots = EphemeralTempRoots.resolve(confstrPath: stub.resolve(_:))

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

        let roots = EphemeralTempRoots.resolve(confstrPath: stub.resolve(_:))

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
            let roots = EphemeralTempRoots.resolve(confstrPath: stub.resolve(_:))
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
        XCTAssertEqual(
            EphemeralTempRoots.canonicalRoot(
                fromRawPath: "/tmp", provider: provider
            )?.path,
            "/private/tmp",
            "/tmp is a symlink to private/tmp — the canonical spelling wins"
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

        // C is declared before T: the alias spelling (with the live trailing
        // slash) must collapse onto the already-kept root by INODE identity.
        let stub = ConfstrStub([
            _CS_DARWIN_USER_CACHE_DIR: real.path,
            _CS_DARWIN_USER_TEMP_DIR: alias.path + "/",
        ])

        let roots = EphemeralTempRoots.resolve(confstrPath: stub.resolve(_:))

        XCTAssertEqual(roots.count, 2, "two spellings of one directory ⇒ one root")
        XCTAssertEqual(roots.map(\.url.path),
                       ["/private/tmp", canonicalPath(real)])
        XCTAssertEqual(roots.last?.label, EphemeralTempRoots.userCache.label,
                       "first declaration wins the de-dupe")
        XCTAssertNil(root(roots, labelled: EphemeralTempRoots.userTemp))
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

        let roots = EphemeralTempRoots.resolve(confstrPath: stub.resolve(_:))

        XCTAssertEqual(roots.count, 2)
        XCTAssertEqual(roots.last?.url.path, privateSpelling,
                       "/var/… canonicalizes to /private/var/…")
        XCTAssertEqual(roots.last?.label, EphemeralTempRoots.userCache.label)
    }

    func testResolvedRootsAreCanonicalIdempotentAndDistinct() {
        let provider = FileSystemIdentityProvider()
        let roots = EphemeralTempRoots.resolve(provider: provider)

        XCTAssertFalse(roots.isEmpty)
        for root in roots {
            XCTAssertTrue(root.url.path.hasPrefix("/"), root.url.path)
            XCTAssertFalse(root.url.path.hasSuffix("/"), root.url.path)
            XCTAssertEqual(
                provider.canonicalize(root.url).path, root.url.path,
                "the exposed spelling is already canonical — fn-6.2 declares, "
                    + "stamps and derives identity from exactly this URL"
            )
        }
        XCTAssertEqual(Set(roots.map(\.url.path)).count, roots.count,
                       "no duplicate roots survive resolution")
    }

    // MARK: - R2: live-Mac integration (conditionally skipped)

    func testLiveConfstrResolvesPerUserContainersUnderPrivateVarFolders() throws {
        let roots = EphemeralTempRoots.resolve()
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

        let roots = EphemeralTempRoots.resolve(confstrPath: stub.resolve(_:))

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

        let roots = EphemeralTempRoots.resolve(confstrPath: stub.resolve(_:))

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
