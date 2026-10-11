import Foundation

/// The POSIX `sh` scripts from `Scripts/remote/`, embedded as strings so the app never reads
/// them from disk at run time. Each script lives in its own `RemoteScripts+<Name>.swift` file
/// and has a test asserting it is byte-identical to the file in `Scripts/remote/`.
///
/// Scripts are sent on stdin to ``shellCommand``, so nothing from them is interpolated into the
/// remote command line:
///
/// ```swift
/// try await runner.run(RemoteScripts.shellCommand, on: host, stdin: Data(RemoteScripts.metrics.utf8))
/// ```
public enum RemoteScripts {
    /// The remote command every script runs under: a POSIX shell reading the script from stdin,
    /// with the C locale so number formats and messages are predictable.
    public static let shellCommand = "LC_ALL=C sh -s"
}
