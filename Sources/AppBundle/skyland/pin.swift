import AppKit
import Common

// skyland: Hyprland pin. A pinned window is a floating window that goes along with every
// workspace switch of its monitor: before each layout it is moved to the workspace its
// monitor shows, so it is never hidden in a corner nor slid out, and keeps its frame.
// Remembered in ~/.cache/skyland/pinned.json (window ids stay the same while their app runs).

private let pinnedUrl = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/skyland/pinned.json")

@MainActor private var pinned: Set<UInt32>? = nil // nil until read from the file

@MainActor
func isPinned(_ window: Window) -> Bool { pinnedWindows.contains(window.windowId) }

@MainActor
private var pinnedWindows: Set<UInt32> {
    get {
        if pinned == nil { pinned = Set((try? JSONDecoder().decode([UInt32].self, from: Data(contentsOf: pinnedUrl))) ?? []) }
        return pinned ?? []
    }
    set {
        guard newValue != pinned else { return }
        pinned = newValue
        try? FileManager.default.createDirectory(at: pinnedUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(newValue.sorted()).write(to: pinnedUrl, options: .atomic)
    }
}

/// Before each layout (refreshModel): pinned windows join the workspace their monitor shows.
@MainActor
func followPinnedWindows() {
    if isStartup { return } // windows are still being registered: don't drop their pins yet
    let alive = pinnedWindows.filter { MacWindow.allWindowsMap[$0] != nil }
    if alive != pinnedWindows { pinnedWindows = alive } // closed windows
    for id in alive {
        guard let window = MacWindow.allWindowsMap[id], let workspace = window.nodeWorkspace else { continue }
        let shown = workspace.workspaceMonitor.activeWorkspace
        if !window.isFloating || workspace != shown { window.bindAsFloatingWindow(to: shown) }
    }
}

struct PinCommand: Command {
    let args: PinCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io), let window = target.windowOrNil else {
            return .fail(io.err("No window"))
        }
        let pin = switch args.toggle {
            case .on: true
            case .off: false
            case .toggle: !isPinned(window)
        }
        if pin {
            if !window.isFloating { _ = await runInternal("layout --window-id \(window.windowId) floating") }
            pinnedWindows.insert(window.windowId)
        } else {
            pinnedWindows.remove(window.windowId) // stays floating where it is
        }
        return .succ
    }
}
