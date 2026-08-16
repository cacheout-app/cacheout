/// # ProjectTreeEvent — The Shared Walker Event (fn-4.1, R1/R9)
///
/// The ONE walker-event value type shared between the project-tree walker
/// (fn-4.2, which EMITS it) and the build-artifact rule matcher (fn-4.1,
/// which CONSUMES it). Declared here — beside the matcher, its coupling
/// point — so the matcher's input is a full event by TYPE, not by caller
/// discipline (epic round 18).
///
/// A bare `(name, kind)` entry list is deliberately INSUFFICIENT input for
/// matching: it cannot distinguish a broad dev root that happens to contain
/// `pyvenv.cfg` from a child venv directory, so the root-never-eligible rule
/// (D6 — a stray marker must not convert a broad root into an artifact)
/// would degrade into caller discipline. `depth` and `originRoot` make that
/// rule enforceable structurally inside the matcher.

import Foundation

/// One visited directory during a project-tree walk: the directory itself,
/// its depth below the walk's origin root (the origin itself is depth 0),
/// the EXACT declared origin-root spelling the walk started under (validator
/// origin binding needs it verbatim — never canonicalized here), and the
/// directory's immediate entries with their lstat no-follow kinds (from
/// `FileSystemIdentityProvider` probes — a symlink reports `.symlink`, never
/// its target's kind).
struct ProjectTreeEvent: Equatable, Sendable {

    /// One immediate child of `directory`: its name and its lstat no-follow
    /// kind.
    struct Entry: Equatable, Sendable {
        let name: String
        let kind: FileSystemIdentityProvider.FileKind

        init(name: String, kind: FileSystemIdentityProvider.FileKind) {
            self.name = name
            self.kind = kind
        }
    }

    /// The directory this event describes.
    let directory: URL
    /// Depth below `originRoot` — the origin root itself is depth 0, its
    /// immediate subdirectories depth 1.
    let depth: Int
    /// The DECLARED spelling of the dev root this walk started under,
    /// verbatim (provenance/origin binding — never canonicalized).
    let originRoot: URL
    /// Immediate entries of `directory` in the order the walker produced
    /// them.
    let entries: [Entry]

    init(directory: URL, depth: Int, originRoot: URL, entries: [Entry]) {
        self.directory = directory
        self.depth = depth
        self.originRoot = originRoot
        self.entries = entries
    }
}
