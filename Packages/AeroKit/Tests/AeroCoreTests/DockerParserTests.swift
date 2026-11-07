import Foundation
import Testing
import AeroCore
import AeroTestSupport

@Suite("DockerParser")
struct DockerParserTests {
    /// 2026-10-11T00:00:00Z.
    private let day = 1_791_676_800.0

    private let exitedID = "15e8ff998cfdffc93b3bc28073104f4c3dd524b2f98622066598b7ed70d24924"
    private let loggerID = "373621db2af74d2d1130df7f6b7957bd8c26c788392222f98260675d9e622f7a"
    private let webID = "5eff53560ba43d389541a4287ab1bd43a3123ef3a2f1e630909bd3356a8229a4"

    private func fixtureContainers() throws -> [ContainerInfo] {
        try DockerParser.parseContainers(ps: try Fixtures.string("docker/ps-a.jsonl"),
                                         stats: try Fixtures.string("docker/stats.jsonl"))
    }

    @Test("ps -a merged with stats: every field of the three demo containers")
    func psAndStats() throws {
        let rows = try fixtureContainers()
        #expect(rows.map(\.name) == ["demo-exited", "demo-logger", "demo-web"])
        expectExited(rows[0])
        expectLogger(rows[1])
        expectWeb(rows[2])
    }

    private func expectExited(_ exited: ContainerInfo) {
        #expect(exited.id == exitedID)
        #expect(exited.image == "alpine:3.22")
        #expect(exited.state == .exited)
        #expect(exited.status == "Exited (3) 7 minutes ago")
        #expect(exited.exitCode == 3)
        #expect(exited.cpuPercent == nil)
        #expect(exited.memUsedBytes == nil)
        #expect(exited.memLimitBytes == nil)
        #expect(exited.ports == nil)
        #expect(exited.runningFor == "7 minutes ago")
        #expect(exited.restartCount == nil)
        #expect(exited.createdAt == Date(timeIntervalSince1970: day + 6 * 3600 + 55 * 60 + 30))
        #expect(exited.health == .failing)
    }

    private func expectLogger(_ logger: ContainerInfo) {
        #expect(logger.id == loggerID)
        #expect(logger.image == "busybox:1.36")
        #expect(logger.state == .running)
        #expect(logger.status == "Up 7 minutes")
        #expect(logger.healthCheck == nil)
        #expect(logger.cpuPercent == 0.03)
        #expect(logger.memUsedBytes == 208_896)
        #expect(logger.memLimitBytes == 3_125_662_450)
        #expect(logger.createdAt == Date(timeIntervalSince1970: day + 6 * 3600 + 55 * 60 + 29))
        #expect(logger.health == .healthy)
    }

    private func expectWeb(_ web: ContainerInfo) {
        #expect(web.id == webID)
        #expect(web.image == "nginx:1.27-alpine")
        #expect(web.status == "Up 7 minutes (healthy)")
        #expect(web.healthCheck == .healthy)
        #expect(web.cpuPercent == 0)
        #expect(web.memUsedBytes == 9_699_328)
        #expect(web.memLimitBytes == 3_125_662_450)
        #expect(web.ports == "0.0.0.0:8080->80/tcp, [::]:8080->80/tcp")
        #expect(web.createdAt == Date(timeIntervalSince1970: day + 6 * 3600 + 55 * 60 + 27))
        #expect(web.health == .healthy)
        #expect(web.age(now: Date(timeIntervalSince1970: day + 7 * 3600 + 2 * 60 + 27)) == "7m")
    }

    @Test("ps via sudo is the same output")
    func psViaSudo() throws {
        let direct = try DockerParser.parseContainers(ps: try Fixtures.string("docker/ps-a.jsonl"))
        let sudo = try DockerParser.parseContainers(ps: try Fixtures.string("docker/ps-a-via-sudo.jsonl"))
        #expect(direct == sudo)
        #expect(direct.count == 3)
    }

