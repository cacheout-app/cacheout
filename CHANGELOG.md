# Changelog

All notable changes to Cacheout will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] - 2026-01-01

### Added

- Initial release
- 25+ cache categories: Xcode, Docker, npm, Yarn, pnpm, Bun, Homebrew, pip, uv, Gradle, CocoaPods, Swift PM, Playwright, VS Code, Electron, browser caches, ChatGPT Desktop, Prisma, TypeScript, node-gyp, PyTorch Hub
- Recursive node_modules finder with staleness detection (30d+)
- Risk-level indicators (Safe / Review / Caution)
- Async parallel scanning via Swift actors and TaskGroups
- Sparse file awareness (accurate Docker disk image sizing)
- Move to Trash option (recoverable deletion)
- Cleanup logging to `~/.cacheout/cleanup.log`
- Main window with full cache management UI
- Menubar popover with disk gauge and quick clean
- Settings window with scan interval, low-disk threshold, and Docker prune
- CLI mode (`--cli`) with scan, clean, smart-clean, disk-info, and spotlight commands
- Dry-run support for CLI clean commands
- Smart clean: auto-select safe categories until target GB freed
- Spotlight tagging for cache directory discovery
- Custom clean commands (e.g., simulator device cleanup via `xcrun simctl`)
- Probed path discovery (dynamic cache location via shell commands)
- Low-disk notifications with 1-hour throttle
- Customizable scan interval (15min–4h)
- Sparkle framework integration for future auto-updates
- Custom menubar icon with disk-full warning badge
- Homebrew formula
- DMG installer with custom background
- Watchdog scripts for background monitoring
