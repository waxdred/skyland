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

final class WorkspaceSlideTest: XCTestCase {
    func testDirectionFollowsWorkspaceOrder() {
        assertEquals(workspaceSlideSign(from: "1", to: "2"), 1) // higher: comes from below
        assertEquals(workspaceSlideSign(from: "2", to: "1"), -1)
        assertEquals(workspaceSlideSign(from: "9", to: "10"), 1) // numeric, not "10" < "9"
        assertEquals(workspaceSlideSign(from: "A", to: "B"), 1)
        assertEquals(workspaceSlideSign(from: "B", to: "A"), -1)
    }
}

final class MouseModifierTest: XCTestCase {
    func testParse() {
        assertEquals(parseMouseModifier("alt"), .maskAlternate)
        assertEquals(parseMouseModifier("ctrl-alt"), [.maskControl, .maskAlternate])
        assertEquals(parseMouseModifier(""), nil)
        assertEquals(parseMouseModifier("hyper"), nil)
    }

    @MainActor
    func testConfig() {
        assertEquals(parseConfig("mouse-modifier = 'alt'").config.mouseModifier, "alt")
        assertEquals(parseConfig("mouse-modifier = 'super'").errors.count, 1)
    }
}

final class InputSourceKeysTest: XCTestCase {
    func testEveryLetterHasAKeyInTheActiveLayout() {
        let keys = inputSourceLetterKeys()
        assertEquals(keys.count, 26)
        assertEquals(Set(keys.values.map(\.carbonKeyCode)).count, 26) // one physical key per letter
    }

    @MainActor
    func testPreset() {
        let result = parseConfig("key-mapping.preset = 'input-source'")
        assertEquals(result.errors, [])
        assertEquals(result.config.keyMapping.followsInputSource, true)
    }
}

final class ArrowKeysTest: XCTestCase {
    func testHiddenArrowModifiersAreIgnored() {
        // cmd-up as the keyboard sends it: command + function + numeric pad
        assertEquals(modifierFlags([.maskCommand, .maskSecondaryFn, .maskNumericPad]), .command)
        assertEquals(modifierFlags([.maskAlternate, .maskShift, .maskAlphaShift]), [.option, .shift])
        assertEquals(isArrowKey(.upArrow), true)
        assertEquals(isArrowKey(.m), false)
    }
}

final class BarHeightTest: XCTestCase {
    func testOverlap() {
        assertEquals(barOverlap(barHeight: 32, menuBarHeight: 32), 0) // notched built-in display
        assertEquals(barOverlap(barHeight: 32, menuBarHeight: 24), 8) // external display
        assertEquals(barOverlap(barHeight: 32, menuBarHeight: 0), 32) // auto-hidden menu bar
        assertEquals(barOverlap(barHeight: 0, menuBarHeight: 24), 0) // option off
    }
}

final class FloatingCenterTest: XCTestCase {
    func testCenteredRect() {
        let r = centeredRect(in: Rect(topLeftX: 0, topLeftY: 32, width: 1000, height: 600), percent: 70)
        assertEquals([r.topLeftX, r.topLeftY, r.width, r.height], [150, 122, 700, 420])
    }

    @MainActor
    func testParse() {
        assertEquals(parseConfig("floating-center-percent = 70").config.floatingCenterPercent, 70)
        assertEquals(parseConfig("").config.floatingCenterPercent, 0)
    }
}
