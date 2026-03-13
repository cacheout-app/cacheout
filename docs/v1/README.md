# Cacheout v1 Documentation

Complete technical documentation for the Cacheout macOS application, version 1.0.0.

## Documentation Index

| Document | Description |
|----------|-------------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | System architecture, data flow, concurrency model, and design decisions |
| [API-REFERENCE.md](API-REFERENCE.md) | Complete API reference for all types, protocols, and methods |
| [CLI-REFERENCE.md](CLI-REFERENCE.md) | CLI mode commands, flags, and output format |
| [CATEGORIES.md](CATEGORIES.md) | All cache categories with paths, risk levels, and behavior |
| [UI-GUIDE.md](UI-GUIDE.md) | View hierarchy, layout structure, and user interaction flows |
| [BUILD-AND-DISTRIBUTION.md](BUILD-AND-DISTRIBUTION.md) | Building, bundling, DMG creation, and Homebrew formula |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to add categories, modify views, and submit changes |
| [CONFIGURATION.md](CONFIGURATION.md) | UserDefaults keys, Info.plist settings, and environment |

## Quick Start for New Developers

1. **Read [ARCHITECTURE.md](ARCHITECTURE.md)** first to understand the overall design
2. **Read [API-REFERENCE.md](API-REFERENCE.md)** for the type system and method signatures
3. **Read [CATEGORIES.md](CATEGORIES.md)** to understand the cache category system
4. **Read [CONTRIBUTING.md](CONTRIBUTING.md)** for code conventions and PR guidelines

## Project Overview

Cacheout is a native macOS utility that helps developers reclaim disk space by scanning
and cleaning common cache directories. It targets macOS 14+ (Sonoma) and is built with
Swift 5.9+ and SwiftUI.

**Key numbers:**
- 18 Swift source files
- 25+ cache categories
- 2 execution modes (GUI + CLI)
- 3 app scenes (Main Window, Menubar, Settings)
- 1 external dependency (Sparkle for updates)
