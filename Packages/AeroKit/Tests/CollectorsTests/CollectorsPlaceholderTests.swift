import Testing
@testable import Collectors

// Placeholder so the CollectorsTests target builds and links. Replace with real tests.
// Fixtures: `import AeroTestSupport`, then `try Fixtures.string("<path under dev/fixtures>")`.
@Test("Collectors links")
func moduleLinks() {
    #expect(CollectorsPlaceholder.moduleName == "Collectors")
}
