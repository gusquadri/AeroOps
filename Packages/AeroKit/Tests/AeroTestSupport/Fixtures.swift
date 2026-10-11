import Foundation

/// Locates test fixtures in the repo's `dev/fixtures/` directory.
///
/// Fixtures are read in place rather than copied into test bundles as resources, so a fixture
/// captured from a real server is usable by every test target immediately. The repo root is found
/// by walking up from this source file's compile-time path (`#filePath`) until a directory
/// containing `dev/fixtures` appears, which works for both `swift test` and `xcodebuild test`.
///
/// ```swift
/// let text = try Fixtures.string("proc/ubuntu-24.04/metrics.txt")
/// ```
public enum Fixtures {
    /// Errors thrown when a fixture cannot be located or read.
    public enum FixtureError: Error, CustomStringConvertible {
        /// No ancestor of the test sources contains `dev/fixtures`.
        case repoRootNotFound(startingAt: String)
        /// The fixture path does not exist under `dev/fixtures/`.
        case missing(URL)

        public var description: String {
            switch self {
            case .repoRootNotFound(let start): "No ancestor of \(start) contains dev/fixtures"
            case .missing(let url): "Fixture not found: \(url.path)"
            }
        }
    }

    /// The repository root (the directory that contains `dev/`, `Packages/` and `project.yml`).
    public static func repoRoot(filePath: String = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        let fm = FileManager.default
        while dir.path != "/" {
            var isDir: ObjCBool = false
            let candidate = dir.appending(path: "dev/fixtures", directoryHint: .isDirectory)
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        throw FixtureError.repoRootNotFound(startingAt: filePath)
    }

    /// The `dev/fixtures/` directory.
    public static func directory() throws -> URL {
        try repoRoot().appending(path: "dev/fixtures", directoryHint: .isDirectory)
    }

    /// URL of a fixture, given its path relative to `dev/fixtures/`. Throws if it does not exist.
    public static func url(_ relativePath: String) throws -> URL {
        let url = try directory().appending(path: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { throw FixtureError.missing(url) }
        return url
    }

    /// Raw bytes of a fixture, given its path relative to `dev/fixtures/`.
    public static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: url(relativePath))
    }

    /// UTF-8 text of a fixture, given its path relative to `dev/fixtures/`.
    public static func string(_ relativePath: String) throws -> String {
        try String(decoding: data(relativePath), as: UTF8.self)
    }
}
