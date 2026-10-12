// aeroops-askpass: the SSH_ASKPASS helper bundled at AeroOps.app/Contents/MacOS/aeroops-askpass.
//
// SSHKit points ssh at it for password hosts. ssh runs it
// with the prompt as the only argument and reads one line from stdout. The helper asks the
// running app over ~/.aeroops/askpass.sock and prints the password. The app only answers this
// binary (its team and identifier), started by an ssh that the app itself started, only for
// password prompts, and only once per ssh process.
//
// On any refusal the helper terminates the /usr/bin/ssh that started it before exiting 1: ssh
// sends an empty password when askpass fails, and servers count that as a failed login, which
// can lock the account (fail2ban, pam_faillock). The message on stderr starts with
// "aeroops-askpass: ", which SSHKit reports as an authentication failure.
//
// Environment (set by SSHKit, passed on by ssh):
//   AEROOPS_ASKPASS_SOCKET   the app's askpass socket
//   AEROOPS_ASKPASS_HOST     the host id whose password ssh needs
//   AEROOPS_ASKPASS_TOKEN    optional: a one-time token for an unsaved password (Test Connection)

import AskpassProtocol
import Darwin
import Foundation

let arguments = CommandLine.arguments
if arguments.count == 2, ["--help", "-h", "--version"].contains(arguments[1]) {
    print("aeroops-askpass: SSH_ASKPASS helper for AeroOps password hosts. AeroOps runs it; it is not for direct use.")
    exit(0)
}

do {
    let password = try AskpassClient.password(
        prompt: arguments.count > 1 ? arguments[1] : "",
        environment: ProcessInfo.processInfo.environment
    )
    FileHandle.standardOutput.write(Data((password + "\n").utf8))
    exit(0)
} catch {
    FileHandle.standardError.write(Data("aeroops-askpass: \(error.message)\n".utf8))
    terminateParentSSH()
    exit(1)
}

/// Sends SIGTERM to the parent if it is /usr/bin/ssh (it is waiting for this process, so the
/// pid cannot have been reused). Run any other way, the helper leaves its parent alone.
func terminateParentSSH() {
    let parent = getppid()
    guard parent > 1 else { return }
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(parent, &buffer, UInt32(buffer.count))
    guard length > 0,
          String(decoding: buffer[0..<Int(length)].map { UInt8(bitPattern: $0) }, as: UTF8.self) == "/usr/bin/ssh" else { return }
    kill(parent, SIGTERM)
}
