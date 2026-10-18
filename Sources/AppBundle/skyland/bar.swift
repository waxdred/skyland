import AppKit
import Common

// skyland: the sketchybar workspaces and focused window title, pushed by skyland when
// they change, with one `sketchybar` process. A script used to run on every
// on-focus-changed, exec-on-workspace-change and front_app_switched (up to 3 runs per
// change), each with 4 CLI calls and about 20 processes. The items are created by
// profiles/hypr/sketchybar/skyland.sh, which still runs update.sh on skyland_update
// (theme changes, sketchybar reloads).

private let sketchybarPath = ["/opt/homebrew/bin/sketchybar", "/usr/local/bin/sketchybar"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }
/// skyland-env writes the profile before it starts the app
private let barProfileActive = (try? String(contentsOfFile: NSHomeDirectory() + "/.config/.skyland-profile", encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines) == "hypr"

private struct BarState: Equatable {
    var monitorOfWorkspace: [String: Int] // existing workspaces
    var focused: String
    var title: String
}

@MainActor private var pushed: BarState? = nil
@MainActor private var titleWindowId: UInt32? = nil
@MainActor private var title = "Desktop"

/// Called after every model refresh: pushes only when the bar would change.
@MainActor
func updateBar() {
    guard let sketchybarPath, barProfileActive, TrayMenuModel.shared.isEnabled else { return }
    let window = focus.windowOrNil
    if window?.windowId != titleWindowId {
        titleWindowId = window?.windowId
        title = "Desktop"
        if let window { // the title is an AX call: fetched once per focused window
            let id = window.windowId
            Task { @MainActor in
                let windowTitle = (try? await window.getTitle(.cancellable)) ?? ""
                guard titleWindowId == id else { return }
                title = barTitle(app: window.app.name, windowTitle)
                updateBar()
            }
        }
    }
    var monitors: [String: Int] = [:]
    for workspace in Workspace.all { monitors[workspace.name] = workspace.workspaceMonitor.monitorId_oneBased ?? 0 }
    let state = BarState(monitorOfWorkspace: monitors, focused: focus.workspace.name, title: title)
    if state == pushed { return }
    pushed = state

    let c = barColors()
    var args: [String] = []
    for i in 1 ... 12 {
        let name = String(i), item = "workspace.\(i)"
        args += ["--set", item, "display=\(state.monitorOfWorkspace[name].map(String.init) ?? "active")"]
        args += name == state.focused
            ? ["--set", item, "drawing=on", "icon.color=\(c["ACCENT"]!)", "background.color=\(c["ITEM_BG_ACTIVE"]!)", "background.border_color=\(c["BORDER_ACTIVE"]!)"]
            : state.monitorOfWorkspace[name] != nil
            ? ["--set", item, "drawing=on", "icon.color=\(c["TEXT_DIM"]!)", "background.color=\(c["ITEM_BG"]!)", "background.border_color=\(c["BORDER"]!)"]
            : ["--set", item, "drawing=off"]
    }
    args += ["--set", "window_title", "label=\(state.title)"] // optional item: last, sketchybar goes on past a missing one
    let process = Process()
    process.executableURL = URL(fileURLWithPath: sketchybarPath)
    process.arguments = args
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
}

/// Same as update.sh: "App: title", 40 characters at most, "Desktop" without a window
func barTitle(app: String?, _ title: String) -> String {
    if title.isEmpty { return "Desktop" }
    let short = title.count > 40 ? title.prefix(37) + "..." : title
    return (app.map { "\($0): " } ?? "") + short
}

/// ~/.cache/skyland/theme.env (skyland-theme), Catppuccin like update.sh otherwise.
/// ponytail: read on each push (a small file, only when the bar changes)
private func barColors() -> [String: String] {
    var colors = ["TEXT_DIM": "0xffa5adcb", "ACCENT": "0xffc6a0f6", "ITEM_BG": "0xff363a4f",
                  "ITEM_BG_ACTIVE": "0xff5b6078", "BORDER": "0xff5b6078", "BORDER_ACTIVE": "0xffc6a0f6"]
    let env = (try? String(contentsOfFile: NSHomeDirectory() + "/.cache/skyland/theme.env", encoding: .utf8)) ?? ""
    for line in env.split(separator: "\n") where !line.hasPrefix("#") {
        let parts = line.split(separator: "=", maxSplits: 1)
        if parts.count == 2, colors[String(parts[0])] != nil { colors[String(parts[0])] = String(parts[1]) }
    }
    return colors
}

/// `mode-indicator = 'bar'`: the `skyland.mode` item (profiles/hypr/sketchybar/skyland.sh)
/// shows the mode, and `skyland_mode` is triggered with MODE=<name> ("" back in main).
@MainActor
func updateBarMode(_ mode: String?) {
    guard let sketchybarPath else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: sketchybarPath)
    process.arguments = ["--trigger", "skyland_mode", "MODE=\(mode ?? "")", "--set", "skyland.mode"]
        + (mode.map { ["drawing=on", "label=\($0.uppercased())"] } ?? ["drawing=off"])
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
}

/// skylandbar (github.com/waxdred/skylandBar), when installed, starts with skyland if it
/// is not running yet: at login the LaunchAgent (`skyland env`) or the login item starts
/// skyland only, and launchd kills whatever a LaunchAgent leaves running. Without it,
/// sketchybar is left to its own login service.
@MainActor
func startSkylandBar() {
    let candidates = [NSHomeDirectory() + "/.local/bin/skylandbar", "/opt/homebrew/bin/skylandbar", "/usr/local/bin/skylandbar"]
    guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)), !isSkylandBarRunning() else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
}

/// skylandbar holds an exclusive lock on this file while it runs (its main.swift): taken, a
/// bar runs, whatever started it (a terminal, a login item); not every bar shows in
/// NSWorkspace's running applications.
private func isSkylandBarRunning() -> Bool {
    let fd = open("/tmp/skylandbar-\(NSUserName()).lock", O_RDWR)
    guard fd >= 0 else { return false } // never started
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return true }
    flock(fd, LOCK_UN)
    return false
}
