// swift-tools-version: 6.2
// Phase 0 spike: stdio MCP server built on the official MCP Swift SDK.
// Throwaway code.

import PackageDescription

let package = Package(
    name: "mcp-ping",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Pinned exactly; 0.12.1 == a0ae212ebf6eab5f754c3129608bc5557637e605
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        // Already in the SDK's graph; declared only because `Transport.logger` is a swift-log Logger.
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "mcp-ping",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
