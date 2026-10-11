// swift-tools-version:6.2
// Phase 0 throwaway spike: in-process ssh-agent serving Keychain Ed25519,
// Secure Enclave P-256 and RSA (SHA-2) keys over a Unix socket.
import PackageDescription

let package = Package(
    name: "SpikeAgent",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "spike-agent",
            path: "Sources/SpikeAgent",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
