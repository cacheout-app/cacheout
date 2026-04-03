/// # Categories — Cache Category Registry
///
/// Defines all cache categories that Cacheout scans. Each entry specifies the category
/// name, filesystem paths (via `PathDiscovery`), risk level, and rebuild instructions.
///
/// ## Adding a New Category
///
/// 1. Add a new `CacheCategory(...)` entry to `allCategories` in the appropriate
///    MARK section.
/// 2. Choose the correct `PathDiscovery` type:
///    - Use `.staticPath("Library/Caches/YourApp")` for fixed home-relative paths.
///    - Use `.probed(command:requiresTool:fallbacks:)` when the cache location
///      can be queried dynamically (e.g., `brew --cache`).
///    - Use `.absolutePath("/some/system/path")` for paths outside `~/`.
/// 3. Set `riskLevel` conservatively — when in doubt, use `.review`.
/// 4. Write a clear `rebuildNote` explaining what happens after cleaning.
/// 5. Set `defaultSelected: true` only for `.safe` categories.
///
/// ## Current Category Groups
///
/// - **Xcode & Apple Development**: DerivedData, Device Support, Simulators, SPM, CocoaPods
/// - **Package Managers**: Homebrew
/// - **JavaScript/Node.js**: npm, Yarn, pnpm, Bun, node-gyp, Playwright
/// - **Python**: pip, uv, PyTorch Hub
/// - **JVM/Build Systems**: Gradle
/// - **Containers**: Docker Disk Image
/// - **Editors & Desktop Apps**: VS Code, Electron, Browser Caches
/// - **AI/LLM**: ChatGPT Desktop
/// - **Misc Development**: Prisma Engines, TypeScript Build Cache

