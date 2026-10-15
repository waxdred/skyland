import AppKit

// skyland: with the macOS menu bar set to hide automatically, sketchybar
// (topmost=on, so its workspace icons get the clicks) covers the menu bar when it
// slides in on hover. While a menu bar window is down (its y >= 0, -height when
// hidden), sketchybar is hidden so the native menu bar is usable, and shown again
// once the menu bar slides back up.

@MainActor private var peekTimer: Timer? = nil
@MainActor private var menuBarIds: [CGWindowID] = []
@MainActor private var menuBarIdsDate = Date.distantPast
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
    if Date.now.timeIntervalSince(menuBarIdsDate) > 5 { // displays and settings change
        menuBarIdsDate = .now
        menuBarAutoHides = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["_HIHideMenuBar"] as? Bool == true
        let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        menuBarIds = all.filter { $0[kCGWindowOwnerName as String] as? String == "Window Server" && $0[kCGWindowName as String] as? String == "Menubar" }
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
    }
    guard menuBarAutoHides else {
        if barHidden { setBarHidden(false) }
        return
    }
    guard !menuBarIds.isEmpty,
          let windows = CGWindowListCreateDescriptionFromArray(menuBarIds.map { UnsafeRawPointer(bitPattern: UInt($0)) } as CFArray) as? [[String: Any]]
    else { return }
    let down = windows.contains { window in
        guard let bounds = window[kCGWindowBounds as String] as? [String: Any], let y = (bounds["Y"] as? NSNumber)?.doubleValue else { return false }
        return y > -1 // slid in (a hidden menu bar sits at -height)
    }
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
