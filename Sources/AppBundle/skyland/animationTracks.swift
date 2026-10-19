import AppKit
import Common
import SkylandAnimation

// skyland: Hyprland's animation tree (Sources/SkylandAnimation, issue #33): a window event
// becomes a track (rect, opacity, brightness sampled over the animation) that the Dock
// payload plays at the display rate (`track`).
//
// [animations]
// enabled = true
// preset = 'vertical'                  # hyprland | slide | gnome | vertical | cyberspace,
//                                      # or stacked: ['gnome', 'cyberspace'] (the later wins node by node)
// bezier = ['overshot, 0.05, 0.9, 0.1, 1.05']
// animation = [                        # hyprland.conf lines, over the preset
//   'windows, 1, 5, overshot, slide',
//   'workspaces, 1, 6, default, slidefade 20%',
// ]
//
// Without preset nor lines, the older keys (windows-ms / -bezier, workspaces-*, fade-*) give
// skyland's look so far: windows pop in from 80%, workspaces slide vertically and fade.

/// The base lines: the presets' in order (a later line replaces an earlier one of the same
/// node or curve), else the older keys.
private func baseLines(_ a: Animations) -> (bezier: [String], animation: [String]) {
    let presets = a.preset.compactMap(AnimationPreset.named)
    if !presets.isEmpty { return (presets.flatMap(\.bezier), presets.flatMap(\.animation)) }
    let ds = { (ms: Int) in String(Double(ms) / 100) }
    let curve = { (name: String, b: Bezier) in "\(name), \(b.x1), \(b.y1), \(b.x2), \(b.y2)" }
    return (
        [curve("skylandWindows", a.windowsBezier), curve("skylandWorkspaces", a.workspacesBezier), curve("skylandFade", a.fadeBezier)],
        [
            "windows, \(a.windowsMs > 0 ? 1 : 0), \(ds(max(a.windowsMs, 1))), skylandWindows, popin 80%",
            "workspaces, \(a.workspacesMs > 0 ? 1 : 0), \(ds(max(a.workspacesMs, 1))), skylandWorkspaces, slidefadevert 100%",
            "fade, \(a.fadeMs > 0 ? 1 : 0), \(ds(max(a.fadeMs, 1))), skylandFade",
            "specialWorkspace, \(a.windowsMs > 0 ? 1 : 0), \(ds(max(a.windowsMs, 1))), skylandWindows, slidevert",
        ],
    )
}

private func settings(_ a: Animations) -> (settings: AnimationSettings, diagnostics: [AnimationDiagnostic]) {
    let base = baseLines(a)
    var (settings, diagnostics) = AnimationSettings.parse(bezier: base.bezier + a.bezier, animation: base.animation + a.animation)
    settings.enabled = a.enabled
    return (settings, diagnostics)
}

/// Config errors of the animation lines (notices about nodes macOS has no use for are left out).
func animationLineErrors(_ a: Animations) -> [String] {
    var errors = settings(a).diagnostics.filter(\.isError).map(\.description)
    for name in a.preset where AnimationPreset.named(name) == nil {
        errors.append("Unknown animation preset '\(name)': \(AnimationPreset.all.map(\.name).joined(separator: " | "))")
    }
    return errors
}

@MainActor private var animatorCache: (key: Animations, animator: WindowAnimator)? = nil

/// The animator of the current config (rebuilt when [animations] changes).
@MainActor
var windowAnimator: WindowAnimator {
    if let cache = animatorCache, cache.key == config.animations { return cache.animator }
    let animator = WindowAnimator(settings: settings(config.animations).settings)
    animatorCache = (config.animations, animator)
    return animator
}

/// Windows whose opacity / brightness a track drives until the date: the decoration pass
/// does not fade them meanwhile (it would take the channel over).
@MainActor private var alphaTracked: [UInt32: Date] = [:]
@MainActor private var brightnessTracked: [UInt32: Date] = [:]
@MainActor func isAlphaTracked(_ windowId: UInt32) -> Bool { (alphaTracked[windowId] ?? .distantPast) > .now }
@MainActor func isBrightnessTracked(_ windowId: UInt32) -> Bool { (brightnessTracked[windowId] ?? .distantPast) > .now }

extension AnimRect {
    init(_ r: Rect) { self.init(x: r.topLeftX, y: r.topLeftY, width: r.width, height: r.height) }
}

/// Plays `event` on the window through the payload; nil when it is off (or the payload has
/// no `track`). `rect`: where the window ends (coming in) or is (leaving); `direction` +1
/// towards a higher workspace, -1 a lower one (a scratchpad: -1, from the top).
@MainActor
@discardableResult
func playTrack(_ event: WindowEvent, _ window: Window, rect: Rect, direction: Double = 1, mode: WindowTrack.Mode? = nil) -> WindowTrack? {
    guard config.animations.enabled, payloadCapabilities.contains("track"), !overrides(window.windowId).noAnim else { return nil }
    let monitor = window.nodeWorkspace?.workspaceMonitor ?? mainMonitorInfo
    let screen = AnimRect(monitor.rect)
    let opacity = Double(windowOpacity(window.windowId, focused: window === focus.windowOrNil)) / 100
    let context = WindowContext(windowId: window.windowId, rect: AnimRect(rect), monitor: screen, direction: direction,
                                opacity: opacity, neighbourEdges: screen.neighbourEdges(among: monitorInfos.map { AnimRect($0.rect) }))
    let animator = windowAnimator
    guard var track = animator.track(for: event, context) else { return nil }
    if let mode { track.mode = mode }
    skylandSa(track.payloadCommand)
    let until = Date.now + track.durationMs / 1000
    if track.channels.contains(.alpha) {
        alphaTracked[window.windowId] = until
        // a track cut short (another one on the window, a frame only one) leaves the opacity where
        // it was, 0 for a window coming back from a hidden workspace: once it is over, the opacity
        // the decoration pass holds for the window is sent again
        let windowId = window.windowId
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(track.durationMs) + 100))
            if alphaTracked[windowId] == until { settleOpacity(windowId) }
        }
    }
    if track.channels.contains(.brightness) { brightnessTracked[window.windowId] = until }
    if track.channels.contains(.frame) { pauseAnimatedBorder(ms: Int(track.durationMs)) }
    let style = animator.effectiveStyle(event, animator.settings.resolve(event.node).style, context)
    if style == .cyberspace {
        let accent = skylandThemeColors()["accent"]?.cgColor ?? NSColor.controlAccentColor.cgColor
        CyberspaceOverlay.play(around: context.rect, durationMs: track.durationMs, leaving: event.isLeaving, color: accent,
                               level: window.isFloating ? Int(CGWindowLevelForKey(.floatingWindow)) : 0, above: window.windowId)
    }
    return track
}

extension CubicBezier {
    /// The payload's `x1 y1 x2 y2` arguments
    var args: String { "\(x1) \(y1) \(x2) \(y2)" }
}
