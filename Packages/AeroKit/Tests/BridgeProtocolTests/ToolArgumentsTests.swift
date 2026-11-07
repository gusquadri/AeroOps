import AeroCore
import Foundation
import Testing
@testable import BridgeProtocol

@Suite("Tool argument validation")
struct ToolArgumentsTests {
    /// The validation message for `arguments`, or `nil` when they are valid.
    private func message(_ tool: String, _ arguments: [String: JSONValue]) -> String? {
        do {
            _ = try ToolCall.parse(toolName: tool, arguments: arguments)
            return nil
        } catch {
            return error.message
        }
    }

    private let logs: [String: JSONValue] = ["host": "web", "kind": "pod", "name": "api-0"]

    @Test func validCallsParse() throws {
        #expect(try ToolCall.parse(toolName: "list_hosts", arguments: [:]) == .monitoring(.listHosts(ListHostsArguments())))
        #expect(try ToolCall.parse(toolName: "list_hosts", arguments: ["tag": "prod"]) == .monitoring(.listHosts(ListHostsArguments(tag: "prod"))))
        #expect(try ToolCall.parse(toolName: "get_host_metrics", arguments: ["host": "  web-1 "]) ==
            .monitoring(.getHostMetrics(HostArguments(host: "web-1"))))
        #expect(try ToolCall.parse(toolName: "list_containers", arguments: ["host": "web", "all": "true"]) ==
            .monitoring(.listContainers(ListContainersArguments(host: "web", all: true))))
        #expect(try ToolCall.parse(toolName: "list_pods", arguments: ["host": "web", "namespace": "kube-system"]) ==
            .monitoring(.listPods(ListPodsArguments(host: "web", namespace: "kube-system"))))
        #expect(try ToolCall.parse(toolName: "run_command", arguments: ["host": "web", "command": "df -h\nuptime", "reason": "disk"]) ==
            .runCommand(RunCommandArguments(host: "web", command: "df -h\nuptime", reason: "disk", timeoutSeconds: 60)))
    }

    @Test func getLogsDefaultsAndConversions() throws {
        let call = try ToolCall.parse(toolName: "get_logs", arguments: logs.merging([
            "namespace": "shop", "container": "app", "tail": "500", "since": "15m", "previous": true,
        ]) { $1 })
        guard case .monitoring(.getLogs(let arguments)) = call else {
            Issue.record("not get_logs")
            return
        }
        #expect(arguments.tail == 500)
        #expect(arguments.sinceSeconds == 900)
        #expect(arguments.previous)
        let request = arguments.logRequest(hostId: UUID())
        #expect(request.kind == .pod)
        #expect(request.namespace == "shop")
        #expect(request.container == "app")
        #expect(request.tail == 500)
        #expect(request.sinceSeconds == 900)
        #expect(!request.follow)

        guard case .monitoring(.getLogs(let defaults)) = try ToolCall.parse(toolName: "get_logs", arguments: logs) else { return }
        #expect(defaults.tail == 200)
        #expect(defaults.sinceSeconds == nil)
        #expect(message("get_logs", logs.merging(["tail": 2000.0, "since": 90]) { $1 }) == nil)
    }

    @Test func limitMessages() {
        #expect(message("get_logs", logs.merging(["tail": 5000]) { $1 }) == "Argument 'tail' must be between 1 and 2000 (got 5000).")
        #expect(message("get_logs", logs.merging(["tail": 0]) { $1 }) == "Argument 'tail' must be between 1 and 2000 (got 0).")
        #expect(message("get_logs", logs.merging(["tail": 1.5]) { $1 }) == "Argument 'tail' must be a whole number (got 1.5).")
        #expect(message("get_logs", logs.merging(["tail": "lots"]) { $1 }) == "Argument 'tail' must be an integer (got \"lots\").")
        #expect(message("run_command", ["host": "web", "command": "ls", "reason": "r", "timeoutSec": 301]) ==
            "Argument 'timeoutSec' must be between 1 and 300 (got 301).")
        #expect(message("get_logs", logs.merging(["since": "31d"]) { $1 }) ==
            "Argument 'since' must be between 1 second and 30 days (got 2678400 seconds).")
        #expect(message("get_logs", logs.merging(["since": "1w"]) { $1 }) ==
            "Argument 'since' must be seconds or a number with s, m, h or d, like \"90\" or \"15m\" (got \"1w\").")
        #expect(message("run_command", ["host": "web", "command": .string(String(repeating: "a", count: 16_385)), "reason": "r"]) ==
            "Argument 'command' is 16385 bytes long; the limit is 16384.")
        #expect(message("run_command", ["host": "web", "command": "ls", "reason": .string(String(repeating: "r", count: 1001))]) ==
            "Argument 'reason' is 1001 characters long; the limit is 1000.")
    }

    @Test func namesMustBeSafe() {
        #expect(message("get_logs", ["host": "web", "kind": "container", "name": "api; rm -rf /"]) ==
            "Argument 'name' may only contain letters, digits, '.', '_' and '-' and must not start with '-' (got \"api; rm -rf /\").")
        #expect(message("get_logs", ["host": "web", "kind": "container", "name": "-v"])?.contains("must not start with '-'") == true)
        #expect(message("list_pods", ["host": "web", "namespace": "$(id)"])?.hasPrefix("Argument 'namespace' may only contain") == true)
        #expect(message("get_logs", ["host": "web", "kind": "container", "name": .string(String(repeating: "a", count: 254))]) ==
            "Argument 'name' is 254 bytes long; the limit is 253.")
    }

    @Test func requiredAndUnknownArguments() {
        #expect(message("get_host_metrics", [:]) == "Missing required argument 'host'.")
        #expect(message("get_host_metrics", ["host": "  "]) == "Argument 'host' must not be empty. Use a name or id from list_hosts.")
        #expect(message("get_host_metrics", ["host": 5]) == "Argument 'host' must be a string (got an integer).")
        #expect(message("get_logs", ["host": "web", "kind": "container"]) == "Missing required argument 'name'.")
        #expect(message("run_command", ["host": "web", "command": "ls"]) == "Missing required argument 'reason'.")
        #expect(message("run_command", ["host": "web", "command": "  ", "reason": "r"]) == "Argument 'command' must not be empty.")
        #expect(message("get_host_metrics", ["host": "web", "verbose": true]) ==
            "Unknown argument \"verbose\" for get_host_metrics. Allowed: host.")
        #expect(message("list_hosts", ["a": 1, "b": 2]) == "Unknown arguments \"a\", \"b\" for list_hosts. Allowed: tag.")
        // null counts as absent.
        #expect(message("list_containers", ["host": "web", "all": nil]) == nil)
        #expect(message("list_containers", ["host": "web", "all": "yes"]) == "Argument 'all' must be true or false (got \"yes\").")
        #expect(message("nope", [:]) == "Unknown tool 'nope'.")
    }

    @Test func kindSpecificArguments() {
        #expect(message("get_logs", ["host": "web", "kind": "vm", "name": "x"]) ==
            "Argument 'kind' must be \"container\" or \"pod\" (got \"vm\").")
        #expect(message("get_logs", ["host": "web", "kind": "container", "name": "x", "namespace": "y"]) ==
            "Argument 'namespace' only applies to kind \"pod\".")
        #expect(message("get_logs", ["host": "web", "kind": "container", "name": "x", "previous": true]) ==
            "Argument 'previous' only applies to kind \"pod\".")
    }

    @Test func controlAndInvisibleCharactersAreRejected() {
        #expect(message("run_command", ["host": "web", "command": "ls\u{0}", "reason": "r"]) ==
            "Argument 'command' must not contain NUL characters.")
        #expect(message("run_command", ["host": "web", "command": "ls\u{1B}[2J", "reason": "r"]) ==
            "Argument 'command' contains control character U+001B; only tab and newline are allowed.")
        #expect(message("run_command", ["host": "web", "command": "echo hi\r", "reason": "r"]) ==
            "Argument 'command' contains control character U+000D; only tab and newline are allowed.")
        #expect(message("run_command", ["host": "web", "command": "ls \u{202E}fdp.exe", "reason": "r"]) ==
            "Argument 'command' contains invisible or direction-changing character U+202E, which could hide what it says.")
        #expect(message("run_command", ["host": "web", "command": "ls", "reason": "line\nbreak"]) ==
            "Argument 'reason' contains control character U+000A; only tab is allowed.")
        #expect(message("get_host_metrics", ["host": "w\u{200B}eb"])?.contains("U+200B") == true)
        #expect(message("run_command", ["host": "web", "command": "printf '%s\\n' \"$HOME\"\tx", "reason": "r"]) == nil)
    }

    @Test func displayTextSanitizes() {
        #expect(DisplayText.sanitized("  claude\u{1B}[31m\ncode\u{202E} ") == "claude [31m code")
        #expect(DisplayText.sanitized(String(repeating: "a", count: 10), maxLength: 4) == "aaaa…")
    }
}
