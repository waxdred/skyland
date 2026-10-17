import AppKit
import SkylandAnimation

// skyland-anim: plays the SkylandAnimation styles on a real window, to try them before the
// module is wired into skyland. It sends the track to the Dock payload itself, so the
// payload needs the `track` command: `skyland sa build && skyland sa load` (then
// `skyland sa send ping` answers "... track").

let usage = """
    usage: skyland-anim <style> [event] [options]
           skyland-anim --preset <name> [event] [options]
           skyland-anim list

    style    slide [top|bottom|left|right] | slidevert | popin [N%] | gnomed | fade
             | slidefade [N%] | slidefadevert [N%] | cyberspace
    event    open (default) | close | in | out | special-in | special-out | move
             (in / out: its workspace is shown / switched away; close and out put the
             window back at the end, nothing is closed or hidden)
    options  --window <id>     the window (skyland list-windows), default: the frontmost one
             --ms <duration>   the animation's duration (a style, not a preset)
             --dir 1|-1        workspace switches: towards a higher / lower workspace
             --opacity <0..1>  the window's opacity at rest (default 1)
             --no-overlay      cyberspace without its neon frame
             --print           print the payload command instead of sending it
    """

let socketPath = "/tmp/skyland-sa_\(NSUserName()).socket"

@main
struct SkylandAnim {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments.first == "-h" || arguments.first == "--help" {
            print(usage)
            return
        }
        if arguments == ["list"] {
            print("styles: slide [top|bottom|left|right], slidevert, popin [N%], gnomed, fade, slidefade [N%], slidefadevert [N%], cyberspace")
            print("events: open, close, in, out, special-in, special-out, move")
            print("presets:")
            for preset in AnimationPreset.all { print("  \(preset.name): \(preset.summary)") }
            return
        }

