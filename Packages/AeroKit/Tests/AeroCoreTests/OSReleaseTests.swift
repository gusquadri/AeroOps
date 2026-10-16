import Foundation
import Testing
import AeroCore
import AeroTestSupport

@Suite("OSRelease and the @@os section")
struct OSReleaseTests {
    /// The `@@host` to `@@end` tail of real runs of the current script (2026-10-15): the Alpine dev
    /// servers, `debian:stable-slim` and `ubuntu:24.04` under Docker.
    static let alpine = """
        @@host
        Linux 7.2.9-orbstack-00391-g2b298d05fbd4 aarch64
        aeroops-alpine
        @@os
        NAME="Alpine Linux"
        ID=alpine
        VERSION_ID=3.24.2
        PRETTY_NAME="Alpine Linux v3.24"
        @@end

        """
    static let ubuntu = """
        @@os
        PRETTY_NAME="Ubuntu 24.04.5 LTS"
        NAME="Ubuntu"
        VERSION_ID="24.04"
        ID=ubuntu
        ID_LIKE=debian
        @@end

        """

    /// A fixture's output with `section` spliced in before `@@end`.
    private func fixture(_ name: String, with section: String) throws -> String {
        let full = try Fixtures.string("metrics/\(name).txt")
        return full.replacingOccurrences(of: "@@end\n", with: section)
    }

    @Test("Ubuntu: ID, ID_LIKE, quoted names and version reach the snapshot")
    func ubuntu() throws {
        let output = try fixture("ubuntu-vm-1", with: Self.ubuntu)
        let (snapshot, sample) = try #require(MetricsParser.parse(output).successPair)
        let os = try #require(snapshot.os)
        #expect(os == OSRelease(id: "ubuntu", idLike: ["debian"], name: "Ubuntu", prettyName: "Ubuntu 24.04.5 LTS", versionID: "24.04"))
        #expect(sample.os == os)
        #expect(os.displayName == "Ubuntu 24.04.5 LTS")
    }

    @Test("Alpine (BusyBox): bare and quoted values")
    func alpine() throws {
        let output = try fixture("alpine-busybox-1", with: "")
            .replacingOccurrences(of: "@@host\n", with: "@@unused\n")
            + Self.alpine
        let (snapshot, _) = try #require(MetricsParser.parse(output).successPair)
        #expect(snapshot.os?.id == "alpine")
        #expect(snapshot.os?.idLike == [])
        #expect(snapshot.os?.prettyName == "Alpine Linux v3.24")
        #expect(snapshot.os?.versionID == "3.24.2")
        #expect(snapshot.hostname == "aeroops-alpine")
    }

    @Test("Captures from before @@os, and an empty @@os (macOS), have no os")
    func absent() throws {
        for name in ["ubuntu-vm-1", "debian-1", "devcontainer-1", "alpine-busybox-1"] {
            #expect(try #require(MetricsParser.parse(try Fixtures.string("metrics/\(name).txt")).snapshot).os == nil)
        }
        let darwin = try fixture("nonlinux-darwin", with: "@@os\n@@end\n")
        guard case .unsupportedOS(let sample) = MetricsParser.parse(darwin) else {
            Issue.record("expected unsupportedOS")
            return
        }
        #expect(sample.os == nil)
        #expect(sample.kernel == "Darwin 27.0.0 arm64")
    }

    @Test("Rocky Linux: ID_LIKE is split and lower-cased; ID is lower-cased")
    func idLike() throws {
        let os = try #require(OSRelease(lines: ["ID=\"Rocky\"", "ID_LIKE=\"rhel  CentOS\tfedora\""]))
        #expect(os.id == "rocky")
        #expect(os.idLike == ["rhel", "centos", "fedora"])
        #expect(os.displayName == "rocky")
    }

    @Test("Quoting: single quotes, escapes, unterminated quotes, comments and repeats")
    func quoting() throws {
        let os = try #require(OSRelease(lines: [
            "# a comment",
            "NAME='Arch Linux'",
            #"PRETTY_NAME="Say \"hi\" \$HOME \\ \q""#,
            "ID=arch",
            "ID=ubuntu",
            "VERSION_ID=\"1.0",
            "junk line",
        ]))
        #expect(os.name == "Arch Linux")
        #expect(os.prettyName == #"Say "hi" $HOME \ \q"#)
        #expect(os.id == "arch")
        #expect(os.versionID == nil)
    }

    @Test("NAME and VERSION_ID make the display name without PRETTY_NAME")
    func displayName() {
        #expect(OSRelease(name: "Debian GNU/Linux", versionID: "13").displayName == "Debian GNU/Linux 13")
        #expect(OSRelease(name: "NixOS").displayName == "NixOS")
        #expect(OSRelease().displayName == nil)
    }

    @Test("Nothing useful is nil; snapshots without os decode from old JSON")
    func emptyAndCodable() throws {
        #expect(OSRelease(lines: [String]()) == nil)
        #expect(OSRelease(lines: ["ID=", "OTHER=1"]) == nil)
        let output = try fixture("ubuntu-vm-1", with: Self.ubuntu)
        let snapshot = try #require(MetricsParser.parse(output).snapshot)
        let decoded = try JSONDecoder().decode(MetricsSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
    }
}
