// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Cacheout",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "CKernelPrivate",
            path: "Sources/CKernelPrivate",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CacheoutShared",
            path: "Sources/CacheoutShared"
        ),
        .executableTarget(
            name: "Cacheout",
            dependencies: ["Sparkle", "CacheoutShared"],
            path: "Sources/Cacheout",
            resources: [.process("Resources")]
        ),
        .target(
            name: "CacheoutHelperLib",
            dependencies: ["CacheoutShared", "CKernelPrivate"],
            path: "Sources/CacheoutHelperLib"
        ),
        .executableTarget(
            name: "CacheoutHelper",
            dependencies: ["CacheoutShared", "CacheoutHelperLib", "CKernelPrivate"],
            path: "Sources/CacheoutHelper"
        ),
        .testTarget(
            name: "CacheoutHelperTests",
            dependencies: ["CacheoutHelperLib", "CKernelPrivate"],
            path: "Tests/CacheoutHelperTests"
        ),
        .testTarget(
            name: "CacheoutTests",
            dependencies: ["Cacheout", "CacheoutShared"],
            path: "Tests/CacheoutTests"
        ),
    ]
)
