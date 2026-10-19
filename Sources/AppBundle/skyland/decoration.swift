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
// startup-hud = true # a "starting" panel while skyland lays the windows out at start
// glass-blur = 2      # glass panels: how much what is behind is blurred, points (0: sharp)
// ui-style = 'metal'  # skyland's panels (overview, switcher, HUDs, settings, wallpaper picker, media widget): metal (blur) | glass (Liquid Glass, uiStyle.swift)
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
    var shadow = "on" // on | off | floating: only floating windows keep their shadow
    var uiStyle = "metal" // metal | glass
    var glassBlur: Int = 2
    var startupHud = true

    var isEnabled: Bool { rounding > 0 || activeOpacity != 100 || inactiveOpacity != 100 || dimInactive > 0 || shadow != "on" }
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
    "glass-blur": Parser(\.glassBlur, parseInt),
    "startup-hud": Parser(\.startupHud, parseBool),
    "ui-style": Parser(\.uiStyle) { raw, backtrace in
        parseString(raw, backtrace).flatMap { value in
            ["metal", "glass"].contains(value) ? .success(value) : .failure(.init(backtrace, "Expected 'metal' or 'glass', got '\(value)'"))
        }
    },
    "shadow": Parser(\.shadow) { raw, backtrace in
        parseString(raw, backtrace).flatMap { value in
            ["on", "off", "floating"].contains(value) ? .success(value)
                : .failure(.init(backtrace, "Expected 'on', 'off' or 'floating', got '\(value)'"))
        }
    },
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
/// Windows whose shadow skyland turned off ([decoration] shadow). Kept when the payload is
/// injected again: the windows stay shadowless in WindowServer, and the new payload
/// gives them back the default shadow (it lost the saved one).
@MainActor private var shadowless: Set<UInt32> = []
@MainActor private(set) var payloadCapabilities: Set<String> = []
// Windows already there when skyland starts are not faded in: neither during the
// startup refresh nor shortly after (windows can be registered a bit later).
@MainActor private var firstApplyDate: Date? = nil

/// Windows checked for a transform left over from before skyland (or this payload) started.
@MainActor private var untransformed: Set<UInt32> = []
@MainActor private var untransformedSince: (inode: ino_t, date: Date) = (0, .distantPast)

/// A WindowServer transform outlives the animation that set it when skyland or Dock dies
/// mid-way (killed, crashed): the window stays drawn at the animated size and place, a lone
/// window looking stuck in a split (#72). Each window skyland finds in the first seconds of
/// a payload is put back to its real frame; later ones are new, their open animation is ours.
@MainActor
private func clearStaleTransforms() {
    var st = stat()
    let inode = unsafe stat(skylandSaSocketPath, &st) == 0 ? st.st_ino : 0
    guard inode != 0 else { return } // no payload: no transform either
    if inode != untransformedSince.inode {
        untransformedSince = (inode, .now)
        untransformed = []
    }
    guard Date.now.timeIntervalSince(untransformedSince.date) < 5 else { return }
    for windowId in MacWindow.allWindowsMap.keys where untransformed.insert(windowId).inserted && !isAlphaTracked(windowId) {
        skylandSa("untransform \(windowId)")
    }
}

