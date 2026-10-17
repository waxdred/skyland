import AppKit

// skyland: with the macOS menu bar set to hide automatically, sketchybar
// (topmost=on, so its workspace icons get the clicks) covers the menu bar when it
// slides in on hover. While a Menubar window is on screen (a hidden one is off
// screen at y = -height), sketchybar is hidden so the native menu bar is usable, and shown again
// once the menu bar slides back up.
// The window list is only polled while the cursor is near the top of a screen (the
// menu bar slides in from there) or while the menu bar is down: a mouse move
// monitor starts the poll, the poll stops itself once both are over.

@MainActor private var peekTimer: Timer? = nil
@MainActor private var mouseMonitor: Any? = nil
@MainActor private var settingDate = Date.distantPast
@MainActor private var barHidden = false
@MainActor private var menuBarAutoHides = false

private let sketchybar = ["/opt/homebrew/bin/sketchybar", "/usr/local/bin/sketchybar"].first { FileManager.default.isExecutableFile(atPath: $0) }

@MainActor
func startMenuBarPeek() {
    guard sketchybar != nil, mouseMonitor == nil else { return }
    mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { _ in
        MainActor.assumeIsolated { if peekTimer == nil && cursorNearTop() { startPeekTimer() } }
    }
    checkMenuBar() // shown at startup
}

@MainActor
private func startPeekTimer() {
    peekTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
        MainActor.assumeIsolated {
            checkMenuBar()
            if !barHidden && !cursorNearTop() { peekTimer?.invalidate(); peekTimer = nil }
        }
    }
}

/// The cursor is in the top 40 points of its screen (the menu bar is 24 to 37 high)
@MainActor
private func cursorNearTop() -> Bool {
    let mouse = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) else { return false }
    return mouse.y >= screen.frame.maxY - 40
}

@MainActor
private func checkMenuBar() {
    if Date.now.timeIntervalSince(settingDate) > 5 {
        settingDate = .now
        menuBarAutoHides = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["_HIHideMenuBar"] as? Bool == true
    }
    guard menuBarAutoHides else {
        if barHidden { setBarHidden(false) }
        return
    }
    // a hidden menu bar is off screen; it is on screen from the moment it starts sliding in
    let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let down = onScreen.contains { $0[kCGWindowOwnerName as String] as? String == "Window Server" && $0[kCGWindowName as String] as? String == "Menubar" }
    if down != barHidden { setBarHidden(down) }
}

@MainActor
private func setBarHidden(_ hidden: Bool, wait: Bool = false) {
    barHidden = hidden
    guard let sketchybar else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: sketchybar)
    process.arguments = ["--bar", "hidden=\(hidden ? "on" : "off")"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    if wait { process.waitUntilExit() }
}

/// Called before quitting: never leave sketchybar hidden.
@MainActor
func stopMenuBarPeek() {
    peekTimer?.invalidate()
    peekTimer = nil
    if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    mouseMonitor = nil
    if barHidden { setBarHidden(false, wait: true) }
}
