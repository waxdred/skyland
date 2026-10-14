@testable import AppBundle
import Common
import XCTest

@MainActor
final class DwindleTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testNewWindowSplitsFocusedWindow() async throws {
        config.dwindle = true
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        assertEquals(TestWindow.new(id: 2, parent: root).focusWindow(), true)

        let w3 = TestWindow.new(id: 3, parent: root)
        try await w3.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .window(1),
            .v_tiles([.window(2), .window(3)]),
        ]))

        assertEquals(w3.focusWindow(), true)
        let w4 = TestWindow.new(id: 4, parent: root)
        try await w4.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .window(1),
            .v_tiles([.window(2), .h_tiles([.window(3), .window(4)])]),
        ]))
    }
}
