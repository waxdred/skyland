import Common
import Foundation

// Hyprland-like window decoration (rounding, active/inactive opacity), applied
// through the skyland scripting addition injected into Dock (see osax/payload.m).
// TOML has no float support in this config parser, so opacity is in percent
// (no fade: WindowServer animated alpha can crash, see osax/payload.m).
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

@MainActor
func applyDecorations() {
    let deco = config.decoration
    if !deco.isEnabled && sentOpacity.isEmpty && sentRounding.isEmpty { return }
    var st = stat()
    let inode = unsafe stat(skylandSaSocketPath, &st) == 0 ? st.st_ino : 0
    if inode != payloadSocketInode {
        payloadSocketInode = inode
        sentOpacity = [:]
        sentRounding = [:]
    }
    let focusedId = focus.windowOrNil?.windowId
    var alive = Set<UInt32>()
    var newWindows: [UInt32] = []
    for windowId in MacWindow.allWindowsMap.keys {
        alive.insert(windowId)
        if seenWindows.insert(windowId).inserted { newWindows.append(windowId) }
        let opacity = windowId == focusedId ? deco.activeOpacity : deco.inactiveOpacity
        if sentOpacity[windowId, default: 100] != opacity {
            sentOpacity[windowId] = opacity
            skylandSa("alpha \(windowId) \(Double(opacity) / 100)")
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

/// Fire-and-forget by default; the payload replies "ok" or "err ...", which we ignore.
func skylandSa(_ line: String, wait: Bool = false) {
    let send: @Sendable () -> Void = {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return }
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
        if connected != 0 { return } // scripting addition not loaded
        let msg = line + "\n"
        _ = msg.withCString { unsafe write(fd, $0, strlen($0)) }
        var reply = [UInt8](repeating: 0, count: 64)
        _ = unsafe read(fd, &reply, reply.count)
    }
    if wait { skylandSaQueue.sync(execute: send) } else { skylandSaQueue.async(execute: send) }
}
