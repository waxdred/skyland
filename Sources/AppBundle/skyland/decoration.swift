import AppKit
import Carbon
import Common

// Hyprland-like window decoration (rounding, active/inactive opacity), applied
// through the skyland scripting addition injected into Dock (see osax/payload.m).
// TOML has no float support in this config parser, so opacity is in percent.
// With [animations] fade-ms, opacity changes fade (stepped by the payload, never
// a WindowServer fade, which crashed it): focus changes, new windows fading in
// and windows of a workspace being switched away fading to 0 while they slide.
//
// [decoration]
// rounding = 8
// active-opacity = 100
// inactive-opacity = 90
// dim-inactive = 0     # darken unfocused windows, percent (Hyprland dim_inactive + dim_strength)
// border-width = 2     # focused window border in the theme accent (JankyBorders), 0 = none
// border-rotate-ms = 0 # rotating border gradient, one turn in ms (skyland draws it, see animatedBorder.swift)
// blur = 5             # Ghostty background blur behind its translucent background, 0 = none
// group-bar-height = 22 # accordion containers become Hyprland groups: tabs bar on top, one window shown (0 = AeroSpace accordion)
// border-width and blur are applied by bin/skyland-theme; parsed here so the config validates.
struct Decoration: ConvenienceMutable, Equatable, Sendable {
    var rounding: Int = 0
    var activeOpacity: Int = 100
    var inactiveOpacity: Int = 100
    var dimInactive: Int = 0
    var borderWidth: Int = 0
    var borderRotateMs: Int = 0
    var blur: Int = 0
    var groupBarHeight: Int = 0

    var isEnabled: Bool { rounding > 0 || activeOpacity != 100 || inactiveOpacity != 100 || dimInactive > 0 }
}

private let decorationParser: [String: any ParserProtocol<Decoration>] = [
    "rounding": Parser(\.rounding, parseInt),
    "active-opacity": Parser(\.activeOpacity, parseInt),
    "inactive-opacity": Parser(\.inactiveOpacity, parseInt),
    "dim-inactive": Parser(\.dimInactive, parseInt),
    "border-width": Parser(\.borderWidth, parseInt),
    "border-rotate-ms": Parser(\.borderRotateMs, parseInt),
    "blur": Parser(\.blur, parseInt),
    "group-bar-height": Parser(\.groupBarHeight, parseInt),
]

