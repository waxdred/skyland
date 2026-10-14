import AppKit
import Common

// skyland: AeroSpace puts every window on the visible workspace when it starts.
// Remember window -> workspace (saved when it changes and on quit) and restore
// it for the windows found at startup. Window ids stay the same while their
// app runs, which is exactly the "skyland restarted" case; the app bundle id
// guards against an id reused by another app.

struct RememberedWindow: Codable, Equatable {
    let workspace: String
    let appId: String?
}

private let memoryUrl = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/skyland/workspaces.json")

@MainActor private var loaded: [UInt32: RememberedWindow]? = nil
@MainActor private var lastSaved: [UInt32: RememberedWindow] = [:]

/// Workspace a window was on before skyland restarted, if any.
@MainActor
func rememberedWorkspace(windowId: UInt32, appId: String?) -> Workspace? {
    if loaded == nil { loaded = loadWorkspaceMemory() }
    guard let entry = loaded?[windowId], entry.appId == appId else { return nil }
    return Workspace.get(byName: entry.workspace)
}

/// Called after every refresh and before quitting; writes only on change.
@MainActor
func saveWorkspaceMemory() {
    // Keep the previous run's memory before the first write: the startup refresh
    // can run before windows are registered and would save an empty map.
    if loaded == nil { loaded = loadWorkspaceMemory() }
    if isStartup { return }
    var current: [UInt32: RememberedWindow] = [:]
    for (windowId, window) in MacWindow.allWindowsMap {
        guard let workspace = window.nodeWorkspace else { continue }
        current[windowId] = RememberedWindow(workspace: workspace.name, appId: window.app.rawAppBundleId)
    }
    if current == lastSaved { return }
    lastSaved = current
    let json = Dictionary(uniqueKeysWithValues: current.map { (String($0.key), $0.value) })
    guard let data = try? JSONEncoder().encode(json) else { return }
    try? FileManager.default.createDirectory(at: memoryUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: memoryUrl, options: .atomic)
}

private func loadWorkspaceMemory() -> [UInt32: RememberedWindow] {
    guard let data = try? Data(contentsOf: memoryUrl),
          let json = try? JSONDecoder().decode([String: RememberedWindow].self, from: data) else { return [:] }
    return Dictionary(uniqueKeysWithValues: json.compactMap { key, value in UInt32(key).map { ($0, value) } })
}
