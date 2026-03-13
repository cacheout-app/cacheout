# Cache Categories

Cacheout scans 25+ cache categories organized into groups. This document details each
category's paths, discovery method, risk level, and behavior.

## Category Overview

| # | Category | Risk | Default Selected | Discovery |
|---|----------|------|------------------|-----------|
| 1 | Xcode DerivedData | Safe | Yes | Static |
| 2 | Xcode Device Support | Review | Yes | Static |
| 3 | Simulator Devices | Review | No | Static + Custom Command |
| 4 | Swift PM Cache | Safe | Yes | Static |
| 5 | CocoaPods Cache | Safe | Yes | Probed |
| 6 | Homebrew Cache | Safe | Yes | Probed |
| 7 | npm Cache | Safe | Yes | Probed |
| 8 | Yarn Cache | Safe | Yes | Probed |
| 9 | pnpm Store | Safe | Yes | Probed |
| 10 | Bun Cache | Safe | Yes | Probed |
| 11 | node-gyp Cache | Safe | Yes | Probed |
| 12 | Playwright Browsers | Safe | Yes | Static |
| 13 | pip Cache | Safe | Yes | Probed |
| 14 | uv Cache | Safe | Yes | Probed |
| 15 | PyTorch Hub Models | Review | No | Static |
| 16 | Gradle Cache | Safe | Yes | Static |
| 17 | Docker Disk Image | Caution | No | Probed |
| 18 | VS Code Cache | Safe | Yes | Static |
| 19 | Electron Cache | Safe | Yes | Static |
| 20 | Browser Caches | Review | Yes | Static |
| 21 | ChatGPT Desktop Cache | Safe | Yes | Static |
| 22 | Prisma Engines | Safe | Yes | Static |
| 23 | TypeScript Build Cache | Safe | Yes | Static |

---

## Xcode & Apple Development

### Xcode DerivedData
- **Slug:** `xcode_derived_data`
- **Risk:** Safe
- **Path:** `~/Library/Developer/Xcode/DerivedData`
- **Discovery:** Static
- **After cleaning:** Xcode rebuilds on next build
- **Typical size:** 2–20 GB
- **Notes:** Contains build artifacts, indexes, and module caches. Completely safe to delete — Xcode regenerates everything on next build.

### Xcode Device Support
- **Slug:** `xcode_device_support`
- **Risk:** Review
- **Path:** `~/Library/Developer/Xcode/iOS DeviceSupport`
- **Discovery:** Static
- **After cleaning:** Re-downloads when you connect a device
- **Typical size:** 2–15 GB
- **Notes:** Contains debug symbols for each iOS version you've connected. Accumulates across iOS updates.

### Simulator Devices
- **Slug:** `simulator_devices`
- **Risk:** Review
- **Path:** `~/Library/Developer/CoreSimulator/Devices`
- **Discovery:** Static
- **Clean command:** `xcrun simctl shutdown all; xcrun simctl delete unavailable; xcrun simctl erase all`
- **After cleaning:** Recreated when you use Simulator
- **Typical size:** 5–30 GB
- **Notes:** Uses a custom clean command instead of file deletion. Shuts down running simulators, deletes unavailable ones, and erases all data.

### Swift PM Cache
- **Slug:** `swift_pm_cache`
- **Risk:** Safe
- **Path:** `~/Library/Caches/org.swift.swiftpm`
- **Discovery:** Static
- **After cleaning:** SPM re-resolves on next build

### CocoaPods Cache
- **Slug:** `cocoapods_cache`
- **Risk:** Safe
- **Probe command:** `pod cache list --short 2>/dev/null | head -1 | sed 's|/[^/]*$||'`
- **Requires tool:** `pod`
- **Fallback:** `~/Library/Caches/CocoaPods`
- **After cleaning:** `pod install` re-downloads

---

## Package Managers

### Homebrew Cache
- **Slug:** `homebrew_cache`
- **Risk:** Safe
- **Probe command:** `brew --cache 2>/dev/null`
- **Requires tool:** `brew`
- **Fallback:** `~/Library/Caches/Homebrew`
- **After cleaning:** Equivalent to `brew cleanup`
- **Typical size:** 1–10 GB

---

## JavaScript / Node.js

### npm Cache
- **Slug:** `npm_cache`
- **Risk:** Safe
- **Probe command:** `npm config get cache 2>/dev/null`
- **Requires tool:** `npm`
- **Fallbacks:** `~/.npm/_cacache`, `~/.npm`
- **After cleaning:** npm re-downloads packages as needed

### Yarn Cache
- **Slug:** `yarn_cache`
- **Risk:** Safe
- **Probe command:** `yarn cache dir 2>/dev/null`
- **Requires tool:** `yarn`
- **Fallback:** `~/Library/Caches/Yarn`
- **After cleaning:** Yarn re-downloads packages as needed

### pnpm Store
- **Slug:** `pnpm_store`
- **Risk:** Safe
- **Probe command:** `pnpm store path 2>/dev/null`
- **Requires tool:** `pnpm`
- **Fallbacks:** `~/Library/pnpm/store`, `~/.local/share/pnpm/store`
- **After cleaning:** pnpm re-downloads packages as needed

### Bun Cache
- **Slug:** `bun_cache`
- **Risk:** Safe
- **Requires tool:** `bun`
- **Fallback:** `~/.bun/install/cache`
- **After cleaning:** Bun re-downloads packages as needed
- **Notes:** Bun doesn't have a cache-dir command, so discovery uses a dummy probe with tool check + fallback.

