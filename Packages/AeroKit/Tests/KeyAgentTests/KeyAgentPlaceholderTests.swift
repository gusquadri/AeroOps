import Testing
@testable import KeyAgent

// Placeholder so the KeyAgentTests target builds and links. Replace with real tests.
// Fixtures: `import AeroTestSupport`, then `try Fixtures.string("<path under dev/fixtures>")`.
@Test("KeyAgent links")
func moduleLinks() {
    #expect(KeyAgentPlaceholder.moduleName == "KeyAgent")
}
