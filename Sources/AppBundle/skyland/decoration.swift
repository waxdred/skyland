import Common
import Foundation

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
struct Decoration: ConvenienceMutable, Equatable, Sendable {
    var rounding: Int = 0
    var activeOpacity: Int = 100
    var inactiveOpacity: Int = 100

    var isEnabled: Bool { rounding > 0 || activeOpacity != 100 || inactiveOpacity != 100 }
}

private let decorationParser: [String: any ParserProtocol<Decoration>] = [
    "rounding": Parser(\.rounding, parseInt),
    "active-opacity": Parser(\.activeOpacity, parseInt),
    "inactive-opacity": Parser(\.inactiveOpacity, parseInt),
]

func parseDecoration(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> Decoration {
    parseTable(raw, Decoration(), decorationParser, backtrace, &c)
}

// Last value sent per window, so a refresh only sends what changed.
@MainActor private var sentOpacity: [UInt32: Int] = [:]
@MainActor private var sentRounding: [UInt32: Int] = [:]
@MainActor private var seenWindows: Set<UInt32> = []
// The payload recreates its socket on every injection; a Dock restart drops
// what it applied, so a new socket inode means everything must be resent.
@MainActor private var payloadSocketInode: ino_t = 0
// Fades only when the loaded payload says it supports them (asked once per
// injection); an older payload rejects `fade` and opacity would never change.
@MainActor private var payloadCanFade = false
// Windows already there when skyland starts are not faded in: neither during the
// startup refresh nor shortly after (windows can be registered a bit later).
@MainActor private var firstApplyDate: Date? = nil

@MainActor
func applyDecorations() {
    let deco = config.decoration
    let anim = config.animations
    let wantsFades = anim.enabled && anim.fadeMs > 0
    if !deco.isEnabled && !wantsFades && sentOpacity.isEmpty && sentRounding.isEmpty { return }
    var st = stat()
    let inode = unsafe stat(skylandSaSocketPath, &st) == 0 ? st.st_ino : 0
    if inode != payloadSocketInode {
        payloadSocketInode = inode
        sentOpacity = [:]
        sentRounding = [:]
        payloadCanFade = skylandSa("ping", wait: true)?.contains("fade") == true
    }
    let fades = wantsFades && payloadCanFade
    let startedAt = firstApplyDate ?? .now
    firstApplyDate = startedAt
    let startingUp = isStartup || Date.now.timeIntervalSince(startedAt) < 2
    let focusedId = focus.windowOrNil?.windowId
    var alive = Set<UInt32>()
    var newWindows: [UInt32] = []
    for (windowId, window) in MacWindow.allWindowsMap {
        alive.insert(windowId)
        var fadeIn = false
        if seenWindows.insert(windowId).inserted {
            newWindows.append(windowId)
            fadeIn = fades && !startingUp // Hyprland fadeIn
        }
        // Hidden in a corner = workspace switched away: fade out while it slides out
        let opacity = fades && window.isHiddenInCorner ? 0
            : windowId == focusedId ? deco.activeOpacity : deco.inactiveOpacity
        if fadeIn || sentOpacity[windowId, default: 100] != opacity {
            sentOpacity[windowId] = opacity
            // one command: if the payload rejects it, nothing changes (never alpha 0 then fade)
            skylandSa(fades
                ? "fade \(windowId) \(Double(opacity) / 100) \(anim.fadeMs) \(anim.fadeBezier.args)\(fadeIn ? " 0" : "")"
                : "alpha \(windowId) \(Double(opacity) / 100)")
        }
        if sentRounding[windowId, default: 0] != deco.rounding {
            sentRounding[windowId] = deco.rounding
            skylandSa(deco.rounding > 0 ? "corner \(windowId) \(deco.rounding)" : "uncorner \(windowId)")
        }
    }
    sentOpacity = sentOpacity.filter { alive.contains($0.key) }
    sentRounding = sentRounding.filter { alive.contains($0.key) }
    seenWindows = seenWindows.intersection(alive)
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
        }
        applyDecorations()
    }
}

/// Put every window back to stock macOS look, called before quitting.
@MainActor
func restoreDecorations() {
    for windowId in sentOpacity.keys { skylandSa("alpha \(windowId) 1", wait: true) }
    for windowId in sentRounding.keys { skylandSa("uncorner \(windowId)", wait: true) }
    sentOpacity = [:]
    sentRounding = [:]
}

private let skylandSaQueue = DispatchQueue(label: "skyland-sa")
private let skylandSaSocketPath = "/tmp/skyland-sa_\(NSUserName()).socket"

/// Fire-and-forget by default; with `wait` it returns the payload reply
/// ("ok ..." or "err ..."), nil when the scripting addition is not loaded.
@discardableResult
func skylandSa(_ line: String, wait: Bool = false) -> String? {
    let send: @Sendable () -> String? = {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return nil }
        defer { close(fd) }
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
        if connected != 0 { return nil } // scripting addition not loaded
        let msg = line + "\n"
        _ = msg.withCString { unsafe write(fd, $0, strlen($0)) }
        var reply = [UInt8](repeating: 0, count: 64)
        let count = unsafe read(fd, &reply, reply.count)
        return count > 0 ? String(decoding: reply.prefix(count), as: UTF8.self) : nil
    }
    if wait { return skylandSaQueue.sync(execute: send) }
    skylandSaQueue.async { _ = send() }
    return nil
}