        var windowId: UInt32? = nil
        var durationMs: Double? = nil
        var direction: Double? = nil
        var opacity = 1.0
        var overlay = true
        var printOnly = false
        var presetName: String? = nil
        var words: [String] = []
        var index = 0
        func value(of option: String) -> String {
            index += 1
            guard index < arguments.count else { fail("\(option) needs a value") }
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
                case "--window":
                    guard let id = UInt32(value(of: argument)) else { fail("--window takes a window id (skyland list-windows)") }
                    windowId = id
                case "--ms":
                    guard let ms = Double(value(of: argument)), ms > 0 else { fail("--ms takes a duration in milliseconds") }
                    durationMs = ms
                case "--dir":
                    guard let dir = Double(value(of: argument)) else { fail("--dir takes 1 or -1") }
                    direction = dir < 0 ? -1 : 1
                case "--opacity":
                    guard let alpha = Double(value(of: argument)), (0 ... 1).contains(alpha) else { fail("--opacity takes a number in 0...1") }
                    opacity = alpha
                case "--preset":
                    presetName = value(of: argument)
                case "--no-overlay":
                    overlay = false
                case "--print":
                    printOnly = true
                default:
                    if argument.hasPrefix("--") { fail("unknown option \(argument)\n\n\(usage)") }
                    words.append(argument)
            }
            index += 1
        }

        // the event: the last word when it names one
        let events = ["open", "close", "in", "out", "special-in", "special-out", "move"]
        let eventName = words.last.flatMap { events.contains($0) ? $0 : nil } ?? "open"
        if words.last == eventName { words.removeLast() }

        let settings: AnimationSettings
        if let presetName {
            guard let preset = AnimationPreset.named(presetName) else {
                fail("no preset '\(presetName)': \(AnimationPreset.all.map(\.name).joined(separator: ", "))")
            }
            if !words.isEmpty { fail("a preset or a style, not both") }
            settings = preset.settings
        } else {
            let styleText = words.joined(separator: " ")
            guard let style = AnimationStyle.parse(styleText), style != .once, style != .loop else {
                fail("no style '\(styleText)'\n\n\(usage)")
            }
            let ds = (durationMs ?? (style == .cyberspace ? 550 : 500)) / 100
            let parsed = AnimationSettings.parse(
                bezier: ["overshot, 0.05, 0.9, 0.1, 1.05"],
                animation: [
                    "windows, 1, \(ds), overshot, \(styleText)",
                    "windowsMove, 1, \(ds), overshot",
                    "fade, 1, \(ds * 0.7), default",
                    "workspaces, 1, \(ds), default, \(styleText)",
                    "specialWorkspace, 1, \(ds), overshot, \(styleText)",
                ],
            )
            if let error = parsed.diagnostics.first(where: \.isError) { fail(error.description) }
            settings = parsed.settings
        }

        guard let window = findWindow(windowId) else {
            fail(windowId.map { "no window \($0) on screen" } ?? "no window of the frontmost app")
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let screens = NSScreen.screens.map {
            AnimRect(x: $0.frame.minX, y: primaryHeight - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height)
        }
        let monitor = screens.first { $0.contains(x: window.rect.midX, y: window.rect.midY) } ?? screens.first ?? window.rect
        let event: WindowEvent = switch eventName {
            case "close": .close
            case "in": .workspaceIn
            case "out": .workspaceOut
            case "special-in": .specialIn
            case "special-out": .specialOut
            case "move": .move(from: window.rect.offsetBy(dx: -0.15 * monitor.width, dy: 0))
            default: .open
        }
        // a scratchpad comes from the top and goes back to it, like skyland's
        let side = direction ?? (event == .specialIn || event == .specialOut ? -1 : 1)
        let context = WindowContext(windowId: window.id, rect: window.rect, monitor: monitor, direction: side, opacity: opacity,
                                    neighbourEdges: monitor.neighbourEdges(among: screens))
        let animator = WindowAnimator(settings: settings)
        guard let track = animator.track(for: event, context) else { fail("that animation is off for \(event.node.rawValue)") }
        if printOnly {
            print(track.payloadCommand)
            return
        }
        guard sendToPayload(["ping"]).first?.split(separator: " ").contains("track") == true else {
            fail("the Dock payload is not loaded or has no `track` command: skyland sa build && skyland sa load")
        }
        let reply = sendToPayload([track.payloadCommand]).first ?? "no reply"
        guard reply == "ok" else { fail("the payload refused the track: \(reply)") }

        let style = animator.effectiveStyle(event, settings.resolve(event.node).style, context)
        if overlay && style == .cyberspace {
            NSApplication.shared.setActivationPolicy(.accessory)
            CyberspaceOverlay.play(around: window.rect, durationMs: track.durationMs, leaving: event.isLeaving, color: themeAccent(),
                                   level: window.level, above: window.id)
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: (track.durationMs + 150) / 1000))
        if event.isLeaving {
            // the window was not really closed or hidden: back to how it was
            sendToPayload(["untransform \(window.id)", "alpha \(window.id) \(opacity)", "dim \(window.id) 0"])
        }
        print("\(style) \(eventName) on \(window.owner) (\(window.id)): \(track.samples.count) samples over \(Int(track.durationMs)) ms")
    }

    /// The window `id` (or the frontmost app's frontmost window): id, owner, frame (top-left
    /// origin, global) and level.
    static func findWindow(_ id: UInt32?) -> (id: UInt32, owner: String, rect: AnimRect, level: Int)? {
        let list = id.map { CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID($0)) }
            ?? CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for info in list as? [[String: Any]] ?? [] {
            guard let number = info[kCGWindowNumber as String] as? UInt32,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.width > 1, frame.height > 1 else { continue }
            let level = info[kCGWindowLayer as String] as? Int ?? 0
            if id == nil && (level != 0 || info[kCGWindowOwnerPID as String] as? pid_t != frontPid) { continue }
            let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
            return (number, owner, AnimRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height), level)
        }
        return nil
    }

    /// The accent of the current skyland theme (~/.cache/skyland/theme.css), cyan without one.
    static func themeAccent() -> CGColor {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/skyland/theme.css")
        if let css = try? String(contentsOf: url, encoding: .utf8),
           let match = css.firstMatch(of: /@define-color\s+accent\s+#([0-9A-Fa-f]{6})/),
           let hex = Int(match.1, radix: 16)
        {
            return CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return CGColor(srgbRed: 0.24, green: 0.9, blue: 1, alpha: 1)
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("skyland-anim: " + message + "\n").utf8))
        exit(1)
    }
}

/// One connection to the Dock payload: the lines, then their replies (none when it is not
/// loaded). The same as skyland's (Sources/AppBundle/skyland/decoration.swift).
@discardableResult
func sendToPayload(_ lines: [String]) -> [String] {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { return [] }
    defer { close(fd) }
    var on: Int32 = 1
    unsafe setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        _ = socketPath.utf8CString.withUnsafeBytes { src in
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
