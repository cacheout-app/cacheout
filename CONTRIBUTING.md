# Contributing to Cacheout

Thanks for your interest in contributing! Cacheout is a macOS developer utility for
cleaning cache directories, and contributions are welcome.

## Quick Start

```bash
git clone https://github.com/yourusername/cacheout.git
cd cacheout
swift build
```

## How to Contribute

### Adding a Cache Category

The most common contribution. Edit `Sources/Cacheout/Scanner/Categories.swift`:

```swift
CacheCategory(
    name: "Your Tool Cache",
    slug: "your_tool_cache",
    description: "Short description.",
    icon: "sf.symbol.name",
    discovery: [
        .probed(
            command: "your-tool --cache-dir 2>/dev/null",
            requiresTool: "your-tool",
            fallbacks: ["Library/Caches/YourTool"]
        )
    ],
    riskLevel: .safe,
    rebuildNote: "What happens after cleaning",
    defaultSelected: true
)
```

### Bug Fixes & Features

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/your-feature`
3. Make changes, ensure `swift build` and `swift test` succeed
4. Test both GUI mode and CLI mode (`--cli scan`; destructive commands require
   `--confirm` — preview safely with `--cli clean <slug> --dry-run`)
5. Submit a PR with a clear description

> **A green tally is not a green run.** A trapping construct (`as!`, `try!`,
> a force-unwrap, an out-of-range subscript) kills the whole test process,
> and every `Executed N tests … 0 failures` line printed BEFORE the kill
> stays in the log — one truncated run showed a passing tally while ~26
> later suites never executed (fn-4.14). When reading a `swift test` log,
> trust only the process EXIT CODE and the final executed COUNT compared
> against the expected baseline, never a greppable `0 failures` line.
> `StrandFenceTests` fences the trapping shapes out of test sources.

## Documentation

Full technical documentation is in [docs/v1/](docs/v1/):
- [Architecture](docs/v1/ARCHITECTURE.md)
- [API Reference](docs/v1/API-REFERENCE.md)
- [Contributing Guide](docs/v1/CONTRIBUTING.md) (detailed)

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