    @Test("stats rows")
    func stats() throws {
        let stats = DockerParser.parseStats(try Fixtures.string("docker/stats.jsonl"))
        #expect(stats == [
            DockerStats(containerID: loggerID, shortID: "373621db2af7", name: "demo-logger", cpuPercent: 0.03,
                        memUsedBytes: 208_896, memLimitBytes: 3_125_662_450),
            DockerStats(containerID: webID, shortID: "5eff53560ba4", name: "demo-web", cpuPercent: 0,
                        memUsedBytes: 9_699_328, memLimitBytes: 3_125_662_450),
        ])
    }

    @Test("stats match by name or short ID when the full ID is absent")
    func statsFallbackMatching() throws {
        let ps = try Fixtures.string("docker/ps-a.jsonl")
        let byName = try DockerParser.parseContainers(
            ps: ps, stats: #"{"Name":"demo-web","CPUPerc":"12.5%","MemUsage":"1MiB / 2MiB"}"#)
        #expect(byName[2].cpuPercent == 12.5)
        #expect(byName[2].memUsedBytes == 1_048_576)
        #expect(byName[2].memLimitBytes == 2_097_152)
        #expect(byName[1].cpuPercent == nil)

        let byShortID = try DockerParser.parseContainers(
            ps: ps, stats: #"{"ID":"373621db2af7","CPUPerc":"150.25%","MemUsage":"-- / --"}"#)
        #expect(byShortID[1].cpuPercent == 150.25)
        #expect(byShortID[1].memUsedBytes == nil)
        #expect(byShortID[1].memLimitBytes == nil)
    }

    @Test("inspect summary for demo-web")
    func inspect() throws {
        let summaries = DockerParser.parseInspect(try Fixtures.data("docker/inspect-demo-web.json"))
        #expect(summaries.count == 1)
        let web = try #require(summaries.first)
        #expect(web.id == webID)
        #expect(web.name == "demo-web")
        #expect(web.image == "nginx:1.27-alpine")
        #expect(web.restartCount == 0)
        #expect(web.healthCheck == .healthy)
        #expect(web.exitCode == 0)
        let started = try #require(web.startedAt)
        #expect(abs(started.timeIntervalSince1970 - (day + 6 * 3600 + 55 * 60 + 29.352732321)) < 1e-5)
        #expect(web.finishedAt == nil)
        #expect(web.restartPolicy == "unless-stopped")
        #expect(web.ports == ["0.0.0.0:8080->80/tcp", "[::]:8080->80/tcp"])
    }

    @Test("inspect: unpublished ports, numeric port order, junk")
    func inspectVariants() {
        let json = #"""
        [{"Id":"abc","Name":"/x","State":{"ExitCode":137,"FinishedAt":"2026-10-11T07:00:00Z","Health":null},
          "HostConfig":{"RestartPolicy":{"Name":"no"}},
          "NetworkSettings":{"Ports":{"8080/tcp":null,"443/tcp":[{"HostIp":"","HostPort":"8443"}],"53/udp":[]}}},
         {"Name":"/no-id"}, 42, null]
        """#
        let summaries = DockerParser.parseInspect(Data(json.utf8))
        #expect(summaries.count == 1)
        #expect(summaries.first?.ports == ["53/udp", "8443->443/tcp", "8080/tcp"])
        #expect(summaries.first?.restartPolicy == nil)
        #expect(summaries.first?.exitCode == 137)
        #expect(summaries.first?.healthCheck == nil)
        #expect(summaries.first?.finishedAt == Date(timeIntervalSince1970: day + 7 * 3600))
        #expect(DockerParser.parseInspect(Data("Error: No such object: nope".utf8)).isEmpty)
        #expect(DockerParser.parseInspect(Data()).isEmpty)
    }

    @Test("permission denied fixture is a typed error with a hint")
    func permissionDenied() throws {
        let text = try Fixtures.string("docker/error-permission-denied.txt")
        let error = DockerError.classify(text)
        #expect(error == .permissionDenied(socket: "unix:///var/run/docker.sock"))
        #expect(error.hint?.contains("docker group") == true)
        #expect(error.hint?.contains("sudo -n") == true)
        #expect(error.errorDescription == "Permission denied on the Docker socket (unix:///var/run/docker.sock).")

        #expect(throws: DockerError.permissionDenied(socket: "unix:///var/run/docker.sock")) {
            try DockerParser.parseContainers(ps: text)
        }
    }

    @Test("other docker errors")
    func otherErrors() {
        #expect(DockerError.classify("sudo: a password is required\n[exit status 1]") == .sudoRefused)
        #expect(DockerError.classify(
            "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?")
            == .daemonNotRunning)
        #expect(DockerError.classify("sh: docker: not found\n[exit status 127]") == .notInstalled)
        #expect(DockerError.classify("bash: line 1: docker: command not found") == .notInstalled)
        #expect(DockerError.classify("Error response from daemon: boom\n[exit status 1]")
            == .failed(message: "Error response from daemon: boom"))
        #expect(DockerError.classify("").errorDescription == "The docker command failed.")
        #expect(DockerError.sudoRefused.hint?.contains("NOPASSWD") == true)
        #expect(DockerError.failed(message: "x").hint == nil)
    }

    @Test("hints name the host editor's docker sudo toggle exactly")
    func hintsNameTheToggle() {
        let toggle = "\"Run docker with sudo -n\""
        #expect(DockerError.permissionDenied(socket: nil).hint?.contains(toggle) == true)
        #expect(DockerError.sudoRefused.hint?.contains(toggle) == true)
        #expect(DockerError.permissionDenied(socket: nil).hint?.contains("Use sudo -n for Docker") == false)
    }

    @Test("empty ps output is no containers, not an error")
    func emptyPS() throws {
        #expect(try DockerParser.parseContainers(ps: "").isEmpty)
        #expect(try DockerParser.parseContainers(ps: "\n  \n").isEmpty)
    }

    @Test("junk lines between JSON rows are skipped")
    func junkLines() throws {
        let ps = "WARNING: something\n" + (try Fixtures.string("docker/ps-a.jsonl")) + "\n{not json}\n[1,2]\n{}\n"
        #expect(try DockerParser.parseContainers(ps: ps).count == 3)
    }

    @Test("old Docker without State: derived from Status; names cleaned")
    func stateFromStatus() throws {
        let ps = """
        {"ID":"a1","Names":"/one,other/alias","Status":"Up 2 hours (Paused)"}
        {"ID":"a2","Names":"two","Status":"Restarting (1) 5 seconds ago"}
        {"ID":"a3","Status":"Created"}
        {"Names":"four","Status":"Removal In Progress"}
        {"ID":"a5","Names":"five","Status":"Dead"}
        {"ID":"a6","Names":"six","Status":"Up 1 second (health: starting)","State":"running"}
        {"ID":"a7","Names":"seven","Status":"Up 3 days (unhealthy)","State":"running"}
        {"ID":"a8","Names":"eight","Status":"Exited (0) 1 hour ago","State":"exited","CreatedAt":"garbage"}
        {"ID":"a9","Names":"nine","Status":"???","State":"weird"}
        {"Image":"no-id-or-name"}
        """
        let rows = try DockerParser.parseContainers(ps: ps)
        #expect(rows.map(\.name) == ["one", "two", "a3", "four", "five", "six", "seven", "eight", "nine"])
        #expect(rows.map(\.state) == [.paused, .restarting, .created, .removing, .dead, .running, .running, .exited, .unknown])
        #expect(rows[3].id == "four")
        #expect(rows.map(\.health) == [.warning, .failing, .inactive, .warning, .failing, .warning, .failing, .inactive, .inactive])
        #expect(rows[5].healthCheck == .starting)
        #expect(rows[6].healthCheck == .unhealthy)
        #expect(rows[7].exitCode == 0)
        #expect(rows[7].createdAt == nil)
        #expect(rows[7].age() == nil)
    }

    @Test("byte sizes and percentages")
    func sizes() {
        #expect(DockerParser.parseByteSize("204KiB") == 208_896)
        #expect(DockerParser.parseByteSize("9.25MiB") == 9_699_328)
        #expect(DockerParser.parseByteSize("2.911GiB") == 3_125_662_450)
        #expect(DockerParser.parseByteSize("1TiB") == 1_099_511_627_776)
        #expect(DockerParser.parseByteSize("14.7MB") == 14_700_000)
        #expect(DockerParser.parseByteSize("8.19kB") == 8_190)
        #expect(DockerParser.parseByteSize("0B") == 0)
        #expect(DockerParser.parseByteSize(" 126B ") == 126)
        #expect(DockerParser.parseByteSize("--") == nil)
        #expect(DockerParser.parseByteSize("12") == nil)
        #expect(DockerParser.parseByteSize("-1MiB") == nil)
        #expect(DockerParser.parseByteSize("1QiB") == nil)
        #expect(DockerParser.parseByteSize("1e300GiB") == nil)
        #expect(DockerParser.parseByteSize("nanGiB") == nil)
        #expect(DockerParser.parsePercent("0.03%") == 0.03)
        #expect(DockerParser.parsePercent("250.5%") == 250.5)
        #expect(DockerParser.parsePercent("--") == nil)
        #expect(DockerParser.parsePercent("-5%") == nil)
        #expect(DockerParser.parsePercent("inf%") == nil)
    }
}
