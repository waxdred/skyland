import AppKit
import Common

// skyland: per window properties (Hyprland windowrulev2 actions), set by the
// `window-rule` command, mostly from `run` of [[on-window-detected]]:
//
// [[on-window-detected]]
// if.app-id = 'com.apple.finder'
// run = ['layout floating', 'window-rule size 60% 70%', 'window-rule center', 'window-rule opacity 95 85']
//
// Kept per window id (in memory) and dropped with the window; read by the decoration pass
// (opacity, rounding, dim), the rotating border and the animations.

struct WindowOverrides: Equatable {
    var activeOpacity: Int? = nil
    var inactiveOpacity: Int? = nil
    var rounding: Int? = nil
    var noBorder = false
    var noDim = false
    var noAnim = false
}

@MainActor private(set) var windowOverrides: [UInt32: WindowOverrides] = [:]

@MainActor func overrides(_ windowId: UInt32) -> WindowOverrides { windowOverrides[windowId] ?? WindowOverrides() }

/// The decoration pass: windows that are gone lose their overrides.
@MainActor func dropWindowOverrides(keeping alive: Set<UInt32>) {
    if windowOverrides.keys.contains(where: { !alive.contains($0) }) { windowOverrides = windowOverrides.filter { alive.contains($0.key) } }
}

/// Apps whose windows stay opaque and undimmed: their privacy and security panes ignore
/// clicks in a window that is not fully opaque (clickjacking protection), so System
/// Settings' panes took no mouse input at inactive-opacity 98.
let alwaysOpaqueApps: Set<String> = [
    "com.apple.systempreferences", "com.apple.SecurityAgent", "com.apple.UserNotificationCenter",
    "com.apple.Passwords", "com.apple.keychainaccess",
]

/// Also sheets and dialogs (save / open panels, alerts: popups for skyland) and the windows of
/// an app showing one: the save panel runs in another process that refuses clicks while its
/// window, or the window it hangs from, is not fully opaque (a download's save sheet in Brave
/// could not be clicked).
/// `popupPids`: pidsShowingPopup(), computed once by a caller that asks for every window.
@MainActor
func isAlwaysOpaque(_ windowId: UInt32, popupPids: Set<Int32>? = nil) -> Bool {
    guard let window = MacWindow.allWindowsMap[windowId] else { return false }
    if window.app.rawAppBundleId.map(alwaysOpaqueApps.contains) == true { return true }
    if window.parent is MacosPopupWindowsContainer { return true }
    return (popupPids ?? pidsShowingPopup()).contains(window.app.pid)
}

/// The apps showing a popup (sheet, dialog) right now.
@MainActor
func pidsShowingPopup() -> Set<Int32> {
    Set(MacWindow.allWindowsMap.values.lazy.filter { $0.parent is MacosPopupWindowsContainer }.map(\.app.pid))
}

/// A floating window found with its middle off its monitor, on a shown workspace: its app
/// saved the frame skyland gave it while its workspace was hidden (the corner), and opened it
/// there again (Calculator quit on a hidden workspace came back 1 px from the edge). Centered,
/// as Hyprland places floating windows.
@MainActor
func centerIfOffscreen(_ window: Window, _ rect: Rect?) {
    guard window.isFloating, let rect, let workspace = window.nodeWorkspace, workspace.isVisible else { return }
    let area = workspace.workspaceMonitor.visibleRect
    guard !area.contains(rect.center) else { return }
    window.setAxFrame(CGPoint(x: area.topLeftX + (area.width - rect.width) / 2, y: area.topLeftY + (area.height - rect.height) / 2), nil)
}

/// The window's opacity in percent: its own override, else [decoration].
@MainActor
func windowOpacity(_ windowId: UInt32, focused: Bool, popupPids: Set<Int32>? = nil) -> Int {
    if isAlwaysOpaque(windowId, popupPids: popupPids) { return 100 }
    let o = overrides(windowId), deco = config.decoration
    return focused ? o.activeOpacity ?? deco.activeOpacity : o.inactiveOpacity ?? deco.inactiveOpacity
}

struct WindowRuleCommand: Command {
    let args: WindowRuleCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io), let window = target.windowOrNil else {
            return .fail(io.err("No window"))
        }
        let id = window.windowId
        var o = overrides(id)
        let monitor = window.nodeWorkspace?.workspaceMonitor.visibleRect ?? mainMonitorInfo.visibleRect
        /// "800" points, or "60%" of the screen's width / height
        func length(_ raw: String?, of total: CGFloat) -> CGFloat? {
            guard let raw else { return nil }
            if raw.hasSuffix("%"), let p = Double(raw.dropLast()) { return total * p / 100 }
            return Double(raw).map { CGFloat($0) }
        }
        func flag(_ current: Bool) -> Bool? {
            switch args.value1 ?? "on" {
                case "on": true
                case "off": false
                case "toggle": !current
                default: nil
            }
        }
        switch args.property.val {
            case .size, .move, .center:
                guard window.isFloating else { return .fail(io.err("\(args.property.val.rawValue) applies to floating windows (layout floating first)")) }
                guard let rect = try? await window.getAxRect(.nonCancellable) else { return .fail(io.err("Can't read the window's frame")) }
                switch args.property.val {
                    case .size:
                        guard let w = length(args.value1, of: monitor.width), let h = length(args.value2, of: monitor.height), w >= 1, h >= 1 else {
                            return .fail(io.err("size <width> <height>: points or N%"))
                        }
                        window.setAxFrame(nil, CGSize(width: w, height: h))
                    case .move:
                        guard let x = length(args.value1, of: monitor.width), let y = length(args.value2, of: monitor.height) else {
                            return .fail(io.err("move <x> <y>: points or N% from the screen's top left corner"))
                        }
                        window.setAxFrame(CGPoint(x: monitor.topLeftX + x, y: monitor.topLeftY + y), nil)
                    default: // center, at its size (a `size` just before may not be applied yet: use it)
                        let size = rect.size
                        window.setAxFrame(CGPoint(x: monitor.topLeftX + (monitor.width - size.width) / 2,
                                                  y: monitor.topLeftY + (monitor.height - size.height) / 2), nil)
                }
                return .succ
            case .opacity:
                guard let active = args.value1.flatMap({ Int($0) }), (0 ... 100).contains(active),
                      (args.value2.flatMap { Int($0) }.map { (0 ... 100).contains($0) } ?? true) else {
                    return .fail(io.err("opacity <active> [<inactive>]: percent"))
                }
                o.activeOpacity = active
                o.inactiveOpacity = args.value2.flatMap { Int($0) } ?? active
            case .rounding:
                guard let px = args.value1.flatMap({ Int($0) }), px >= 0 else { return .fail(io.err("rounding <px>")) }
                o.rounding = px
            case .noborder:
                guard let v = flag(o.noBorder) else { return .fail(io.err("on | off | toggle")) }
                o.noBorder = v
            case .nodim:
                guard let v = flag(o.noDim) else { return .fail(io.err("on | off | toggle")) }
                o.noDim = v
            case .noanim:
                guard let v = flag(o.noAnim) else { return .fail(io.err("on | off | toggle")) }
                o.noAnim = v
        }
        windowOverrides[id] = o == WindowOverrides() ? nil : o
        return .succ
    }
}
