@testable import AppBundle
import Common
import SkylandAnimation
import XCTest

@MainActor
final class AnimationPresetConfigTest: XCTestCase {
    private func load(_ toml: String) -> [ConfigParseDiagnostic] {
        let result = parseConfig("[animations]\nenabled = true\n" + toml)
        config = result.config
        return result.errors
    }

    func testOnePreset() {
        assertEquals(load("preset = 'gnome'").count, 0)
        assertEquals(windowAnimator.settings.resolve(.windowsIn).style, .gnomed)
        assertEquals(windowAnimator.settings.resolve(.workspacesIn).style, .slideFade(percent: 20, vertical: false))
    }

    func testStackedPresetsLaterWinsNodeByNode() {
        assertEquals(load("preset = ['cyberspace', 'gnome']").count, 0)
        assertEquals(windowAnimator.settings.resolve(.windowsIn).style, .gnomed) // gnome sets windows
        assertEquals(windowAnimator.settings.resolve(.windowsOut).style, .cyberspace) // gnome leaves windowsOut to cyberspace
        assertEquals(windowAnimator.settings.resolve(.workspacesIn).style, .slideFade(percent: 20, vertical: false))
    }

    func testLinesOverPresets() {
        assertEquals(load("preset = ['gnome']\nanimation = ['workspaces, 1, 6, default, slidefade 40%']").count, 0)
        assertEquals(windowAnimator.settings.resolve(.workspacesOut).style, .slideFade(percent: 40, vertical: false))
        assertEquals(windowAnimator.settings.resolve(.windowsIn).style, .gnomed)
    }

    func testUnknownPreset() {
        assertEquals(load("preset = ['gnome', 'nope']").count, 1)
    }

    override func tearDown() {
        config = defaultConfig
    }
}
