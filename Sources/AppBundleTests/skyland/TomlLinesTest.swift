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
}
