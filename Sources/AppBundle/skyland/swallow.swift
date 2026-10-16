import AppKit
import Common

// skyland: Hyprland window swallowing. A tiled window opened by a program started
// from a terminal (mpv, imv, zathura, a GUI binary run from the shell) takes the
// place of that terminal window, which waits on the hidden workspace
// "scratch-swallowed" and comes back where the window was when it closes.
// Apps started with `open` are children of launchd, not of the shell: no swallow.
//
// [swallow]
// enabled = true
// terminals = ['com.mitchellh.ghostty']   # bundle ids, default: the common terminals
// exceptions = ['org.videolan.vlc']       # apps that never swallow their terminal
struct SwallowConfig: ConvenienceMutable, Equatable, Sendable {
    var enabled: Bool = false
    var terminals: [String] = []
    var exceptions: [String] = []
}

private let swallowParser: [String: any ParserProtocol<SwallowConfig>] = [
    "enabled": Parser(\.enabled, parseBool),
    "terminals": Parser(\.terminals, parseArrayOfStrings),
    "exceptions": Parser(\.exceptions, parseArrayOfStrings),
]

func parseSwallow(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> SwallowConfig {
    parseTable(raw, SwallowConfig(), swallowParser, backtrace, &c)
}

let swallowWorkspaceName = scratchpadWorkspaceName + "-swallowed"

private let defaultTerminals: Set<String> = [
    "com.mitchellh.ghostty", "com.googlecode.iterm2", "com.apple.Terminal", "net.kovidgoyal.kitty",
    "com.github.wez.wezterm", "org.alacritty", "dev.warp.Warp-Stable", "com.raphaelamorim.rio",
]

/// swallowing window id -> the terminal window it hides
@MainActor private var swallowedTerminals: [UInt32: UInt32] = [:]

/// Called once for every new window: swap it with the terminal window it was started from.
@MainActor
func swallowTerminal(for window: MacWindow) {
    let swallow = config.swallow
    guard swallow.enabled, !isStartup, window.parent is TilingContainer, let workspace = window.nodeWorkspace,
          !swallow.exceptions.contains(window.app.rawAppBundleId ?? "") else { return }
    let terminals = swallow.terminals.isEmpty ? defaultTerminals : Set(swallow.terminals)
    let ancestors = ancestorPids(of: window.app.pid)
    let candidates = workspace.allLeafWindowsRecursive.filter {
        $0 !== window && $0.parent is TilingContainer && ancestors.contains($0.app.pid)
            && terminals.contains($0.app.rawAppBundleId ?? "")
    }
    // the terminal you typed in: focused, else the most recent one of that app
    guard let terminal = candidates.first(where: { $0 === focus.windowOrNil })
        ?? candidates.first(where: { $0 === workspace.mostRecentWindowRecursive }) ?? candidates.first
    else { return }
    window.unbindFromParent()
    let slot = terminal.unbindFromParent()
    window.bind(to: slot.parent, adaptiveWeight: slot.adaptiveWeight, index: slot.index)
    terminal.bind(to: Workspace.get(byName: swallowWorkspaceName).rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    window.markAsMostRecentChild()
    swallowedTerminals[window.windowId] = terminal.windowId
}

/// Called when `windowId` closed and left `slot`: its terminal comes back there.
@MainActor
func releaseSwallowedTerminal(of windowId: UInt32, at slot: BindingData) {
    swallowedTerminals = swallowedTerminals.filter { MacWindow.allWindowsMap[$0.value] != nil } // terminals closed meanwhile
    guard let terminalId = swallowedTerminals.removeValue(forKey: windowId),
          let terminal = MacWindow.allWindowsMap[terminalId],
          terminal.nodeWorkspace?.name == swallowWorkspaceName else { return }
    terminal.unbindFromParent()
    if slot.parent.nodeWorkspace != nil {
        terminal.bind(to: slot.parent, adaptiveWeight: slot.adaptiveWeight, index: slot.index)
    } else { // the container went away with the window
        terminal.bind(to: focus.workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }
    terminal.markAsMostRecentChild()
}

/// Parent, grandparent... of `pid`, up to launchd.
func ancestorPids(of pid: pid_t) -> Set<pid_t> {
    var result = Set<pid_t>()
    var current = pid
    while result.count < 64, let parent = parentPid(current), parent > 1, result.insert(parent).inserted {
        current = parent
    }
    return result
}

private func parentPid(_ pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard unsafe sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
}