func parseDecoration(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> Decoration {
    parseTable(raw, Decoration(), decorationParser, backtrace, &c)
}

// Last value sent per window, so a refresh only sends what changed.
@MainActor private var sentOpacity: [UInt32: Int] = [:]
@MainActor private var sentRounding: [UInt32: Int] = [:]
@MainActor private var sentDim: [UInt32: Int] = [:]
// Floating windows stay above tiles (payload `layer`); ids currently raised.
@MainActor private var raisedWindows: Set<UInt32> = []
@MainActor private var seenWindows: Set<UInt32> = []
// The payload recreates its socket on every injection; a Dock restart drops
// what it applied, so a new socket inode means everything must be resent.
@MainActor private var payloadSocketInode: ino_t = 0
// Fades only when the loaded payload says it supports them (asked once per
// injection); an older payload rejects `fade` and opacity would never change.
/// Words of the payload's `ping` reply ("ok fade close"), asked once per injection.
@MainActor private(set) var payloadCapabilities: Set<String> = []
// Windows already there when skyland starts are not faded in: neither during the
// startup refresh nor shortly after (windows can be registered a bit later).
@MainActor private var firstApplyDate: Date? = nil

@MainActor
func applyDecorations() {
    updateAnimatedBorder()
    guard TrayMenuModel.shared.isEnabled else { return } // disabled: stock macOS look (restoreDecorations)
    let deco = config.decoration
    let anim = config.animations
    let wantsFades = anim.enabled && anim.fadeMs > 0
    if !deco.isEnabled && !wantsFades && sentOpacity.isEmpty && sentRounding.isEmpty && sentDim.isEmpty && raisedWindows.isEmpty
        && !MacWindow.allWindows.contains(where: \.isFloating) { return }
    var st = stat()
    let inode = unsafe stat(skylandSaSocketPath, &st) == 0 ? st.st_ino : 0
    if inode != payloadSocketInode {
        payloadSocketInode = inode
        sentOpacity = [:]
        sentRounding = [:]
        sentDim = [:]
        raisedWindows = []
        payloadCapabilities = Set((skylandSa("ping", wait: true) ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
        setSkylandSaBatches(payloadCapabilities.contains("batch"))
    }
    let fades = wantsFades && payloadCapabilities.contains("fade")
    let startedAt = firstApplyDate ?? .now
    firstApplyDate = startedAt
    let startingUp = isStartup || Date.now.timeIntervalSince(startedAt) < 2
    let focusedId = focus.windowOrNil?.windowId
    var alive = Set<UInt32>()
    var newWindows: [UInt32] = []
    // Floating windows go back to the normal level while a password / Touch ID
    // prompt (secure input) or another app without managed windows (auth agents,
    // system popups) is in front: their normal level windows would be under them.
    let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let raiseFloating = !IsSecureEventInputEnabled()
        && (frontPid == nil || MacWindow.allWindows.contains { $0.app.pid == frontPid })
    for (windowId, window) in MacWindow.allWindowsMap {
        alive.insert(windowId)
        var fadeIn = false
        if seenWindows.insert(windowId).inserted {
            newWindows.append(windowId)
            fadeIn = fades && !startingUp // Hyprland fadeIn
        }
        // Hidden in a corner = workspace switched away: fade out while it slides out
        let opacity = (fades && window.isHiddenInCorner) || isHiddenGroupTab(window) ? 0
            : windowId == focusedId ? deco.activeOpacity : deco.inactiveOpacity
        if fadeIn || sentOpacity[windowId, default: 100] != opacity {
            sentOpacity[windowId] = opacity
            // one command: if the payload rejects it, nothing changes (never alpha 0 then fade)
            skylandSa(fades
                ? "fade \(windowId) \(Double(opacity) / 100) \(anim.fadeMs) \(anim.fadeBezier.args)\(fadeIn ? " 0" : "")"
                : "alpha \(windowId) \(Double(opacity) / 100)")
        }
        let raise = window.isFloating && raiseFloating
        if payloadCapabilities.contains("layer"), raise != raisedWindows.contains(windowId) {
            if raise { raisedWindows.insert(windowId) } else { raisedWindows.remove(windowId) }
            skylandSa("layer \(windowId) \(raise ? 1 : 0)")
        }
        let dim = windowId == focusedId ? 0 : min(100, max(0, deco.dimInactive))
        if payloadCapabilities.contains("dim"), sentDim[windowId, default: 0] != dim {
            let from = sentDim[windowId, default: 0]
            sentDim[windowId] = dim
            skylandSa(fades && !fadeIn
                ? "dim \(windowId) \(Double(dim) / 100) \(anim.fadeMs) \(anim.fadeBezier.args) \(Double(from) / 100)"
                : "dim \(windowId) \(Double(dim) / 100)")
        }
        if sentRounding[windowId, default: 0] != deco.rounding {
            sentRounding[windowId] = deco.rounding
            skylandSa(deco.rounding > 0 ? "corner \(windowId) \(deco.rounding)" : "uncorner \(windowId)")
        }
    }
    sentOpacity = sentOpacity.filter { alive.contains($0.key) }
    sentRounding = sentRounding.filter { alive.contains($0.key) }
    sentDim = sentDim.filter { alive.contains($0.key) }
    seenWindows = seenWindows.intersection(alive)
    raisedWindows = raisedWindows.intersection(alive)
    if !newWindows.isEmpty { resendLater(newWindows) }
}

// macOS animates a window in when it opens and resets its alpha to 1 at the
// end, overwriting what we just sent; resend once the animation is over.
@MainActor private func resendLater(_ windowIds: [UInt32]) {
    Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(500))
        for windowId in windowIds {
            sentOpacity[windowId] = nil
            sentRounding[windowId] = nil
            sentDim[windowId] = nil
        }
        applyDecorations()
    }
}

/// Put every window back to stock macOS look, called before quitting.
@MainActor
func restoreDecorations() {
    hideAnimatedBorder()
    for windowId in sentOpacity.keys { skylandSa("alpha \(windowId) 1", wait: true) }
    for windowId in sentRounding.keys { skylandSa("uncorner \(windowId)", wait: true) }
    for windowId in raisedWindows { skylandSa("layer \(windowId) 0", wait: true) }
    for (windowId, dim) in sentDim where dim > 0 { skylandSa("dim \(windowId) 0", wait: true) }
    // a transform left by an animation outlives skyland (and Dock): the window
    // would stay drawn at the animated position until its app reopens it
    for windowId in MacWindow.allWindowsMap.keys { skylandSa("untransform \(windowId)", wait: true) }
    raisedWindows = []
    sentOpacity = [:]
    sentRounding = [:]
    sentDim = [:]
}

private let skylandSaQueue = DispatchQueue(label: "skyland-sa")
private let skylandSaSocketPath = "/tmp/skyland-sa_\(NSUserName()).socket"

/// Fire-and-forget by default; with `wait` it returns the payload reply
/// ("ok ..." or "err ..."), nil when the scripting addition is not loaded.
/// Fire-and-forget lines of one burst (a refresh, a layout) go in one connection
/// when the payload takes several commands per connection ("batch").
@discardableResult
func skylandSa(_ line: String, wait: Bool = false) -> String? {
    if wait {
        return skylandSaQueue.sync {
            flushSkylandSa() // keeps the order
            return sendToPayload([line]).first
        }
    }
    skylandSaQueue.async {
        pendingLines.append(line)
        // first line of a burst: flush once the main thread is done queueing it
        if pendingLines.count == 1 { DispatchQueue.main.async { skylandSaQueue.async { flushSkylandSa() } } }
    }
    return nil
}

/// The loaded payload takes several commands per connection (its ping says "batch")
func setSkylandSaBatches(_ batches: Bool) { skylandSaQueue.async { payloadBatches = batches } }

// only touched on skylandSaQueue
nonisolated(unsafe) private var pendingLines: [String] = []
nonisolated(unsafe) private var payloadBatches = false

private func flushSkylandSa() {
    if pendingLines.isEmpty { return }
    let lines = pendingLines
    pendingLines = []
    if payloadBatches { sendToPayload(lines) } else { for line in lines { sendToPayload([line]) } }
}

/// One connection: the lines, then their replies (empty when the payload is not loaded).
@discardableResult
private func sendToPayload(_ lines: [String]) -> [String] {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { return [] }
    defer { close(fd) }
    var on: Int32 = 1
    unsafe setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        _ = skylandSaSocketPath.utf8CString.withUnsafeBytes { src in
            unsafe memcpy(buf.baseAddress!, src.baseAddress!, min(src.count, buf.count - 1))
        }
    }
    let connected = withUnsafePointer(to: &addr) {
        unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            unsafe connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if connected != 0 { return [] } // scripting addition not loaded
    let msg = lines.map { $0 + "\n" }.joined()
    _ = msg.withCString { unsafe write(fd, $0, strlen($0)) }
    if lines.count > 1 { shutdown(fd, SHUT_WR) } // the payload reads until the end, an older one reads one line
    var replies = ""
    var buf = [UInt8](repeating: 0, count: 4096)
    while replies.filter({ $0 == "\n" }).count < lines.count {
        let count = unsafe read(fd, &buf, buf.count)
        if count <= 0 { break }
        replies += String(decoding: buf.prefix(count), as: UTF8.self)
    }
    return replies.split(separator: "\n").map(String.init)
}

/// The window's opacity at once, no fade (a scratchpad window sliding in).
@MainActor
func showOpaqueNow(_ windowId: UInt32, focused: Bool) {
    let opacity = focused ? config.decoration.activeOpacity : config.decoration.inactiveOpacity
    sentOpacity[windowId] = opacity // the next decoration pass sees nothing to fade
    skylandSa("alpha \(windowId) \(Double(opacity) / 100)") // also stops a running fade
}

/// A window of a group (accordion with group-bar-height) that is not the shown tab:
/// fully transparent behind the shown one.
@MainActor
func isHiddenGroupTab(_ window: Window) -> Bool {
    guard config.decoration.groupBarHeight > 0 else { return false }
    var node: TreeNode = window
    while let parent = node.parent as? TilingContainer {
        if parent.layout == .accordion && parent.mostRecentChild !== node { return true }
        node = parent
    }
    return false
}
