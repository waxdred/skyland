@testable import AppBundle
import Common
import XCTest

@MainActor
final class GroupRenameCommandTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        namedGroups = []
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

    /// The case that gave two groups the same name: a group made around a named one.
    func testNestedGroupsKeepTheirOwnNames() async {
        var inner: TilingContainer!, outer: TilingContainer!
        outer = Workspace.get(byName: name).rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            inner = TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                $0.layout = .accordion
                assertEquals(TestWindow.new(id: 2, parent: $0).focusWindow(), true)
                TestWindow.new(id: 3, parent: $0)
            }
        }
        _ = await parseCommand("group-rename Tester").cmdOrDie.run(.defaultEnv, .emptyStdin)
        outer.layout = .accordion
        assertEquals(TestWindow.get(byId: 1)?.focusWindow(), true)
        _ = await parseCommand("group-rename Claude").cmdOrDie.run(.defaultEnv, .emptyStdin)
        refreshGroupNames()
        assertEquals(groupNames[ObjectIdentifier(inner)], "Tester")
        assertEquals(groupNames[ObjectIdentifier(outer)], "Claude")
    }

    func testNamesGoToTheGroupWithTheirWindows() {
        // disjoint groups, swapped order
        assertEquals(matchGroupNames([[1, 2], [3, 4]], [[3, 4], [1, 2]]), [1, 0])
        // an inner group {2, 3} inside an outer one {1, 2, 3}: each name keeps its own
        assertEquals(matchGroupNames([[2, 3], [1, 2, 3]], [[1, 2, 3], [2, 3]]), [1, 0])
        // a window added to the group: still its name; a group gone: no group for its name
        assertEquals(matchGroupNames([[1, 2], [7, 8]], [[1, 2, 5]]), [0, nil])
        // two names for one group: the closest one gets it
        assertEquals(matchGroupNames([[1], [1, 2]], [[1, 2]]), [nil, 0])
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
