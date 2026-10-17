@testable import SkylandAnimation
import XCTest

private let monitor = AnimRect(x: 0, y: 0, width: 1600, height: 1000)
private let tile = AnimRect(x: 100, y: 80, width: 700, height: 500)

private func context(_ rect: AnimRect = tile, id: UInt32 = 4242, direction: Double = 1, neighbours: Set<SlideEdge> = []) -> WindowContext {
    WindowContext(windowId: id, rect: rect, monitor: monitor, direction: direction, opacity: 0.9, brightness: 0, neighbourEdges: neighbours)
}

/// One style for every event, like `skyland-anim <style>`
private func settings(_ style: String) -> AnimationSettings {
    let parsed = AnimationSettings.parse(bezier: ["overshot, 0.05, 0.9, 0.1, 1.05"], animation: [
        "windows, 1, 5, overshot, \(style)",
        "windowsMove, 1, 4, overshot",
        "fade, 1, 3.5, default",
        "workspaces, 1, 6, default, \(style)",
        "specialWorkspace, 1, 5, overshot, \(style)",
    ])
    XCTAssertEqual(parsed.diagnostics, [])
    return parsed.settings
}

private func assertRect(_ actual: AnimRect, _ expected: AnimRect, file: StaticString = #filePath, line: UInt = #line) {
    for (a, e) in [(actual.x, expected.x), (actual.y, expected.y), (actual.width, expected.width), (actual.height, expected.height)] {
        XCTAssertEqual(a, e, accuracy: 1e-9, "\(actual) is not \(expected)", file: file, line: line)
    }
}

/// The animation block of Hyprland's own default hyprland.conf
private let hyprlandConf = """
    animations {
        enabled = yes, please :)

        # Default animations, see https://wiki.hyprland.org/Configuring/Animations/ for more
        bezier = easeOutQuint,0.23,1,0.32,1
        bezier = easeInOutCubic,0.65,0.05,0.36,1
        bezier = linear,0,0,1,1
        bezier = almostLinear,0.5,0.5,0.75,1.0
        bezier = quick,0.15,0,0.1,1

        animation = global, 1, 10, default
        animation = border, 1, 5.39, easeOutQuint
        animation = windows, 1, 4.79, easeOutQuint
        animation = windowsIn, 1, 4.1, easeOutQuint, popin 87%
        animation = windowsOut, 1, 1.49, linear, popin 87%
        animation = fadeIn, 1, 1.73, almostLinear
        animation = fadeOut, 1, 1.46, almostLinear
        animation = fade, 1, 3.03, quick
        animation = layers, 1, 3.81, easeOutQuint
        animation = layersIn, 1, 4, easeOutQuint, fade
        animation = layersOut, 1, 1.5, linear, fade
        animation = fadeLayersIn, 1, 1.79, almostLinear
        animation = fadeLayersOut, 1, 1.39, almostLinear
        animation = workspaces, 1, 1.94, almostLinear, fade
        animation = workspacesIn, 1, 1.21, almostLinear, fade
        animation = workspacesOut, 1, 1.94, almostLinear, fade
    }

    decoration {
        blur {
            enabled = false
        }
    }
    """

final class CubicBezierTest: XCTestCase {
    func testEase() {
        for x in stride(from: 0.0, through: 1, by: 0.1) { XCTAssertEqual(CubicBezier.linear.ease(x), x, accuracy: 1e-6) }
        // CSS `ease` = cubic-bezier(0.25, 0.1, 0.25, 1), reference value at 0.5
        XCTAssertEqual(CubicBezier(0.25, 0.1, 0.25, 1).ease(0.5), 0.8024, accuracy: 1e-3)
        let easeOut = CubicBezier(0.05, 0.9, 0.1, 1)
        XCTAssertEqual(easeOut.ease(-1), 0)
        XCTAssertEqual(easeOut.ease(2), 1)
        XCTAssertGreaterThan(easeOut.ease(0.1), 0.5)
        var previous = 0.0
        for x in stride(from: 0.0, through: 1, by: 0.01) {
            XCTAssertGreaterThanOrEqual(easeOut.ease(x), previous - 1e-9)
            previous = easeOut.ease(x)
        }
        // an overshooting curve goes above 1 before it settles
        XCTAssertGreaterThan(stride(from: 0.0, through: 1, by: 0.01).map { CubicBezier(0.1, 0.9, 0.2, 1.08).ease($0) }.max()!, 1)
    }
}