@MainActor
func applyDecorations() {
    updateAnimatedBorder()
    guard TrayMenuModel.shared.isEnabled else { return } // disabled: stock macOS look (restoreDecorations)
    clearStaleTransforms()
    let deco = config.decoration
    let anim = config.animations
    // focus / dim fades: fadeSwitch / fadeDim of the animation tree (animationTracks.swift)
    let switchFade = windowAnimator.settings.resolve(.fadeSwitch), dimFade = windowAnimator.settings.resolve(.fadeDim)
    let wantsFades = anim.enabled && switchFade.enabled && switchFade.durationMs > 0
    if !deco.isEnabled && !wantsFades && windowOverrides.isEmpty && sentOpacity.isEmpty && sentRounding.isEmpty && sentDim.isEmpty && raisedWindows.isEmpty
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
            : windowOpacity(windowId, focused: windowId == focusedId) // window-rule opacity, else [decoration]
        // a track that drives the opacity ends at it: nothing to send meanwhile
        if isAlphaTracked(windowId) {
            sentOpacity[windowId] = opacity
        } else if fadeIn || sentOpacity[windowId, default: 100] != opacity {
            sentOpacity[windowId] = opacity
            // one command: if the payload rejects it, nothing changes (never alpha 0 then fade)
            skylandSa(fades
                ? "fade \(windowId) \(Double(opacity) / 100) \(Int(switchFade.durationMs)) \(switchFade.curve.args)\(fadeIn ? " 0" : "")"
                : "alpha \(windowId) \(Double(opacity) / 100)")
        }
        // popups and alerts skyland does not manage (a confirmation at an app's launch...) at the
        // normal level go over the windows too: focus follows the mouse on its way to them, and
        // the window it crossed came in front and hid them. Menus, tooltips: higher already.
        let popup = window.parent is MacosPopupWindowsContainer
            && (raisedWindows.contains(windowId) || getWindowLevel(for: windowId) == .normalWindow)
        let raise = (window.isFloating || popup) && raiseFloating
        if payloadCapabilities.contains("layer"), raise != raisedWindows.contains(windowId) {
            if raise { raisedWindows.insert(windowId) } else { raisedWindows.remove(windowId) }
            skylandSa("layer \(windowId) \(raise ? 1 : 0)")
        }
        let dim = windowId == focusedId || overrides(windowId).noDim || isAlwaysOpaque(windowId) ? 0 : min(100, max(0, deco.dimInactive))
        if payloadCapabilities.contains("dim"), sentDim[windowId, default: 0] != dim, !isBrightnessTracked(windowId) {
            let from = sentDim[windowId, default: 0]
            sentDim[windowId] = dim
            skylandSa(fades && !fadeIn && dimFade.enabled
                ? "dim \(windowId) \(Double(dim) / 100) \(Int(dimFade.durationMs)) \(dimFade.curve.args) \(Double(from) / 100)"
                : "dim \(windowId) \(Double(dim) / 100)")
        }
        // shadow off / floating only (payload `shadow`, which keeps the window's own to give it back)
        let shadow = deco.shadow == "on" || (deco.shadow == "floating" && window.isFloating)
        if payloadCapabilities.contains("shadow"), shadow == shadowless.contains(windowId) {
            if shadow { shadowless.remove(windowId) } else { shadowless.insert(windowId) }
            skylandSa("shadow \(windowId) \(shadow ? 1 : 0)")
        }
        let rounding = isSmartBorderless(window) ? -1 : overrides(windowId).rounding ?? deco.rounding // -1: square (smart border)
        if sentRounding[windowId, default: 0] != rounding {
            sentRounding[windowId] = rounding
            skylandSa(rounding > 0 ? "corner \(windowId) \(rounding)" : rounding < 0 ? "corner \(windowId) 0" : "uncorner \(windowId)")
        }
    }
    sentOpacity = sentOpacity.filter { alive.contains($0.key) }
    sentRounding = sentRounding.filter { alive.contains($0.key) }
    sentDim = sentDim.filter { alive.contains($0.key) }
    shadowless = shadowless.intersection(alive)
    dropWindowOverrides(keeping: alive)
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
    for windowId in shadowless { skylandSa("shadow \(windowId) 1", wait: true) }
    shadowless = []
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

/// A hidden window shown by a swipe (`shown`) or hidden again: its alpha at once, and what
/// the decoration pass will compare with.
@MainActor
func setSwipeAlpha(_ windowId: UInt32, shown: Bool) {
    let fades = config.animations.enabled && config.animations.fadeMs > 0 && payloadCapabilities.contains("fade")
    let opacity = shown || !fades ? windowOpacity(windowId, focused: false) : 0 // hidden windows are faded out
    sentOpacity[windowId] = opacity
    skylandSa("alpha \(windowId) \(Double(opacity) / 100)")
}

/// The window's opacity at once, no fade (a scratchpad window sliding in).
@MainActor
func showOpaqueNow(_ windowId: UInt32, focused: Bool) {
    let opacity = windowOpacity(windowId, focused: focused)
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
