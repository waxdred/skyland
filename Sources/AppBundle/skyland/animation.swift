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
//
// windows: moves/resizes slide from the previous tile, new windows pop in from 80%.
// workspaces: windows of the workspace being shown slide in vertically.
struct Animations: ConvenienceMutable, Equatable, Sendable {
    var enabled: Bool = false
    var windowsMs: Int = 0
    var windowsBezier: Bezier = .linear
    var workspacesMs: Int = 0
    var workspacesBezier: Bezier = .linear
}

struct Bezier: Equatable, Sendable {
    var x1: Double, y1: Double, x2: Double, y2: Double
    static let linear = Bezier(x1: 0, y1: 0, x2: 1, y2: 1)
    var args: String { "\(x1) \(y1) \(x2) \(y2)" }
}

private let animationsParser: [String: any ParserProtocol<Animations>] = [
    "enabled": Parser(\.enabled, parseBool),
    "windows-ms": Parser(\.windowsMs, parseInt),
    "windows-bezier": Parser(\.windowsBezier, parseBezier),
    "workspaces-ms": Parser(\.workspacesMs, parseInt),
    "workspaces-bezier": Parser(\.workspacesBezier, parseBezier),
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

/// Windows that were hidden in a corner because their workspace was not visible,
/// and were just brought back: their next layout is a workspace switch.
@MainActor private var unhiddenWindows: Set<UInt32> = []

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
    if unhiddenWindows.remove(window.windowId) != nil {
        // ponytail: always slides up from below; Hyprland picks the direction from workspace order
        from = target.copy(\.topLeftY, target.topLeftY + target.height)
        (ms, bezier) = (anim.workspacesMs, anim.workspacesBezier)
    } else if let previous {
        if previous.topLeftX == target.topLeftX && previous.topLeftY == target.topLeftY
            && previous.width == target.width && previous.height == target.height { return }
        from = previous
        (ms, bezier) = (anim.windowsMs, anim.windowsBezier)
    } else {
        // Hyprland `popin 80%`
        let w = target.width * 0.8, h = target.height * 0.8
        from = Rect(topLeftX: target.topLeftX + (target.width - w) / 2, topLeftY: target.topLeftY + (target.height - h) / 2, width: w, height: h)
        (ms, bezier) = (anim.windowsMs, anim.windowsBezier)
    }
    if ms <= 0 { return }
    skylandSa("animate \(window.windowId) \(from.topLeftX) \(from.topLeftY) \(from.width) \(from.height) \(ms) \(bezier.args)")
}