final class AnimationSettingsTest: XCTestCase {
    func testHyprlandConf() {
        let (settings, diagnostics) = AnimationSettings.parse(hyprlandConf: hyprlandConf)
        XCTAssertEqual(diagnostics, [])
        XCTAssertTrue(settings.enabled) // the blur block's `enabled = false` is not the animations' one
        let windowsIn = settings.resolve(.windowsIn)
        XCTAssertEqual(windowsIn.durationMs, 410, accuracy: 1e-9)
        XCTAssertEqual(windowsIn.curve, CubicBezier(0.23, 1, 0.32, 1))
        XCTAssertEqual(windowsIn.style, .popin(percent: 87))
        // inherited: windowsMove from windows, fadeDim from fade, specialWorkspace from workspaces
        let windowsMove = settings.resolve(.windowsMove)
        XCTAssertEqual(windowsMove.durationMs, 479, accuracy: 1e-9)
        XCTAssertEqual(windowsMove.curve, CubicBezier(0.23, 1, 0.32, 1))
        XCTAssertNil(windowsMove.style)
        XCTAssertEqual(settings.resolve(.fadeDim).durationMs, 303, accuracy: 1e-9)
        XCTAssertEqual(settings.resolve(.specialWorkspaceIn).style, .fade)
        XCTAssertEqual(settings.resolve(.windowsOut).curve, .linear) // `linear` redefined, same values
        XCTAssertTrue(settings.hasOwnLine(.windowsIn))
        XCTAssertFalse(settings.hasOwnLine(.windowsMove))
        // nothing set: Hyprland's global
        XCTAssertEqual(AnimationSettings().resolve(.windowsIn), AnimationSettings.globalDefault)
    }

    func testAnimationsOff() {
        let (settings, _) = AnimationSettings.parse(hyprlandConf: "animations {\n    enabled = no\n}\nanimation = windows, 1, 4, default\n")
        XCTAssertFalse(settings.enabled)
        XCTAssertFalse(settings.resolve(.windowsIn).enabled)
        XCTAssertNil(WindowAnimator(settings: settings).track(for: .open, context()))
    }

    func testOffLines() {
        let (settings, diagnostics) = AnimationSettings.parse(animation: ["windows, 0", "windowsIn, 1, 4, default"])
        XCTAssertEqual(diagnostics, [])
        XCTAssertFalse(settings.resolve(.windowsOut).enabled)
        XCTAssertTrue(settings.resolve(.windowsIn).enabled)
    }

    func testBadLines() {
        let lines = [
            "nothing, 1, 4, default", // no such animation
            "windows, 1, 4, nope", // no such curve
            "windows, 1, 0, default", // no duration
            "windows, 1, 4", // a field missing
            "windows, maybe, 4, default",
            "fade, 1, 3, default, popin", // fade has no style
            "workspaces, 1, 3, default, popin 120%",
            "borderangle, 1, 30, linear, slide",
            "windows, 1, 4, default, wobble",
        ]
        let (settings, diagnostics) = AnimationSettings.parse(animation: lines)
        XCTAssertEqual(diagnostics.map(\.line), lines)
        XCTAssertTrue(diagnostics.allSatisfy(\.isError))
        XCTAssertFalse(settings.hasOwnLine(.windows))
        let curves = AnimationSettings.parse(bezier: ["bad, 1.5, 0, 0, 1", "short, 0, 0, 1", ", 0, 0, 1, 1", "nan, 0, nan, 1, 1"])
        XCTAssertEqual(curves.diagnostics.count, 4)
    }

    func testIgnoredOnMacOS() {
        let (settings, diagnostics) = AnimationSettings.parse(animation: ["zoomFactor, 1, 7, default", "fadeShadow, 1, 7, default"])
        XCTAssertEqual(diagnostics.count, 2)
        XCTAssertFalse(diagnostics.contains(where: \.isError))
        XCTAssertTrue(settings.hasOwnLine(.zoomFactor))
    }

    func testPresets() {
        XCTAssertEqual(AnimationPreset.all.map(\.name), ["hyprland", "slide", "gnome", "vertical", "cyberspace"])
        for preset in AnimationPreset.all {
            XCTAssertEqual(AnimationSettings.parse(bezier: preset.bezier, animation: preset.animation).diagnostics, [], preset.name)
        }
        XCTAssertEqual(AnimationPreset.named("cyberspace")?.settings.resolve(.workspacesIn).style, .cyberspace)
        XCTAssertNil(AnimationPreset.named("nope"))
    }
}

