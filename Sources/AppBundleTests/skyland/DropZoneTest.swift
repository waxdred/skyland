@testable import AppBundle
import Common
import XCTest

@MainActor
final class DropZoneTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testDropSide() {
        let rect = Rect(topLeftX: 0, topLeftY: 0, width: 400, height: 200)
        assertEquals(dropSide(CGPoint(x: 20, y: 100), rect), .left)
        assertEquals(dropSide(CGPoint(x: 390, y: 100), rect), .right)
        assertEquals(dropSide(CGPoint(x: 200, y: 10), rect), .up)
        assertEquals(dropSide(CGPoint(x: 200, y: 190), rect), .down)
        assertEquals(dropSide(CGPoint(x: 200, y: 100), rect), nil) // the middle: a swap
    }

    func testInsertBesideWrapsTheTarget() {
        var a: Window!, b: Window!
        let root = Workspace.get(byName: name).rootTilingContainer
        root.apply {
            a = TestWindow.new(id: 1, parent: $0)
            b = TestWindow.new(id: 2, parent: $0)
        }
        // root is horizontal: dropping a under b makes [b / a] where b was
        insertBeside(a, b, .down)
        assertEquals(root.children.count, 1)
        let split = root.children[0] as! TilingContainer
        assertEquals(split.orientation, .v)
        assertEquals(split.children.map { ($0 as! Window).windowId }, [2, 1])
    }

    func testInsertBesideInTheSameSplit() {
        var a: Window!, c: Window!
        let root = Workspace.get(byName: name).rootTilingContainer
        root.apply {
            a = TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
            c = TestWindow.new(id: 3, parent: $0)
        }
        // root is horizontal: a to the left of c, in the same row
        insertBeside(a, c, .left)
        assertEquals(root.children.map { ($0 as! Window).windowId }, [2, 1, 3])
    }
}
