// swift-tools-version: 6.3
// google-play-store-mcp — reusable Google auth / Google Play clients and an MCP server.

import PackageDescription

let package = Package(
    name: "google-play-store-mcp",
    platforms: [.macOS(.v15)],
    products: [
        // Google service-account auth: credentials, RS256 JWT, OAuth2, workload identity federation.
        .library(name: "GoogleAuthKit", targets: ["GoogleAuthKit"]),
        // Google Play Developer API v3 client, DTOs, and the edit→upload→track→commit workflow.
        .library(name: "GooglePlayKit", targets: ["GooglePlayKit"]),
        // MCP server exposing the Play Developer API to an AI agent.
        .executable(name: "google-play-store-mcp", targets: ["GooglePlayMCPServer"]),
    ],
    dependencies: [
        // Stays on the 4.x line: see app-store-connect-mcp's swift-crypto comment — jwt-kit's
        // transitive dependency on apple/swift-certificates still hard-caps swift-crypto below
        // 5.0.0, and both packages must resolve to the same swift-crypto version inside
        // ShipItSwifty's dependency graph. 4.5.1 fixes CVE-2026-28815 (X-Wing HPKE decapsulation
        // accepting malformed ciphertext length); pin the floor there.
        .package(url: "https://github.com/apple/swift-crypto", from: "4.5.2"),
        .package(url: "https://github.com/apple/swift-log", from: "1.12.0"),
        // Pin the public upstream PR for object-valued experimental capabilities sent by Codex.
        // Return to an upstream release once it includes this decoding fix.
        .package(
            url: "https://github.com/nstrm/swift-sdk.git",
            revision: "f7077e0d5cd57e0b2a497862017aa94ee344252f"
        ),
        // Documentation only; contributes no code to any product.
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "GoogleAuthKit",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "CryptoExtras", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "GooglePlayKit",
            dependencies: [
                "GoogleAuthKit",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "GooglePlayMCPServer",
            dependencies: [
                "GoogleAuthKit",
                "GooglePlayKit",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "GoogleAuthKitTests",
            dependencies: [
                "GoogleAuthKit",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "GooglePlayKitTests",
            dependencies: [
                "GoogleAuthKit",
                "GooglePlayKit",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "GooglePlayMCPServerTests",
            dependencies: [
                "GooglePlayMCPServer",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