final class AnimationStyleTest: XCTestCase {
    func testParse() {
        let styles: [String: AnimationStyle] = [
            "slide": .slide(nil), "slide left": .slide(.left), "slidevert": .slideVert, "popin": .popin(percent: 80),
            "popin 87%": .popin(percent: 87), "gnomed": .gnomed, "fade": .fade, "slidefade": .slideFade(percent: 20, vertical: false),
            "slidefadevert 40%": .slideFade(percent: 40, vertical: true), "cyberspace": .cyberspace, "loop": .loop, "once": .once,
        ]
        for (text, style) in styles {
            XCTAssertEqual(AnimationStyle.parse(text), style, text)
            XCTAssertEqual(AnimationStyle.parse(style.description), style, style.description)
        }
        for bad in ["", "popin 120%", "popin %", "popin 80", "slide up", "slidevert 20%", "gnomed 10%", "wobble"] {
            XCTAssertNil(AnimationStyle.parse(bad), bad)
        }
    }
}

final class WindowTrackTest: XCTestCase {
    func testEveryStyleAndEvent() {
        let events: [WindowEvent] = [.open, .close, .workspaceIn, .workspaceOut, .specialIn, .specialOut]
        for style in ["slide", "slidevert", "popin 80%", "gnomed", "slidefade 20%", "cyberspace", "fade", "slide left", "slidefadevert 40%"] {
            let animator = WindowAnimator(settings: settings(style))
            for event in events {
                guard let track = animator.track(for: event, context()) else { return XCTFail("\(style) \(event)") }
                XCTAssertTrue((2 ... WindowTrack.maxSamples).contains(track.samples.count))
                for sample in track.samples {
                    XCTAssertGreaterThanOrEqual(sample.rect.width, 1)
                    XCTAssertGreaterThanOrEqual(sample.rect.height, 1)
                    XCTAssertTrue((0 ... 1).contains(sample.alpha) && (-1 ... 1).contains(sample.brightness))
                }
                if event.isLeaving {
                    assertRect(track.samples[0].rect, tile)
                    if track.channels.contains(.alpha) { XCTAssertEqual(track.samples.last?.alpha, 0) }
                } else {
                    assertRect(track.samples.last!.rect, tile) // the payload maps the track onto the real frame through it
                    if track.channels.contains(.alpha) { XCTAssertEqual(track.samples.last?.alpha, 0.9) }
                }
                XCTAssertEqual(track.mode, event == .close ? .hold : event.isLeaving ? .leave : .enter)
                assertRect(track.state(atMs: track.durationMs + 10).rect, track.samples.last!.rect)
            }
        }
    }

