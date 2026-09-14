import Testing
@testable import Spendable

@Suite("Project skeleton")
struct SmokeTests {
    @Test("the test target links the app module")
    func linksApp() {
        #expect(StorePaths.groupIdentifier == "UW2KV7XB66.spendable")
        #expect(StorePaths.bundleIdentifier == "com.nullterminater.spendable")
    }
}
