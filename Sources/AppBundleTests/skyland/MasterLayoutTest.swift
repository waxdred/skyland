@testable import AppBundle
import Common
import XCTest

@MainActor
final class MasterLayoutTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testMasterShapeAndRatio() {
        let workspace = Workspace.get(byName: name).apply { wsp in
            wsp.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
        }
        applyMasterLayout(workspace, order: workspace.rootTilingContainer.allLeafWindowsRecursive)
        let root = workspace.rootTilingContainer
        assertEquals(root.orientation, .h)
        assertEquals(root.children.count, 2)
        assertEquals((root.children[0] as? Window)?.windowId, 1)
        let stack = root.children[1] as! TilingContainer
        assertEquals(stack.orientation, .v)
        assertEquals(stack.children.compactMap { ($0 as? Window)?.windowId }, [2, 3])
        let master = root.children[0].getWeight(.h), rest = stack.getWeight(.h)
        assertEquals(Int((master / (master + rest) * 100).rounded()), config.masterRatio)
    }

    func testCenterOrientation() {
        let saved = config.masterOrientation
        defer { config.masterOrientation = saved }
        config.masterOrientation = "center"
        let workspace = Workspace.get(byName: name).apply { wsp in
            wsp.rootTilingContainer.apply {
                for id in 1 ... 5 { TestWindow.new(id: UInt32(id), parent: $0) }
            }
        }
        applyMasterLayout(workspace, order: workspace.rootTilingContainer.allLeafWindowsRecursive)
        let ids: (TreeNode) -> [UInt32] = { node in node.allLeafWindowsRecursive.map(\.windowId) }
        let root = workspace.rootTilingContainer
        assertEquals(root.children.map(ids), [[3, 5], [1], [2, 4]]) // stack alternates right / left
        assertEquals(masterOrder(workspace).map(\.windowId), [1, 2, 3, 4, 5]) // order kept, master first
        applyMasterLayout(workspace) // already in shape: nothing moves
        assertEquals(root.children.map(ids), [[3, 5], [1], [2, 4]])
    }
}