    func testGeometry() {
        // workspaces: the next one comes from the right (slide) or from below (slidevert)
        assertRect(WindowAnimator(settings: settings("slide")).track(for: .workspaceIn, context())!.samples[0].rect,
                   tile.offsetBy(dx: 1600, dy: 0))
        assertRect(WindowAnimator(settings: settings("slide")).track(for: .workspaceIn, context(direction: -1))!.samples[0].rect,
                   tile.offsetBy(dx: -1600, dy: 0))
        assertRect(WindowAnimator(settings: settings("slidevert")).track(for: .workspaceOut, context())!.samples.last!.rect,
                   tile.offsetBy(dx: 0, dy: -1000))
        // windows: by the closest screen edge (the top one, 330 px away), popin, gnomed
        assertRect(WindowAnimator(settings: settings("slide")).track(for: .open, context())!.samples[0].rect,
                   AnimRect(x: 100, y: -500, width: 700, height: 500))
        assertRect(WindowAnimator(settings: settings("popin 80%")).track(for: .open, context())!.samples[0].rect,
                   AnimRect(x: 170, y: 130, width: 560, height: 400))
        assertRect(WindowAnimator(settings: settings("gnomed")).track(for: .open, context())!.samples[0].rect,
                   AnimRect(x: 100, y: 329.5, width: 700, height: 1))
        // a scratchpad (direction -1) comes from the top and goes back up
        let scratch = WindowAnimator(settings: settings("slidevert"))
        assertRect(scratch.track(for: .specialIn, context(direction: -1))!.samples[0].rect, tile.offsetBy(dx: 0, dy: -1000))
        assertRect(scratch.track(for: .specialOut, context(direction: -1))!.samples.last!.rect, tile.offsetBy(dx: 0, dy: -1000))
        // a move goes from the old tile, frame only
        let move = WindowAnimator(settings: settings("cyberspace")).track(for: .move(from: AnimRect(x: 0, y: 0, width: 400, height: 300)), context())!
        assertRect(move.samples[0].rect, AnimRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertEqual(move.channels, .frame)
        XCTAssertNil(WindowAnimator(settings: settings("slide")).track(for: .move(from: tile), context()))
    }

    func testNeighbourScreens() {
        // a full slide through the right edge, shared with another screen, becomes slidefade 20%
        let animator = WindowAnimator(settings: settings("slide"))
        let fenced = animator.track(for: .workspaceIn, context(neighbours: [.right]))!
        assertRect(fenced.samples[0].rect, tile.offsetBy(dx: 320, dy: 0))
        XCTAssertEqual(fenced.channels, [.frame, .alpha])
        XCTAssertEqual(animator.effectiveStyle(.workspaceIn, .slide(nil), context(neighbours: [.right])), .slideFade(percent: 20, vertical: false))
        // the left edge is free, going the other way is a full slide
        XCTAssertEqual(animator.effectiveStyle(.workspaceIn, .slide(nil), context(direction: -1, neighbours: [.right])), .slide(nil))
        // a window slides in by the closest free edge
        assertRect(animator.track(for: .open, context(neighbours: [.top]))!.samples[0].rect, AnimRect(x: -700, y: 80, width: 700, height: 500))
        // the edges two screens share
        let left = AnimRect(x: 0, y: 0, width: 1600, height: 1000), right = AnimRect(x: 1600, y: 0, width: 1920, height: 1080)
        let below = AnimRect(x: 0, y: 1000, width: 1600, height: 1000), corner = AnimRect(x: 1600, y: 1080, width: 800, height: 600)
        let diagonal = AnimRect(x: 1600, y: 2000, width: 800, height: 600) // touches `below` by a corner only
        XCTAssertEqual(left.neighbourEdges(among: [left, right, below]), [.right, .bottom])
        XCTAssertEqual(right.neighbourEdges(among: [left, right, corner]), [.left, .bottom])
        XCTAssertEqual(below.neighbourEdges(among: [left, below, diagonal]), [.top])
    }

    func testPayloadCommand() {
        let track = WindowAnimator(settings: settings("popin 80%")).track(for: .open, context())!
        let fields = track.payloadCommand.split(separator: " ").map(String.init)
        XCTAssertEqual(fields.count, 6 + 6 * track.samples.count)
        XCTAssertEqual(Array(fields.prefix(6)), ["track", "4242", "500.0", "0", "3", "\(track.samples.count)"])
        XCTAssertEqual(fields.dropFirst(6).prefix(6), ["170.0", "130.0", "560.0", "400.0", "0.000", "0.000"])
        XCTAssertTrue(fields.allSatisfy { !$0.hasPrefix("-0.") || Double($0)! != 0 })
        // the longest track fits the payload's line buffer
        let long = WindowAnimator(settings: AnimationSettings.parse(animation: ["windows, 1, 100, default, cyberspace"]).settings)
            .track(for: .open, context())!
        XCTAssertEqual(long.samples.count, WindowTrack.maxSamples)
        XCTAssertLessThan(long.payloadCommand.utf8.count, 16_384)
    }
}

final class CyberspaceTest: XCTestCase {
    func testRez() {
        let animator = WindowAnimator(settings: settings("cyberspace"))
        let track = animator.track(for: .open, context())!
        XCTAssertEqual(track, animator.track(for: .open, context())) // the same glitches every time
        XCTAssertNotEqual(track.samples, animator.track(for: .open, context(id: 7))!.samples)
        XCTAssertEqual(track.channels, [.frame, .alpha, .brightness])
        XCTAssertEqual(track.samples.count, 46) // 500 ms at 90 samples a second
        XCTAssertLessThanOrEqual(track.samples[1].rect.height, 6) // a scan line first
        XCTAssertGreaterThan(track.samples.map(\.brightness).max()!, 0.8) // white-hot
        XCTAssertTrue(track.samples.contains { abs($0.rect.midX - tile.midX) > 5 }) // torn by glitches
        XCTAssertEqual(track.samples.last, TrackSample(rect: tile, alpha: 0.9, brightness: 0))
        // a workspace switch waits for the old windows to derez
        let switched = animator.track(for: .workspaceIn, context())!
        XCTAssertEqual(switched.samples[1].alpha, 0)
    }

    func testDerez() {
        let animator = WindowAnimator(settings: settings("cyberspace"))
        let gone = animator.track(for: .close, context())!
        XCTAssertEqual(gone.mode, .hold)
        XCTAssertEqual(gone.samples.last?.alpha, 0)
        XCTAssertEqual(gone.samples.last?.brightness, 0) // back to its brightness, unseen
        XCTAssertEqual(gone.samples.last?.rect.width, 2) // a dot
        let away = animator.track(for: .workspaceOut, context())!
        XCTAssertEqual(away.mode, .leave)
        XCTAssertLessThan(away.samples.last!.rect.midX, tile.midX) // drifts the way of the switch
    }
}