### node-gyp Cache
- **Slug:** `node_gyp_cache`
- **Risk:** Safe
- **Requires tool:** `node`
- **Fallback:** `~/Library/Caches/node-gyp`
- **After cleaning:** Re-downloads when native modules are built

### Playwright Browsers
- **Slug:** `playwright_browsers`
- **Risk:** Safe
- **Paths:** `~/Library/Caches/ms-playwright`, `~/Library/Caches/ms-playwright-go`
- **Discovery:** Static
- **After cleaning:** Reinstall with `npx playwright install`

---

## Python

### pip Cache
- **Slug:** `pip_cache`
- **Risk:** Safe
- **Probe command:** `pip3 cache dir 2>/dev/null || python3 -m pip cache dir 2>/dev/null`
- **Requires tool:** None (python3 ships with macOS)
- **Fallbacks:** `~/Library/Caches/pip`, `~/Library/Caches/pip-tools`
- **After cleaning:** pip re-downloads packages as needed

### uv Cache
- **Slug:** `uv_cache`
- **Risk:** Safe
- **Probe command:** `uv cache dir 2>/dev/null`
- **Requires tool:** `uv`
- **Fallback:** `~/.cache/uv`
- **After cleaning:** uv re-downloads packages as needed. Also: `uv cache clean`.

### PyTorch Hub Models
- **Slug:** `torch_hub`
- **Risk:** Review
- **Path:** `~/.cache/torch`
- **Discovery:** Static
- **After cleaning:** Models re-download on next use (can be slow for large models)
- **Notes:** Not selected by default because large model downloads can be very slow.

---

## JVM / Build Systems

### Gradle Cache
- **Slug:** `gradle_cache`
- **Risk:** Safe
- **Path:** `~/.gradle/caches`
- **Discovery:** Static
- **After cleaning:** Gradle re-downloads on next build

---

## Containers

### Docker Disk Image
- **Slug:** `docker_disk`
- **Risk:** Caution
- **Requires tool:** `docker`
- **Fallbacks:** `~/Library/Containers/com.docker.docker/Data/vms/0/data`, `~/Library/Containers/com.docker.docker/Data`
- **After cleaning:** Removes ALL Docker data. Run `docker system prune -a` first.
- **Typical size:** 5–60 GB
- **Notes:** This is Docker's virtual disk containing all images, containers, and volumes. Deleting it is equivalent to a full Docker reset. Not selected by default. Uses sparse file — `totalFileAllocatedSize` reports actual disk usage correctly.

---

## Editors & Desktop Apps

### VS Code Cache
- **Slug:** `vscode_cache`
- **Risk:** Safe
- **Paths:** `~/Library/Caches/com.microsoft.VSCode.ShipIt`, `~/Library/Caches/com.microsoft.VSCode`
- **Discovery:** Static
- **After cleaning:** VS Code re-downloads as needed

### Electron Cache
- **Slug:** `electron_cache`
- **Risk:** Safe
- **Path:** `~/Library/Caches/electron`
- **Discovery:** Static
- **After cleaning:** Re-downloads when Electron apps need it

### Browser Caches
- **Slug:** `browser_caches`
- **Risk:** Review
- **Paths:** `~/Library/Caches/BraveSoftware`, `~/Library/Caches/Google`, `~/Library/Caches/com.brave.Browser`, `~/Library/Caches/com.google.Chrome`
- **Discovery:** Static
- **After cleaning:** Browsers rebuild caches as you browse

---

## AI / LLM

### ChatGPT Desktop Cache
- **Slug:** `chatgpt_desktop_cache`
- **Risk:** Safe
- **Path:** `~/Library/Caches/com.openai.atlas`
- **Discovery:** Static
- **After cleaning:** ChatGPT re-creates cache on next launch

---

## Misc Development

### Prisma Engines
- **Slug:** `prisma_engines`
- **Risk:** Safe
- **Path:** `~/.cache/prisma`
- **Discovery:** Static
- **After cleaning:** Re-downloads on next `prisma generate`

### TypeScript Build Cache
- **Slug:** `typescript_cache`
- **Risk:** Safe
- **Paths:** `~/Library/Caches/typescript`, `~/Library/Caches/next-swc`
- **Discovery:** Static
- **After cleaning:** Regenerated on next build

---

## node_modules Discovery

In addition to cache categories, Cacheout includes a dedicated `node_modules` scanner
that recursively searches common project directories.

### Search Roots

The scanner checks these directories under `$HOME`:
- Documents, Developer, Projects, Code, Sites, Desktop, Dropbox, repos, src, work

### Scanning Behavior

- Maximum recursion depth: 6 levels
- Stops recursing when `node_modules` is found (no nested projects expected)
- Skips: .Trash, .git, .hg, node_modules, .build, DerivedData, Pods, .next, dist, build, Library, .cache, .npm, .yarn
- Deduplicates by absolute path
- Results sorted by size descending

### Staleness

A `node_modules` directory is considered **stale** if its modification date is older
than 30 days. Stale directories show an age badge (e.g., "3mo old", "1y old") in the UI.

---

## Adding a New Category

1. Edit `Sources/Cacheout/Scanner/Categories.swift`
2. Add a new `CacheCategory(...)` entry in the appropriate MARK section
3. Choose the right `PathDiscovery`:
   - Static path: `paths: ["Library/Caches/YourApp"]`
   - Probed: `discovery: [.probed(command: "your-tool --cache-dir", requiresTool: "your-tool", fallbacks: ["Library/Caches/YourTool"])]`
4. Set `riskLevel` conservatively
5. Write a clear `rebuildNote`
6. Set `defaultSelected: true` only for `.safe` categories
