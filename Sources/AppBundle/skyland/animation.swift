import AppKit
import Common

// Hyprland-like window animations, stepped by the scripting addition with
// window transforms (see `animate` in osax/payload.m).
//
// [animations]
// enabled = true
// windows-ms = 500                          # Hyprland speed is in ds: speed 5 = 500 ms
// windows-bezier = '0.05, 0.9, 0.1, 1.0'    # Hyprland `bezier = name, x1, y1, x2, y2`
// workspaces-ms = 600
// workspaces-bezier = '0.0, 0.75, 0.15, 1.0'
// fade-ms = 400                             # opacity changes (see decoration.swift)
// fade-bezier = '0.0, 0.75, 0.15, 1.0'
//
// windows: moves/resizes slide from the previous tile, new windows pop in from 80%.
// workspaces: Hyprland `slidevert`. Going to a higher workspace, the new one comes
// in from below and the old one leaves upwards; the reverse going down.
struct Animations: ConvenienceMutable, Equatable, Sendable {
    var enabled: Bool = false
    var windowsMs: Int = 0
    var windowsBezier: Bezier = .linear
    var workspacesMs: Int = 0
    var workspacesBezier: Bezier = .linear
    var fadeMs: Int = 0
    var fadeBezier: Bezier = .linear
}

struct Bezier: Equatable, Sendable {
    var x1: Double, y1: Double, x2: Double, y2: Double
    static let linear = Bezier(x1: 0, y1: 0, x2: 1, y2: 1)
    var args: String { "\(x1) \(y1) \(x2) \(y2)" }

    /// Eased progress for linear progress `x`, as the payload steps it (osax/bezier.h).
    func ease(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        func axis(_ t: Double, _ a: Double, _ b: Double) -> Double { ((1 - 3 * b + 3 * a) * t + (3 * b - 6 * a)) * t * t + 3 * a * t }
        func slope(_ t: Double, _ a: Double, _ b: Double) -> Double { 3 * (1 - 3 * b + 3 * a) * t * t + 2 * (3 * b - 6 * a) * t + 3 * a }
        var t = x
        for _ in 0 ..< 8 {
            let err = axis(t, x1, x2) - x, s = slope(t, x1, x2)
            if abs(err) < 1e-7 || abs(s) < 1e-7 { break }
            t -= err / s
        }
        if t < 0 || t > 1 || abs(axis(t, x1, x2) - x) > 1e-5 { // Newton misbehaved: bisection
            var lo = 0.0, hi = 1.0
            t = x
            for _ in 0 ..< 40 {
                if axis(t, x1, x2) < x { lo = t } else { hi = t }
                t = (lo + hi) / 2
            }
        }
        return axis(t, y1, y2)
    }
}

private let animationsParser: [String: any ParserProtocol<Animations>] = [
    "enabled": Parser(\.enabled, parseBool),
    "windows-ms": Parser(\.windowsMs, parseInt),
    "windows-bezier": Parser(\.windowsBezier, parseBezier),
    "workspaces-ms": Parser(\.workspacesMs, parseInt),
    "workspaces-bezier": Parser(\.workspacesBezier, parseBezier),
    "fade-ms": Parser(\.fadeMs, parseInt),
    "fade-bezier": Parser(\.fadeBezier, parseBezier),
]

