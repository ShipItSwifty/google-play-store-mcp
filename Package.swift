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
        // Support Crypto 4.x consumers (including ShipItSwifty) and Crypto 5.x.
        // 4.5.2 includes the RSA key-size fixes used by service-account signing.
        .package(url: "https://github.com/apple/swift-crypto", "4.5.2"..<"6.0.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.12.0"),
        // Unsupported experimental capabilities are filtered by CapabilityCompatibleTransport
        // until upstream PR #276 lands, keeping the libraries consumable through SemVer.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
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
