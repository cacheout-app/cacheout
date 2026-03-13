# Contributing to Cacheout

## Quick Start

```bash
git clone https://github.com/yourusername/cacheout.git
cd cacheout
swift build
```

## Code Organization

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full architecture overview.

**Key directories:**
- `Sources/Cacheout/Models/` — Data types
- `Sources/Cacheout/Scanner/` — Scanning logic (actors)
- `Sources/Cacheout/Cleaner/` — Cleanup logic (actor)
- `Sources/Cacheout/ViewModels/` — State management
- `Sources/Cacheout/Views/` — SwiftUI views

## Common Tasks

### Adding a New Cache Category

1. Edit `Sources/Cacheout/Scanner/Categories.swift`
2. Add a new `CacheCategory(...)` in the appropriate MARK section:

```swift
CacheCategory(
    name: "Your Tool Cache",
    slug: "your_tool_cache",               // lowercase, underscored
    description: "Short description for UI.",
    icon: "sf.symbol.name",                // SF Symbol
    discovery: [
        .probed(
            command: "your-tool --cache-dir 2>/dev/null",
            requiresTool: "your-tool",
            fallbacks: ["Library/Caches/YourTool"]
        )
    ],
    riskLevel: .safe,                      // .safe, .review, or .caution
    rebuildNote: "What happens after cleaning",
    defaultSelected: true                  // true only for .safe
)
```

3. Build and test: `swift build && .build/debug/Cacheout --cli scan`
4. Verify the category appears in scan output with correct size

**Guidelines:**
- Set `riskLevel` conservatively — when in doubt, use `.review`
- Always provide fallback paths for probed categories
- Set `requiresTool` when the probe command depends on a specific binary
- Use 2-second timeout-safe commands in probes (avoid interactive prompts)
- Probe commands should include `2>/dev/null` to suppress stderr

### Adding a New View

1. Create the file in `Sources/Cacheout/Views/`
2. Accept `CacheoutViewModel` via `@EnvironmentObject`
3. Follow existing naming conventions (no suffixes for primary views, `Sheet` suffix for modals)
4. Add file-level documentation comment explaining the view's purpose and layout

### Modifying the View Model

The `CacheoutViewModel` is `@MainActor` isolated. All `@Published` properties
update the UI automatically. When adding new state:

1. Add the `@Published` property
2. If persisted, add a `didSet` observer that writes to UserDefaults
3. If loading from UserDefaults, initialize in `init()`
4. Add computed properties for derived state rather than duplicating data

## Code Conventions

### Swift Style

- **Concurrency**: Use actors for thread-safe business logic, `@MainActor` for view models
- **Error handling**: Collect errors rather than throwing — return them in reports
- **File organization**: Use `// MARK: -` sections within files
- **Access control**: Default to internal; use `private` for implementation details
- **Documentation**: File-level `///` doc comments explaining purpose and behavior

### Naming

- **Files**: PascalCase matching the primary type (`CacheScanner.swift`)
- **Types**: PascalCase (`CacheCategory`, `ScanResult`)
- **Properties/methods**: camelCase (`scanResults`, `toggleSelection`)
- **Slugs**: lowercase with underscores (`xcode_derived_data`)
- **SF Symbols**: Use descriptive symbol names (`hammer.fill`, `shippingbox.fill`)

### Architecture Rules

- Views never access scanners/cleaners directly — always through the view model
- Actors handle all filesystem operations
- No force unwrapping except in controlled situations (e.g., known-good data)
- Shell commands always have timeouts (2s for probes, 30s for clean commands)
- Notification APIs always guarded by `canUseNotifications` check

## Testing

Currently no automated tests. When adding tests:

- Test scanners with mock filesystem
- Test view model state transitions
- Test CLI output format
- Test path discovery with mock environment

## Pull Request Guidelines

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/your-feature`
3. Make your changes with clear commit messages
4. Ensure `swift build` succeeds
5. Test both GUI and CLI modes
6. Submit a PR with a clear description of changes

## License

MIT — See [LICENSE](../../LICENSE)
