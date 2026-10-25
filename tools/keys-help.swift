// skyland shortcut cheat sheet (alt-shift-h): the [mode.*.binding] tables of the
// config, grouped by their `# section` comments, described by the trailing
// comment of each binding or else its command. Bindings that only differ by a
// digit (cmd-1..cmd-0), or that do the same thing, are shown as one line. Keys
// take the accent of the current skyland theme. Any key or click closes it.
//   skyland-keys [config.toml]   (default ~/.config/skyland/skyland.toml)
// Built by bin/skyland-build.
import AppKit

let path = CommandLine.arguments.dropFirst().first
    ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/skyland/skyland.toml").path
guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
    FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
    exit(1)
}

struct Line { var keys: String, desc: String, pattern: String }
var sections: [(title: String, lines: [Line])] = []

let symbols = ["cmd": "⌘", "alt": "⌥", "ctrl": "⌃", "shift": "⇧", "enter": "↩", "esc": "esc", "tab": "⇥",
               "space": "space", "left": "←", "right": "→", "up": "↑", "down": "↓"]
func pretty(_ key: String) -> String {
    key.split(separator: "-").map { symbols[String($0)] ?? $0.uppercased() }.joined()
}
func describe(_ command: String) -> String {
    command.replacingOccurrences(of: #"^\[|\]$"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: "'", with: "")
        .replacingOccurrences(of: "exec-and-forget ", with: "")
        .replacingOccurrences(of: #"~?/\S*/bin/"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"^open (-n )?-a "?([^"]*)"?$"#, with: "open $2", options: .regularExpression)
        .replacingOccurrences(of: "move-node-to-workspace --focus-follows-window", with: "move window to workspace")
        .replacingOccurrences(of: "--wrap-around ", with: "")
        .replacingOccurrences(of: "mode main", with: "close")
}
func digitsToN(_ s: String) -> String { s.replacingOccurrences(of: #"\d+"#, with: "N", options: .regularExpression) }

// A section starts at the first comment of a block of bindings; a binding with no
// comment after a blank line continues the previous section.
var mode: String? = nil
var pendingTitle: String? = nil
var commentTaken = false
for raw in text.components(separatedBy: "\n") {
    let line = raw.trimmingCharacters(in: .whitespaces)
    if line.hasPrefix("[") {
        mode = line.firstMatch(of: #/^\[mode\.(\w+)\.binding\]/#).map { String($0.1) }
        pendingTitle = mode.map { $0 == "main" ? "general" : "\($0) mode" }
        commentTaken = false
        continue
    }
    guard mode != nil else { continue }
    if line.isEmpty { commentTaken = false; continue }
    if line.hasPrefix("#") {
        if !commentTaken { pendingTitle = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
        commentTaken = true
        continue
    }
    guard let match = line.firstMatch(of: #/^([\w-]+)\s*=\s*(.*?)\s*(?:#\s*(.*))?$/#) else { continue }
    if let title = pendingTitle {
        sections.append((title, []))
        pendingTitle = nil
    }
    commentTaken = true // a comment right under a binding is not a title
    let key = String(match.1), command = describe(String(match.2))
    // "43PR SUPER+L light/dark" -> "light/dark": the 43PR origin is for the config reader
    let comment = (match.3.map(String.init) ?? "").replacingOccurrences(of: #"^43PR:?\s*(SUPER\S*:?\s*)?"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\s*\(43PR[^)]*\)"#, with: "", options: .regularExpression)
    let desc = comment.isEmpty || comment.hasPrefix("(") ? command : comment
    let pattern = digitsToN(key) + "=" + digitsToN(desc)
    let last = sections.count - 1
    if let previous = sections[last].lines.last, previous.pattern == pattern, key.contains(#/\d/#) {
        // cmd-1 .. cmd-0: keep the first key, append the last digit
        let first = String(previous.keys.prefix { $0 != "." })
        sections[last].lines[sections[last].lines.count - 1].keys = first + ".." + String(pretty(key).suffix(1))
        sections[last].lines[sections[last].lines.count - 1].desc = digitsToN(desc).replacingOccurrences(of: ", close", with: "")
    } else if let previous = sections[last].lines.last, previous.desc == desc {
        sections[last].lines[sections[last].lines.count - 1].keys += "  " + pretty(key) // esc / enter: close
    } else {
        sections[last].lines.append(Line(keys: pretty(key), desc: desc, pattern: pattern))
    }
}
sections.removeAll { $0.lines.isEmpty }
// mouse-modifier (Hyprland bindm) is not a binding: shown as its own section
if let match = text.firstMatch(of: #/(?m)^mouse-modifier\s*=\s*'([\w-]+)'/#) {
    let modifier = pretty(String(match.1))
    sections.append(("mouse", [Line(keys: "\(modifier) + drag", desc: "move window (tiles swap on drop)", pattern: ""),
                               Line(keys: "\(modifier) + right drag", desc: "resize window", pattern: "")]))
}

/// accent of the current skyland theme (~/.cache/skyland/theme.css, `@define-color accent #rrggbb;`)
let accent: NSColor = {
    let css = (try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/skyland/theme.css"), encoding: .utf8)) ?? ""
    guard let match = css.firstMatch(of: #/@define-color\s+accent\s+#([0-9A-Fa-f]{6})/#), let hex = Int(match.1, radix: 16) else { return .controlAccentColor }
    return NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}()

final class Sheet: NSView {
    let columnWidth: CGFloat = 440, rowHeight: CGFloat = 22, padding: CGFloat = 24
    let keyFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
    let descFont = NSFont.systemFont(ofSize: 13)
    let titleFont = NSFont.boldSystemFont(ofSize: 15)
    var columns: [[(title: String, lines: [Line])]] = []

    /// Sections packed into columns no taller than maxHeight; returns the sheet size.
    func layout(maxHeight: CGFloat) -> NSSize {
        columns = [[]]
        var height: CGFloat = 0, tallest: CGFloat = 0
        for section in sections {
            let sectionHeight = CGFloat(section.lines.count + 2) * rowHeight
            if height + sectionHeight > maxHeight, !columns[columns.count - 1].isEmpty {
                columns.append([])
                height = 0
            }
            columns[columns.count - 1].append(section)
            height += sectionHeight
            tallest = max(tallest, height)
        }
        return NSSize(width: CGFloat(columns.count) * columnWidth + padding * 2, height: tallest + padding * 2)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        for (index, column) in columns.enumerated() {
            let x = padding + CGFloat(index) * columnWidth
            var y = padding
            for section in column {
                (section.title.uppercased() as NSString).draw(at: NSPoint(x: x, y: y),
                    withAttributes: [.font: titleFont, .foregroundColor: NSColor.secondaryLabelColor])
                y += rowHeight * 1.3
                for line in section.lines {
                    (line.keys as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: keyFont, .foregroundColor: accent])
                    (line.desc as NSString).draw(in: NSRect(x: x + 130, y: y, width: columnWidth - 150, height: rowHeight),
                                            withAttributes: [.font: descFont, .foregroundColor: NSColor.labelColor])
                    y += rowHeight
                }
                y += rowHeight * 0.7
            }
        }
    }
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class App: NSObject, NSApplicationDelegate {
    var panel: KeyPanel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let sheet = Sheet()
        let size = sheet.layout(maxHeight: screen.visibleFrame.height * 0.8)
        panel = KeyPanel(contentRect: NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2,
                                             width: size.width, height: size.height),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .modalPanel // above floating windows raised by skyland
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.masksToBounds = true
        blur.maskImage = roundedMask(radius: 14)
        blur.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor // readable over a bright window
        panel.appearance = NSAppearance(named: .darkAqua)
        sheet.frame = blur.bounds
        blur.addSubview(sheet)
        panel.contentView = blur
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { _ in exit(0) }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func applicationDidResignActive(_ notification: Notification) { exit(0) } // clicked elsewhere
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()

/// Resizable rounded rect mask for NSVisualEffectView.maskImage: it also shapes the
/// window outline and shadow (layer.cornerRadius alone leaves a square edge around).
func roundedMask(radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
}
