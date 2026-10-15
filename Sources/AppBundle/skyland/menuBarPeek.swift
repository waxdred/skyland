import AppKit

// skyland: with the macOS menu bar set to hide automatically, sketchybar
// (topmost=on, so its workspace icons get the clicks) covers the menu bar when it
// slides in on hover. While a Menubar window is on screen (a hidden one is off
// screen at y = -height), sketchybar is hidden so the native menu bar is usable, and shown again
// once the menu bar slides back up.

@MainActor private var peekTimer: Timer? = nil
@MainActor private var settingDate = Date.distantPast
@MainActor private var barHidden = false
@MainActor private var menuBarAutoHides = false

private let sketchybar = ["/opt/homebrew/bin/sketchybar", "/usr/local/bin/sketchybar"].first { FileManager.default.isExecutableFile(atPath: $0) }

@MainActor
func startMenuBarPeek() {
    guard sketchybar != nil, peekTimer == nil else { return }
    peekTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
        MainActor.assumeIsolated { checkMenuBar() }
    }
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
    if barHidden { setBarHidden(false, wait: true) }
}
