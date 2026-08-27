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

    // MARK: - R3: one spelling (parent-canonical, leaf unresolved), inode
    // de-dupe and alias suppression

    func testTrailingSlashesAreStrippedBeforeCanonicalization() {
        let provider = FileSystemIdentityProvider()
        XCTAssertEqual(
            EphemeralTempRoots.resolvedRoot(
                fromRawPath: "/private/tmp/", provider: provider
            )?.path,
            "/private/tmp"
        )
        XCTAssertEqual(
            EphemeralTempRoots.resolvedRoot(
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
            EphemeralTempRoots.resolvedRoot(
                fromRawPath: "/tmp", provider: provider
            )?.path,
            "/tmp",
            "a symlink LEAF stays unresolved — resolving it would register "
                + "the destination as a trusted container root"
        )
        XCTAssertNil(
            EphemeralTempRoots.resolvedRoot(fromRawPath: "/", provider: provider),
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

    /// The exposed spelling is parent-canonical with an UNRESOLVED leaf. On a
    /// stock Mac that ALSO happens to be fully canonical, which this cell
    /// measures rather than claims — see the note inside.
    func testResolvedRootsAreAbsoluteDistinctAndFullyCanonicalOnThisMachine() {
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

    // MARK: - PR #459 codex r12: nothing a symlink leaf points at is contacted

    /// A provider that FAILS THE TEST on contact, under two rules.
    ///
    /// Every filesystem access `EphemeralTempRoots.resolve` performs goes
    /// through one of these overrides, so a call recorded here IS the syscall.
    ///
    /// - `offLimits`: no call may name this subtree. Used for a destination
    ///   nothing declared — the attacker-chosen directory that must stay
    ///   untouched.
    /// - `neverResolved`: `realpath(3)` must never be called on these
    ///   spellings. Used for a symlink root whose destination IS a declared
    ///   root, where naming the destination is legitimate but resolving the
    ///   LINK to get there is the defect.
    ///
    /// `realPath`/`canonicalize` are checked at both ends: `realpath(3)` can
    /// only RETURN a path under a subtree by having walked into it.
    /// `symlinkTarget`'s output is deliberately exempt — `readlink(2)` reads
    /// the link's own data block and returns a name it never visits, which is
    /// the entire reason this file uses it.
    private final class ContactForbiddingProvider: FileSystemIdentityProvider {
        private let offLimits: String?
        private let neverResolved: [String]
        private let fail: (String) -> Void

        init(offLimits: String?, neverResolved: [String],
             fail: @escaping (String) -> Void) {
            self.offLimits = offLimits
            self.neverResolved = neverResolved
            self.fail = fail
        }

        private func check(_ path: String, _ what: String) {
            guard let offLimits,
                  path == offLimits || path.hasPrefix(offLimits + "/")
            else { return }
            fail("\(what) named the off-limits destination: \(path)")
        }

        private func checkResolutionSubject(_ path: String, _ what: String) {
            guard neverResolved.contains(path) else { return }
            fail("\(what) resolved a non-directory leaf: \(path)")
        }

        override func realPath(of path: String) -> String? {
            check(path, "realPath(of:) input")
            checkResolutionSubject(path, "realPath(of:)")
            let out = super.realPath(of: path)
            if let out { check(out, "realPath(of:) output") }
            return out
        }

        override func canonicalize(_ url: URL) -> URL {
            check(url.path, "canonicalize input")
            checkResolutionSubject(url.path, "canonicalize")
            let out = super.canonicalize(url)
            check(out.path, "canonicalize output")
            return out
        }

        override func probeKind(of url: URL) -> KindProbe {
            check(url.path, "probeKind input")
            return super.probeKind(of: url)
        }

        override func identity(of url: URL) -> Identity? {
            check(url.path, "identity input")
            return super.identity(of: url)
        }

        override func ownerProbe(of url: URL) -> OwnerProbe {
            check(url.path, "ownerProbe input")
            return super.ownerProbe(of: url)
        }

        override func canEnumerateDirectory(_ url: URL) -> Bool {
            check(url.path, "canEnumerateDirectory input")
            return super.canEnumerateDirectory(url)
        }

        override func symlinkTarget(of url: URL) -> String? {
            check(url.path, "symlinkTarget input")
            return super.symlinkTarget(of: url)
        }
    }

    /// The r12 finding: a leaf-following `realpath(3)` ran at REGISTRATION.
    ///
    /// `C` and `T` live in a user-owned bucket directory, so a same-UID
    /// process can replace either with a symlink to any destination it
    /// chooses. Resolution runs inside `SpaceScannerRuntime.production()` —
    /// app construction, on the GUI's main thread — so a destination that
    /// blocks blocks the app, and a destination the app has no business
    /// reaching is reached before any trigger gate exists.
    ///
    /// Both arms are driven, because they take different paths through the
    /// alias check: an alias the resolution CAN place (dropped, disclosed)
    /// and one it cannot (kept verbatim for the scan-time gate).
    func testResolutionNeverContactsWhatADeclaredSymlinkPointsAt() throws {
        for coversARealRoot in [true, false] {
            let destination = try mkdir(
                base.appendingPathComponent("destination-\(coversARealRoot)")
            )
            let aliasCache = base
                .appendingPathComponent("alias-C-\(coversARealRoot)")
            try fm.createSymbolicLink(at: aliasCache, withDestinationURL: destination)

            let stub = ConfstrStub(
                coversARealRoot
                    ? [
                        _CS_DARWIN_USER_CACHE_DIR: aliasCache.path,
                        // The destination declared separately, as a real
                        // directory: the alias is droppable.
                        _CS_DARWIN_USER_TEMP_DIR: destination.path,
                    ]
                    : [_CS_DARWIN_USER_CACHE_DIR: aliasCache.path]
            )
            let provider = ContactForbiddingProvider(
                // When the destination is ALSO a declared root, naming it is
                // legitimate — what must not happen is resolving the link to
                // reach it.
                offLimits: coversARealRoot ? nil : canonicalPath(destination),
                neverResolved: [declaredPath(aliasCache)],
                fail: { XCTFail("\($0) (covers a real root: \(coversARealRoot))") }
            )

            let resolved = EphemeralTempRoots.resolve(
                provider: provider, confstrPath: stub.resolve(_:)
            )

            // The behaviour is unchanged by the no-contact rule — asserted
            // here so a mutation that satisfies the rule by doing nothing at
            // all cannot pass this cell.
            if coversARealRoot {
                XCTAssertEqual(resolved.issues.map(\.kind), [.symlinkRoot])
                XCTAssertNil(root(resolved.roots, labelled: EphemeralTempRoots.userCache),
                             "the alias is still dropped")
            } else {
                XCTAssertEqual(resolved.issues, [])
                XCTAssertEqual(
                    root(resolved.roots, labelled: EphemeralTempRoots.userCache)?
                        .url.path,
                    declaredPath(aliasCache),
                    "an alias covered by nothing is still kept AT THE LINK"
                )
            }
        }
    }

    /// The residual the name comparison leaves, measured rather than claimed.
    ///
    /// The link is written through a THIRD spelling of the real root —
    /// neither the parent-canonical one nor the raw source one — by pointing
    /// it through a sibling symlinked directory. The inode key this replaced
    /// would have collapsed it; a name compare cannot. What matters is the
    /// DIRECTION of the miss: both roots survive, so the real one is scanned
    /// exactly as before, and the alias carries no registration issue because
    /// fn-6.2's no-follow root gate is what classifies it at scan time.
    func testAliasWrittenThroughAThirdSpellingKeepsBothRootsRatherThanGuessing()
        throws
    {
        let realTemp = try mkdir(base.appendingPathComponent("real-T"))
        // A third spelling of `real-T`: through a symlinked PARENT.
        let parentAlias = base.appendingPathComponent("bucket-alias")
        try fm.createSymbolicLink(at: parentAlias, withDestinationURL: base)
        let aliasCache = base.appendingPathComponent("alias-C")
        try fm.createSymbolicLink(
            at: aliasCache,
            withDestinationURL: parentAlias.appendingPathComponent("real-T")
        )

        let stub = ConfstrStub([
            _CS_DARWIN_USER_CACHE_DIR: aliasCache.path,
            _CS_DARWIN_USER_TEMP_DIR: realTemp.path,
        ])

        let resolved = EphemeralTempRoots.resolve(confstrPath: stub.resolve(_:))

        XCTAssertEqual(
            root(resolved.roots, labelled: EphemeralTempRoots.userTemp)?.url.path,
            canonicalPath(realTemp),
            "the REAL root survives — that is the half that must never be lost"
        )
        XCTAssertEqual(
            root(resolved.roots, labelled: EphemeralTempRoots.userCache)?.url.path,
            declaredPath(aliasCache),
            "the unrecognised alias is KEPT at the link, not silently dropped"
        )
        XCTAssertEqual(resolved.issues, [],
                       "no registration issue — the scan-time root gate is "
                           + "what classifies a kept symlink root")
    }

    /// The name arithmetic on its own: relative and `..` targets are folded
    /// in the STRING, and nothing that cannot become a usable absolute path
    /// is ever offered for comparison.
    func testLexicalTargetPathFoldsWithoutTouchingTheFilesystem() {
        let link = URL(fileURLWithPath: "/private/var/folders/mq/bucket/C")
        func fold(_ content: String) -> String? {
            EphemeralTempRoots.lexicalTargetPath(ofLink: link, content: content)
        }
        XCTAssertEqual(fold("T"), "/private/var/folders/mq/bucket/T",
                       "a relative target joins the LINK's own directory")
        XCTAssertEqual(fold("./T"), "/private/var/folders/mq/bucket/T")
        XCTAssertEqual(fold("../other/T"), "/private/var/folders/mq/other/T")
        XCTAssertEqual(fold("/var/folders/mq/bucket/T"),
                       "/var/folders/mq/bucket/T",
                       "an absolute target is folded but NEVER canonicalized "
                           + "— /var is left alone")
        XCTAssertEqual(fold("/private/tmp/"), "/private/tmp",
                       "a trailing slash is not a spelling difference")
        XCTAssertNil(fold(""), "empty content names nothing")
        XCTAssertNil(fold("/"), "the filesystem root is never a temp root")
        XCTAssertNil(fold("/.."), "a target that walks off the root is refused")
    }

    // MARK: - PR #459 codex r15: the construction-time mount preflight

    /// FAILS THE TEST on any call naming the over-mounted root or anything
    /// below it, and answers `mountPointPaths()` from an injected table.
    ///
    /// Every filesystem access `EphemeralTempRoots.resolve` and
    /// `SpaceScannerRuntime.production` make on a declared root goes through
    /// one of these overrides, so a call recorded here IS the syscall that
    /// would block. (`deviceID`, `kind` and `sameLocation` are final and
    /// derive from `identity`/`probeKind`/`canonicalize`, so the overrides
    /// cover them too.)
    private final class MountedRootForbiddingProvider:
        FileSystemIdentityProvider, @unchecked Sendable {
        var mountedRootPath = ""
        /// The real table as well, when a real volume backs the fixture.
        var alsoRealTable = false
        private let fail: (String) -> Void

        init(fail: @escaping (String) -> Void) {
            self.fail = fail
            super.init()
        }

        override func mountPointPaths() -> [String] {
            alsoRealTable
                ? super.mountPointPaths()
                : [mountedRootPath]
        }

        private func forbid(_ method: String, _ path: String) {
            guard !mountedRootPath.isEmpty,
                  path == mountedRootPath
                    || path.hasPrefix(mountedRootPath + "/")
            else { return }
            fail("\(method) made first contact with the over-mounted root: "
                    + path)
        }

        override func realPath(of path: String) -> String? {
            forbid("realPath", path)
            let out = super.realPath(of: path)
            if let out { forbid("realPath output", out) }
            return out
        }
        override func canonicalize(_ url: URL) -> URL {
            forbid("canonicalize", url.path)
            return super.canonicalize(url)
        }
        override func probeKind(of url: URL) -> KindProbe {
            forbid("probeKind", url.path)
            return super.probeKind(of: url)
        }
        override func identity(of url: URL) -> Identity? {
            forbid("identity", url.path)
            return super.identity(of: url)
        }
        override func symlinkTarget(of url: URL) -> String? {
            forbid("symlinkTarget", url.path)
            return super.symlinkTarget(of: url)
        }
        override func isMountPoint(_ url: URL) -> Bool {
            forbid("isMountPoint", url.path)
            return super.isMountPoint(url)
        }
        override func canEnumerateDirectory(_ url: URL) -> Bool {
            forbid("canEnumerateDirectory", url.path)
            return super.canEnumerateDirectory(url)
        }
        override func ownerProbe(of url: URL) -> OwnerProbe {
            forbid("ownerProbe", url.path)
            return super.ownerProbe(of: url)
        }
        override func leafMetadata(of url: URL) -> LeafMetadata? {
            forbid("leafMetadata", url.path)
            return super.leafMetadata(of: url)
        }
        override func linkCount(of url: URL) -> UInt64? {
            forbid("linkCount", url.path)
            return super.linkCount(of: url)
        }
    }

    /// THE r15 FINDING: the probe that decides `isDirectory` is an `lstat`
    /// of the DECLARED root, and `lstat` OF a mount point is served by the
    /// mounted filesystem — so a declared root that is itself an
    /// unresponsive hard mount blocked app construction, on the main thread,
    /// before any window or trigger gate existed.
    ///
    /// Refused from the kernel table instead, with ZERO calls naming the
    /// root. Measured against this same fixture before the preflight
    /// existed: `resolve` made 3 (`probeKind`, then `identity` twice from
    /// the de-dupe's `sameLocation`).
    func testAnOverMountedDeclaredRootIsRefusedBeforeAnythingProbesIt() throws {
        let mounted = try mkdir(base.appendingPathComponent("mounted-C"))
        let realTemp = try mkdir(base.appendingPathComponent("real-T"))
        let stub = ConfstrStub([
            _CS_DARWIN_USER_CACHE_DIR: mounted.path,
            _CS_DARWIN_USER_TEMP_DIR: realTemp.path,
        ])
        let provider = MountedRootForbiddingProvider(fail: { XCTFail($0) })
        provider.mountedRootPath = declaredPath(mounted)

        let resolved = EphemeralTempRoots.resolve(
            provider: provider, confstrPath: stub.resolve(_:)
        )

        XCTAssertNil(
            root(resolved.roots, labelled: EphemeralTempRoots.userCache),
            "the over-mounted root is not registered: "
                + "\(resolved.roots.map(\.url.path))"
        )
        // One root refused, never the resolution: the siblings survive.
        XCTAssertEqual(
            resolved.roots.map(\.url.path),
            ["/private/tmp", declaredPath(realTemp)]
        )

        XCTAssertEqual(resolved.issues.count, 1, "\(resolved.issues)")
        let issue = try XCTUnwrap(resolved.issues.first)
        XCTAssertEqual(issue.kind, .mountedVolumeRootAtRegistration)
        XCTAssertEqual(issue.url?.path, declaredPath(mounted))
        XCTAssertTrue(issue.detail.contains("is a mounted volume"),
                      issue.detail)
        // The deterministic-bound rule: this verdict is stored and replayed,
        // so the remedy it names must be the one that actually clears it.
        XCTAssertTrue(
            issue.detail.contains(EphemeralTempRoots.registrationMountRemedy),
            issue.detail
        )
        XCTAssertTrue(issue.detail.contains("relaunch"), issue.detail)
        XCTAssertFalse(
            issue.detail.contains("re-scan"),
            "a re-scan cannot clear a verdict made once per runtime: "
                + issue.detail
        )
        // …and the KIND is what the GUI turns into the visible row label.
        // `.mountedVolumeRoot`'s label ends "then re-scan" and would send the
        // user round a loop that never clears the row.
        XCTAssertEqual(
            ScanIssueRowPresentation(issue: issue, home: base).label,
            "mounted volume at launch; unmount it, then relaunch"
        )
    }

    /// THE FIX AT `production()` SCOPE — the half a drop-vs-keep decision
    /// turns on. A root KEPT here would reach the runtime's cross-scanner
    /// union, where `SpaceScannerRuntime.suppressingAliasShadows`
    /// (`suppressingAliasShadows`' probe pair,
    /// `SpaceScanner.swift:2021-2025`) canonicalizes and probes every root
    /// it is given, still during construction — so the block would simply
    /// move one function along. Measured against this fixture before the
    /// preflight existed: `production()` made 5 calls naming the mounted
    /// root, 3 from `resolve` and 2 from that pair.
    ///
    /// Driven through the SHIPPED `??` arm (no `ephemeralTempRoots:`), which
    /// is the arm both the GUI and the CLI take.
    func testTheOverMountedRootNeverReachesTheCrossScannerUnion() throws {
        let mounted = try mkdir(base.appendingPathComponent("mounted-C"))
        let stub = ConfstrStub([_CS_DARWIN_USER_CACHE_DIR: mounted.path])
        let provider = MountedRootForbiddingProvider(fail: { XCTFail($0) })
        provider.mountedRootPath = declaredPath(mounted)

        let runtime = SpaceScannerRuntime.production(
            home: base,
            provider: provider,
            devRoots: DevRootsResolution(keptRoots: [], issues: []),
            ephemeralTempConfstrPath: stub.resolve(_:)
        )

        XCTAssertFalse(
            runtime.trustedContainerRoots.contains {
                $0.path == declaredPath(mounted)
            },
            "the over-mounted root reached delete-time admission: "
                + "\(runtime.trustedContainerRoots.map(\.path))"
        )
        let tempScanner = try XCTUnwrap(
            runtime.scanners.first { $0.id == "ephemeral_tmp" }
        )
        XCTAssertFalse(
            tempScanner.trustedContainerRoots.contains {
                $0.path == declaredPath(mounted)
            },
            "\(tempScanner.trustedContainerRoots.map(\.path))"
        )
    }

    /// THE PRODUCTION-DEFAULT CELL: a REAL volume attached exactly at a
    /// declared root, refused from the REAL kernel table (`getfsstat`, no
    /// injected table) with nothing contacting it. This is what evidences
    /// that the kernel's canonical `f_mntonname` spelling is the same string
    /// fn-6.1 declares — the assumption the string membership above rests
    /// on. Skipped, never silently passed, where `hdiutil` cannot stage it.
    func testARealVolumeAtADeclaredRootIsRefusedAtRegistration() throws {
        let mounted = try mkdir(base.appendingPathComponent("mounted-C"))
        let rootPath = declaredPath(mounted)
        guard try attachDMG(named: "regroot.dmg",
                            at: URL(fileURLWithPath: rootPath)) else {
            throw XCTSkip("hdiutil could not stage the mount fixture")
        }
        guard FileSystemIdentityProvider().mountPointPaths()
            .contains(rootPath) else {
            throw XCTSkip(
                "kernel table does not spell the mount as \(rootPath)"
            )
        }

        let stub = ConfstrStub([_CS_DARWIN_USER_CACHE_DIR: mounted.path])
        let provider = MountedRootForbiddingProvider(fail: { XCTFail($0) })
        provider.mountedRootPath = rootPath
        provider.alsoRealTable = true

        let resolved = EphemeralTempRoots.resolve(
            provider: provider, confstrPath: stub.resolve(_:)
        )

        XCTAssertNil(
            root(resolved.roots, labelled: EphemeralTempRoots.userCache),
            "\(resolved.roots.map(\.url.path))"
        )
        XCTAssertEqual(resolved.issues.map(\.kind),
                       [.mountedVolumeRootAtRegistration])
        XCTAssertEqual(resolved.issues.first?.url?.path, rootPath)
    }

    /// `hdiutil`-staged APFS volume at `mountpoint`, detached at teardown.
    /// `false` when the tool is unavailable or refuses — the callers SKIP
    /// rather than pass vacuously.
    private func attachDMG(
        named name: String, at mountpoint: URL
    ) throws -> Bool {
        let image = base.appendingPathComponent(name)
        func run(_ arguments: [String]) throws -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
        guard try run([
            "create", "-size", "8m", "-fs", "APFS",
            "-volname", name, image.path,
        ]) else { return false }
        guard try run([
            "attach", image.path, "-mountpoint", mountpoint.path,
            "-nobrowse", "-quiet",
        ]) else { return false }
        addTeardownBlock {
            _ = try? run(["detach", mountpoint.path, "-force"])
        }
        return true
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
