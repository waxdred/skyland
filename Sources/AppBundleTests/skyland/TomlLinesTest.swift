@testable import AppBundle
import XCTest

final class TomlLinesTest: XCTestCase {
    let config = """
        gaps.inner.horizontal = 4 # 43PR gaps_in
        mouse-modifier = 'alt'

        [decoration]
        rounding = 8
        inactive-opacity = 85 # dimmed

        [[on-window-detected]]
        run = 'layout floating'
        """

    func testRead() {
        assertEquals(tomlValue(config, section: "", key: "gaps.inner.horizontal"), "4")
        assertEquals(tomlValue(config, section: "", key: "mouse-modifier"), "'alt'")
        assertEquals(tomlValue(config, section: "decoration", key: "inactive-opacity"), "85")
        assertEquals(tomlValue(config, section: "decoration", key: "rounding-x"), nil)
        assertEquals(tomlValue(config, section: "", key: "rounding"), nil)
    }

    func testReplaceKeepsComment() {
        let result = tomlSet(config, section: "decoration", key: "inactive-opacity", value: "70")
        assertEquals(tomlValue(result, section: "decoration", key: "inactive-opacity"), "70")
        XCTAssertTrue(result.contains("inactive-opacity = 70 # dimmed"))
        assertEquals(result.split(separator: "\n").count, config.split(separator: "\n").count)
    }

    func testInsertMissingKey() {
        let top = tomlSet(config, section: "", key: "bar-height", value: "32")
        assertEquals(tomlValue(top, section: "", key: "bar-height"), "32")
        let inSection = tomlSet(config, section: "decoration", key: "blur", value: "5")
        assertEquals(tomlValue(inSection, section: "decoration", key: "blur"), "5")
        XCTAssertTrue(inSection.contains("inactive-opacity = 85 # dimmed\nblur = 5"))
        let newSection = tomlSet(config, section: "media", key: "opacity", value: "90")
        assertEquals(tomlValue(newSection, section: "media", key: "opacity"), "90")
    }

    func testEntriesReplaceRemove() {
        let bindings = """
            [mode.main.binding]
            alt-t = 'exec-and-forget open -a "Ghost#ty"' # terminal
            cmd-1 = ['workspace 1', 'mode main']
            """
        assertEquals(tomlEntries(bindings, section: "mode.main.binding"), [
            TomlEntry(key: "alt-t", value: "'exec-and-forget open -a \"Ghost#ty\"'", comment: "terminal"),
            TomlEntry(key: "cmd-1", value: "['workspace 1', 'mode main']", comment: ""),
        ])
        let renamed = tomlReplace(bindings, section: "mode.main.binding", key: "alt-t",
                                  with: TomlEntry(key: "alt-enter", value: "'close'", comment: "new"))
        XCTAssertTrue(renamed.contains("alt-enter = 'close' # new"))
        assertEquals(tomlValue(renamed, section: "mode.main.binding", key: "alt-t"), nil)
        let removed = tomlReplace(bindings, section: "mode.main.binding", key: "cmd-1", with: nil)
        assertEquals(tomlEntries(removed, section: "mode.main.binding").map(\.key), ["alt-t"])
    }

    func testBlocks() {
        let rules = """
            a = 1

            [[on-window-detected]]
            if.app-id = 'com.apple.calculator' # Calculator
            run = 'layout floating'

            [[on-window-detected]]
            if.app-id = 'com.hnc.Discord'
            run = 'move-node-to-workspace 8'

            [mode.main.binding]
            alt-q = 'close'
            """
        let blocks = tomlBlocks(rules, name: "on-window-detected")
        assertEquals(blocks.map(\.lines), [2 ..< 5, 6 ..< 9])
        assertEquals(blocks[0].entries.first, TomlEntry(key: "if.app-id", value: "'com.apple.calculator'", comment: "Calculator"))
        let removed = tomlReplaceBlock(rules, name: "on-window-detected", blocks[0], with: [])
        assertEquals(tomlBlocks(removed, name: "on-window-detected").count, 1)
        XCTAssertFalse(removed.contains("calculator"))
        let added = tomlReplaceBlock(rules, name: "on-window-detected", nil, with: ["[[on-window-detected]]", "if.app-id = 'x'", "run = 'layout floating'"])
        assertEquals(tomlBlocks(added, name: "on-window-detected").count, 3)
        assertEquals(tomlValue(added, section: "mode.main.binding", key: "alt-q"), "'close'")
    }

    @MainActor func testMonitorAssignment() {
        assertEquals(monitorAssignmentValue(1), "1")
        assertEquals(monitorAssignmentValue(3), "[3, 2, 1]")
        let text = """
            [workspace-to-monitor-force-assignment]
            1 = 1
            5 = [2, 1] # the external screen

            [mode.main.binding]
            alt-q = 'close'
            """
        let section = "workspace-to-monitor-force-assignment"
        let moved = tomlSet(text, section: section, key: "5", value: monitorAssignmentValue(1))
        assertEquals(tomlValue(moved, section: section, key: "5"), "1")
        assertTrue(moved.contains("5 = 1 # the external screen"))
        let added = tomlSet(text, section: section, key: "7", value: monitorAssignmentValue(2))
        assertEquals(tomlEntries(added, section: section).map(\.key), ["1", "5", "7"])
        assertEquals(tomlValue(added, section: section, key: "7"), "[2, 1]")
        let removed = tomlReplace(text, section: section, key: "5", with: nil)
        assertEquals(tomlEntries(removed, section: section).map(\.key), ["1"])
        assertEquals(tomlValue(removed, section: "mode.main.binding", key: "alt-q"), "'close'")
        assertTrue(parseConfig(added).errors.isEmpty)
    }
}