func parseAnimations(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> Animations {
    parseTable(raw, Animations(), animationsParser, backtrace, &c)
}

/// The config parser has no float type, so a curve is written like in Hyprland: "x1, y1, x2, y2".
func parseBezier(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<Bezier> {
    parseString(raw, backtrace).flatMap { str in
        let values = str.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard values.count == 4, (0 ... 1).contains(values[0]), (0 ... 1).contains(values[2]) else {
            return .failure(.init(backtrace, "Expected 'x1, y1, x2, y2' with x1 and x2 in [0, 1], got '\(str)'"))
        }
        return .success(Bezier(x1: values[0], y1: values[1], x2: values[2], y2: values[3]))
    }
}

/// `percent` of `area`, centered in it (floating toggle, see floating-center-percent).
func centeredRect(in area: Rect, percent: Int) -> Rect {
    let w = area.width * CGFloat(percent) / 100, h = area.height * CGFloat(percent) / 100
    return Rect(topLeftX: area.topLeftX + (area.width - w) / 2, topLeftY: area.topLeftY + (area.height - h) / 2, width: w, height: h)
}

/// Windows that were hidden in a corner because their workspace was not visible,
/// and were just brought back: their next layout is a workspace switch.
@MainActor private var unhiddenWindows: Set<UInt32> = []
/// Workspace shown on each monitor (keyed by its top-left corner) and the slide
/// direction of the last switch there: +1 new workspace comes from below.
@MainActor private var shownWorkspace: [CGPoint: String] = [:]
@MainActor private var slideSign: [CGPoint: CGFloat] = [:]

/// Hyprland orders workspaces by id: numeric names compare as numbers.
func workspaceSlideSign(from old: String, to new: String) -> CGFloat {
    let goesUp = if let o = Int(old), let n = Int(new) { n > o } else { new > old }
    return goesUp ? 1 : -1
}

/// Called by refresh for the workspace each monitor shows, before it is laid out.
@MainActor
func noteShownWorkspace(on monitor: MonitorInfo, _ workspace: Workspace) {
    let key = monitor.rect.topLeftCorner
    if let old = shownWorkspace[key], old != workspace.name {
        slideSign[key] = workspaceSlideSign(from: old, to: workspace.name)
    }
    shownWorkspace[key] = workspace.name
}

/// A trackpad swipe that completes (gestures.swift): where each of its windows is shown
/// when the fingers let go, and how far the leaving ones still go (dx, dy). The switch's
/// animations go on from there instead of their usual slide.
@MainActor var swipeHandoff: [UInt32: Rect] = [:]
@MainActor var swipeLeave = CGPoint.zero

/// Called the first time a laid out window is hidden because its workspace was
/// switched away: it slides out of the screen, then sits hidden in its corner.
@MainActor
func animateSlideOut(_ window: Window, from rect: Rect) {
    let anim = config.animations
    guard anim.enabled, anim.workspacesMs > 0, window.lastAppliedLayoutPhysicalRect != nil,
          let workspace = window.nodeWorkspace else { return }
    let monitor = workspace.workspaceMonitor
    if let shown = swipeHandoff.removeValue(forKey: window.windowId) { // a swipe: on from the fingers
        let to = Rect(topLeftX: rect.topLeftX + swipeLeave.x, topLeftY: rect.topLeftY + swipeLeave.y, width: rect.width, height: rect.height)
        skylandSa("animate \(window.windowId) \(shown.args) \(anim.workspacesMs) \(anim.workspacesBezier.args) \(to.args)")
        return
    }
    let sign = workspaceSlideSign(from: workspace.name, to: monitor.activeWorkspace.name)
    let to = rect.copy(\.topLeftY, rect.topLeftY - sign * monitor.rect.height)
    skylandSa("animate \(window.windowId) \(rect.args) \(anim.workspacesMs) \(anim.workspacesBezier.args) \(to.args)")
}

/// Hyprland windowsOut: before skyland closes a window (close command), it
/// shrinks to 80% and fades out, then is closed. Windows closed by their app
/// (cmd-w, red button) are gone before skyland knows, so they are not animated.
@MainActor
func animateClose(_ window: Window) async {
    let anim = config.animations
    guard anim.enabled, anim.windowsMs > 0, payloadCapabilities.contains("close"),
          let rect = window.lastAppliedLayoutPhysicalRect else { return }
    let ms = anim.windowsMs, bezier = anim.windowsBezier
    skylandSa("animate \(window.windowId) \(rect.args) \(ms) \(bezier.args) \(centeredRect(in: rect, percent: 80).args) 1")
    skylandSa("fade \(window.windowId) 0 \(ms) \(bezier.args)")
    try? await Task.sleep(for: .milliseconds(ms))
}

/// The app may refuse to close (unsaved changes dialog): give the window back
/// its size and opacity instead of leaving it invisible.
@MainActor
func restoreIfStillOpen(_ windowId: UInt32) {
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(1))
        let alive = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowId) as? [[String: Any]])?.isEmpty == false
        if alive {
            skylandSa("untransform \(windowId)")
            skylandSa("alpha \(windowId) 1")
        }
    }
}

extension Rect {
    fileprivate var args: String { "\(topLeftX) \(topLeftY) \(width) \(height)" }
}

@MainActor
func markUnhiddenForAnimation(_ windowId: UInt32) {
    if config.animations.enabled { unhiddenWindows.insert(windowId) }
}

/// Called by layoutRecursive right after `window` was given `target`; `previous`
/// is the tile it had before (nil for a window that was never laid out).
@MainActor
func animateLayoutChange(_ window: Window, from previous: Rect?, to target: Rect) {
    let anim = config.animations
    guard anim.enabled else { return }
    let from: Rect
    let ms: Int
    let bezier: Bezier
    if let shown = swipeHandoff.removeValue(forKey: window.windowId) { // a swipe: on from the fingers
        unhiddenWindows.remove(window.windowId)
        from = shown
        (ms, bezier) = (anim.workspacesMs, anim.workspacesBezier)
    } else if unhiddenWindows.remove(window.windowId) != nil {
        let monitor = window.nodeWorkspace?.workspaceMonitor ?? mainMonitorInfo
        let sign = slideSign[monitor.rect.topLeftCorner] ?? 1
        from = target.copy(\.topLeftY, target.topLeftY + sign * monitor.rect.height)
        (ms, bezier) = (anim.workspacesMs, anim.workspacesBezier)
    } else if let previous {
        if previous.topLeftX == target.topLeftX && previous.topLeftY == target.topLeftY
            && previous.width == target.width && previous.height == target.height { return }
        from = previous
        (ms, bezier) = (anim.windowsMs, anim.windowsBezier)
    } else {
        from = centeredRect(in: target, percent: 80) // Hyprland `popin 80%`
        (ms, bezier) = (anim.windowsMs, anim.windowsBezier)
    }
    if ms <= 0 { return }
    skylandSa("animate \(window.windowId) \(from.args) \(ms) \(bezier.args)")
    pauseAnimatedBorder(ms: ms) // the window server frame is the animated one until the end
}