extension CacheCategory {
    static let allCategories: [CacheCategory] = [

        // ─────────────────────────────────────────────────────────
        // MARK: - Xcode & Apple Development
        // ─────────────────────────────────────────────────────────

        CacheCategory(
            name: "Xcode DerivedData",
            slug: "xcode_derived_data",
            description: "Build artifacts and indexes. Xcode rebuilds automatically.",
            icon: "hammer.fill",
            paths: ["Library/Developer/Xcode/DerivedData"],
            riskLevel: .safe,
            rebuildNote: "Xcode rebuilds on next build",
            defaultSelected: true
        ),
        CacheCategory(
            name: "Xcode Device Support",
            slug: "xcode_device_support",
            description: "Debug symbols for connected iOS devices. Re-downloads on device connect.",
            icon: "iphone",
            paths: ["Library/Developer/Xcode/iOS DeviceSupport"],
            riskLevel: .review,
            rebuildNote: "Re-downloads when you connect a device",
            defaultSelected: true
        ),
        CacheCategory(
            name: "Simulator Devices",
            slug: "simulator_devices",
            description: "iOS/watchOS/tvOS simulator data and device states. Can be several GB.",
            icon: "ipad.landscape",
            discovery: [
                .staticPath("Library/Developer/CoreSimulator/Devices")
            ],
            riskLevel: .review,
            rebuildNote: "Recreated when you use Simulator. Run 'xcrun simctl delete unavailable' for targeted cleanup.",
            defaultSelected: false,
            cleanSteps: [
                ["xcrun", "simctl", "shutdown", "all"],
                ["xcrun", "simctl", "delete", "unavailable"],
                ["xcrun", "simctl", "erase", "all"]
            ]
        ),        CacheCategory(
            name: "Swift PM Cache",
            slug: "swift_pm_cache",
            description: "Swift Package Manager resolved packages.",
            icon: "swift",
            paths: ["Library/Caches/org.swift.swiftpm"],
            riskLevel: .safe,
            rebuildNote: "SPM re-resolves on next build",
            defaultSelected: true
        ),
        CacheCategory(
            name: "CocoaPods Cache",
            slug: "cocoapods_cache",
            description: "Cached CocoaPods specs and downloaded pods.",
            icon: "leaf.fill",
            discovery: [
                .probed(
                    executable: "pod",
                    arguments: ["cache", "list", "--short"],
                    requiresTool: "pod",
                    fallbacks: ["Library/Caches/CocoaPods"],
                    transform: { output in
                        // Equivalent to `head -1 | sed 's|/[^/]*$||'`
                        let firstLine = output.components(separatedBy: "\n").first ?? ""
                        let components = firstLine.components(separatedBy: "/")
                        if components.count > 1 {
                            return components.dropLast().joined(separator: "/")
                        }
                        return firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                )
            ],
            riskLevel: .safe,
            rebuildNote: "'pod install' re-downloads as needed",
            defaultSelected: true
        ),

        // ─────────────────────────────────────────────────────────
        // MARK: - Package Managers (Homebrew, System)
        // ─────────────────────────────────────────────────────────

        CacheCategory(
            name: "Homebrew Cache",
            slug: "homebrew_cache",
            description: "Downloaded formula bottles and source tarballs.",
            icon: "mug.fill",
            discovery: [
                .probed(
                    executable: "brew",
                    arguments: ["--cache"],
                    requiresTool: "brew",
                    fallbacks: ["Library/Caches/Homebrew"]
                )
            ],
            riskLevel: .safe,
            rebuildNote: "Equivalent to 'brew cleanup'",
            defaultSelected: true
        ),

        // ─────────────────────────────────────────────────────────
        // MARK: - JavaScript / Node.js Ecosystem
        // ─────────────────────────────────────────────────────────

        CacheCategory(
            name: "npm Cache",
            slug: "npm_cache",
            description: "Cached npm packages. Re-downloads on next install.",
            icon: "shippingbox.fill",
            discovery: [
                .probed(
                    executable: "npm",
                    arguments: ["config", "get", "cache"],
                    requiresTool: "npm",
                    fallbacks: [".npm/_cacache", ".npm"]
                )
            ],
            riskLevel: .safe,
            rebuildNote: "npm re-downloads packages as needed",
            defaultSelected: true
        ),        CacheCategory(
            name: "Yarn Cache",
            slug: "yarn_cache",
            description: "Cached Yarn packages and metadata.",
            icon: "link",
            discovery: [
                .probed(
                    executable: "yarn",
                    arguments: ["cache", "dir"],
                    requiresTool: "yarn",
                    fallbacks: ["Library/Caches/Yarn"]
                )
            ],
            riskLevel: .safe,
            rebuildNote: "Yarn re-downloads packages as needed",
            defaultSelected: true
        ),
        CacheCategory(
            name: "pnpm Store",
            slug: "pnpm_store",
            description: "Content-addressable pnpm package store.",
            icon: "archivebox.fill",
            discovery: [
                .probed(
                    executable: "pnpm",
                    arguments: ["store", "path"],
                    requiresTool: "pnpm",
                    fallbacks: ["Library/pnpm/store", ".local/share/pnpm/store"]
                )
            ],
            riskLevel: .safe,
            rebuildNote: "pnpm re-downloads packages as needed",
            defaultSelected: true
        ),
        CacheCategory(
            name: "Bun Cache",
            slug: "bun_cache",
            description: "Bun package manager install cache.",
            icon: "hare.fill",
            discovery: [
                .probed(
                    executable: "echo",
                    arguments: ["dummy"], // bun doesn't have a cache-dir command
                    requiresTool: "bun",
                    fallbacks: [".bun/install/cache"],
                    transform: { _ in return nil } // Force fallback behavior
                )
            ],
            riskLevel: .safe,
            rebuildNote: "Bun re-downloads packages as needed",
            defaultSelected: true
        ),
        CacheCategory(
            name: "node-gyp Cache",
            slug: "node_gyp_cache",
            description: "Native Node.js addon build headers and artifacts.",
            icon: "wrench.and.screwdriver.fill",
            discovery: [
                .probed(
                    executable: "echo",
                    arguments: ["dummy"],
                    requiresTool: "node",
                    fallbacks: ["Library/Caches/node-gyp"],
                    transform: { _ in return nil } // Force fallback behavior
                )
            ],
            riskLevel: .safe,
            rebuildNote: "Re-downloads when native modules are built",
            defaultSelected: true
        ),
        CacheCategory(
            name: "Playwright Browsers",
            slug: "playwright_browsers",
            description: "Downloaded browser binaries for Playwright testing.",
            icon: "theatermasks.fill",
            paths: ["Library/Caches/ms-playwright", "Library/Caches/ms-playwright-go"],
            riskLevel: .safe,
            rebuildNote: "Reinstall with 'npx playwright install'",
            defaultSelected: true
        ),
        // ─────────────────────────────────────────────────────────
        // MARK: - Python Ecosystem
        // ─────────────────────────────────────────────────────────

        CacheCategory(
            name: "pip Cache",
            slug: "pip_cache",
            description: "Cached Python packages from pip installs.",
            icon: "puzzlepiece.fill",
            discovery: [
                .probed(
                    executable: "python3",
                    arguments: ["-m", "pip", "cache", "dir"],
                    requiresTool: nil, // python3 is always on macOS
                    fallbacks: ["Library/Caches/pip", "Library/Caches/pip-tools"]
                )
            ],
            riskLevel: .safe,
            rebuildNote: "pip re-downloads packages as needed",
            defaultSelected: true
        ),
        CacheCategory(
            name: "uv Cache",
            slug: "uv_cache",
            description: "Fast Python package installer cache. Can grow large with many environments.",
            icon: "bolt.fill",
            discovery: [
                .probed(
                    executable: "uv",
                    arguments: ["cache", "dir"],
                    requiresTool: "uv",
                    fallbacks: [".cache/uv"]
                )
            ],
            riskLevel: .safe,
            rebuildNote: "uv re-downloads packages as needed. Clean with 'uv cache clean'.",
            defaultSelected: true
        ),
        CacheCategory(
            name: "PyTorch Hub Models",
            slug: "torch_hub",
            description: "Downloaded PyTorch models and datasets.",
            icon: "brain.fill",
            paths: [".cache/torch"],
            riskLevel: .review,
            rebuildNote: "Models re-download on next use (can be slow for large models)",
            defaultSelected: false
        ),

        // ─────────────────────────────────────────────────────────
        // MARK: - JVM / Build Systems
        // ─────────────────────────────────────────────────────────

        CacheCategory(
            name: "Gradle Cache",
            slug: "gradle_cache",
            description: "Gradle build cache and downloaded dependencies.",
            icon: "gearshape.2.fill",
            paths: [".gradle/caches"],
            riskLevel: .safe,
            rebuildNote: "Gradle re-downloads on next build",
            defaultSelected: true
        ),
        // ─────────────────────────────────────────────────────────
        // MARK: - Container / VM
        // ─────────────────────────────────────────────────────────

        CacheCategory(
            name: "Docker Disk Image",
            slug: "docker_disk",
            description: "Docker's virtual disk. Contains all images, containers, and volumes. This is often the single largest space consumer.",
            icon: "cube.fill",
            discovery: [
                .probed(
                    executable: "echo",
                    arguments: ["dummy"],
                    requiresTool: "docker",
                    fallbacks: [
                        "Library/Containers/com.docker.docker/Data/vms/0/data",
                        "Library/Containers/com.docker.docker/Data"
                    ],
                    transform: { _ in return nil } // Force fallback behavior
                )
            ],
            riskLevel: .caution,
            rebuildNote: "Run 'docker system prune -a' first, or delete to reset Docker completely",
            defaultSelected: false
        ),

        // ─────────────────────────────────────────────────────────
        // MARK: - Editors & Desktop Apps
        // ─────────────────────────────────────────────────────────

        CacheCategory(
            name: "VS Code Cache",
            slug: "vscode_cache",
            description: "VS Code update downloads and extension cache.",
            icon: "chevron.left.forwardslash.chevron.right",
            paths: [
                "Library/Caches/com.microsoft.VSCode.ShipIt",
                "Library/Caches/com.microsoft.VSCode"
            ],
            riskLevel: .safe,
            rebuildNote: "VS Code re-downloads as needed",
            defaultSelected: true
        ),
        CacheCategory(
            name: "Electron Cache",
            slug: "electron_cache",
            description: "Shared Electron framework cache used by Electron-based apps.",
            icon: "atom",
            paths: ["Library/Caches/electron"],
            riskLevel: .safe,
            rebuildNote: "Re-downloads when Electron apps need it",
            defaultSelected: true
        ),
        CacheCategory(
            name: "Browser Caches",
            slug: "browser_caches",
            description: "Cached web content from Brave, Chrome, and other browsers.",
            icon: "globe",
            paths: [
                "Library/Caches/BraveSoftware",
                "Library/Caches/Google",
                "Library/Caches/com.brave.Browser",
                "Library/Caches/com.google.Chrome"
            ],
            riskLevel: .review,
            rebuildNote: "Browsers rebuild caches as you browse",
            defaultSelected: true
        ),
        // ─────────────────────────────────────────────────────────
        // MARK: - AI / LLM Desktop Apps
        // ─────────────────────────────────────────────────────────

        CacheCategory(
            name: "ChatGPT Desktop Cache",
            slug: "chatgpt_desktop_cache",
            description: "OpenAI ChatGPT desktop app cache.",
            icon: "bubble.left.and.bubble.right.fill",
            paths: ["Library/Caches/com.openai.atlas"],
            riskLevel: .safe,
            rebuildNote: "ChatGPT re-creates cache on next launch",
            defaultSelected: true
        ),

        // ─────────────────────────────────────────────────────────
        // MARK: - Misc Development Caches
        // ─────────────────────────────────────────────────────────

        CacheCategory(
            name: "Prisma Engines",
            slug: "prisma_engines",
            description: "Prisma ORM query engine binaries.",
            icon: "diamond.fill",
            paths: [".cache/prisma"],
            riskLevel: .safe,
            rebuildNote: "Re-downloads on next 'prisma generate'",
            defaultSelected: true
        ),
        CacheCategory(
            name: "TypeScript Build Cache",
            slug: "typescript_cache",
            description: "TypeScript compiler disk cache and Next.js SWC binaries.",
            icon: "t.square.fill",
            paths: [
                "Library/Caches/typescript",
                "Library/Caches/next-swc"
            ],
            riskLevel: .safe,
            rebuildNote: "Regenerated on next build",
            defaultSelected: true
        ),
    ]
}
