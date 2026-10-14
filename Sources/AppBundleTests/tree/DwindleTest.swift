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

    func testSmartSplitFollowsCursor() {
        let rect = Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 600)
        assertEquals(dwindleSplit(rect, mouse: nil, fallback: .v) == (.h, false), true) // longest side
        assertEquals(dwindleSplit(rect, mouse: CGPoint(x: 50, y: 300), fallback: .v) == (.h, true), true) // left
        assertEquals(dwindleSplit(rect, mouse: CGPoint(x: 750, y: 300), fallback: .v) == (.h, false), true) // right
        assertEquals(dwindleSplit(rect, mouse: CGPoint(x: 400, y: 40), fallback: .v) == (.v, true), true) // top
        assertEquals(dwindleSplit(rect, mouse: CGPoint(x: 400, y: 560), fallback: .v) == (.v, false), true) // bottom
        assertEquals(dwindleSplit(rect, mouse: CGPoint(x: 900, y: 300), fallback: .v) == (.h, false), true) // outside
        assertEquals(dwindleSplit(nil, mouse: nil, fallback: .v) == (.v, false), true)
    }
}
