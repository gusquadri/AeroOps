import Foundation
import Testing
import AeroTestSupport

@Suite("Fixtures helper")
struct FixturesTests {
    @Test("finds the repo root and dev/fixtures")
    func locatesRepo() throws {
        let root = try Fixtures.repoRoot()
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "project.yml").path))
        #expect(try Fixtures.directory().lastPathComponent == "fixtures")
    }

    @Test("missing fixture throws a descriptive error")
    func missingFixture() {
        #expect(throws: Fixtures.FixtureError.self) { try Fixtures.data("does/not/exist.txt") }
    }
}
