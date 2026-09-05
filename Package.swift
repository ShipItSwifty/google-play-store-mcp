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
        .package(url: "https://github.com/apple/swift-crypto", from: "4.4.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.12.0"),
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
