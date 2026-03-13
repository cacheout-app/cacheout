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
3. Make changes, ensure `swift build` succeeds
4. Test both GUI mode and CLI mode (`--cli scan`)
5. Submit a PR with a clear description

## Documentation

Full technical documentation is in [docs/v1/](docs/v1/):
- [Architecture](docs/v1/ARCHITECTURE.md)
- [API Reference](docs/v1/API-REFERENCE.md)
- [Contributing Guide](docs/v1/CONTRIBUTING.md) (detailed)

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
