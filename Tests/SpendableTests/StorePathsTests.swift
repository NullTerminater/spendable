import Foundation
import Testing
@testable import Spendable

@Suite("StorePaths")
struct StorePathsTests {
    @Test("file names are fixed and live inside the container")
    func fileNames() throws {
        let paths = try StorePaths.temporary()
        #expect(paths.databaseURL.lastPathComponent == "spendable.sqlite")
        #expect(paths.widgetSummaryURL.lastPathComponent == "widget-summary.json")
        #expect(paths.databaseURL.deletingLastPathComponent() == paths.containerURL)
        #expect(paths.widgetSummaryURL.deletingLastPathComponent() == paths.containerURL)
    }

    @Test("a temporary container is never inside the repository")
    func temporaryIsOutsideRepo() throws {
        let paths = try StorePaths.temporary()
        #expect(!paths.containerURL.path.contains("/Developer/spendable/"))
        #expect(paths.containerURL.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: paths.containerURL.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test("the live container is the App Group container of the signed host app")
    func liveIsAppGroup() throws {
        let paths = try StorePaths.live()
        #expect(paths.containerURL.path.contains("Group Containers/UW2KV7XB66.spendable"))
    }

    @Test("identifiers never change")
    func identifiers() {
        #expect(StorePaths.groupIdentifier == "UW2KV7XB66.spendable")
        #expect(StorePaths.bundleIdentifier == "com.nullterminater.spendable")
        #expect(StorePaths.keychainService == "com.nullterminater.spendable.simplefin")
    }
}
