@testable import AppBundle
import Common
import XCTest

@MainActor
final class GroupRenameCommandTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        groupNames = [:]
    }

    func testRenameNamesTheFocusedWindowsGroup() async {
        var group: TilingContainer!
        Workspace.get(byName: name).rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            group = TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                $0.layout = .accordion
                assertEquals(TestWindow.new(id: 2, parent: $0).focusWindow(), true)
                TestWindow.new(id: 3, parent: $0)
            }
        }
        // the rest of the line is the name, no quotes needed
        let result = await parseCommand("group-rename work  stuff").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(groupNames[ObjectIdentifier(group)], "work stuff")
    }

    func testRenameOutsideAGroupFails() async {
        Workspace.get(byName: name).rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
        }
        let result = await parseCommand("group-rename nope").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(groupNames.isEmpty, true)
    }
}
