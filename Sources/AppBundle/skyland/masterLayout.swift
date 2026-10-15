import AppKit
import Common

// skyland: Hyprland master layout, per workspace. The tiling tree of a master
// workspace is kept as [master | vertical stack]: the first window of the tree
// is the master (master-ratio percent wide), new windows go to the bottom of the
// stack (MacWindow binding), and the tree is rebuilt only when it lost that
// shape, so resizing the master holds. `master on|off|toggle` picks the layout of
// the focused workspace (remembered across restarts, master-workspaces at first
// start), `master swap` swaps the focused window with the master (with the top of
// the stack when the master is focused), `master focus` focuses the master.

private let stateFile = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/skyland/master-workspaces")

@MainActor private var masterNames: Set<String>? = nil
@MainActor private var laidOutCount: [String: Int] = [:] // windows at the last rebuild: a new or closed window resets the ratio

@MainActor
private var masters: Set<String> {
    get {
        if let masterNames { return masterNames }
        let saved = (try? String(contentsOf: stateFile, encoding: .utf8)).map { Set($0.split(separator: "\n").map(String.init)) }
        let names = saved ?? Set(config.masterWorkspaces)
        masterNames = names
        return names
    }
    set {
        masterNames = newValue
        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? newValue.sorted().joined(separator: "\n").write(to: stateFile, atomically: true, encoding: .utf8)
    }
}

@MainActor
func isMasterWorkspace(_ workspace: Workspace) -> Bool { masters.contains(workspace.name) }

/// Rebuild the tree as [master | stack] unless it already has that shape.
@MainActor
func applyMasterLayout(_ workspace: Workspace, order: [Window]? = nil) {
    let root = workspace.rootTilingContainer
    let windows = order ?? root.allLeafWindowsRecursive
    guard windows.count >= 2 else { laidOutCount[workspace.name] = windows.count; return }
    if order == nil && hasMasterShape(root, windows) && laidOutCount[workspace.name] == windows.count { return }
    laidOutCount[workspace.name] = windows.count
    // weights are pixels (layoutTiles spreads what is left evenly): split the width
    let ratio = CGFloat(max(10, min(90, config.masterRatio))) / 100
    let width = root.lastAppliedLayoutPhysicalRect?.width ?? workspace.workspaceMonitor.visibleRect.width
    for window in windows { window.unbindFromParent() }
    for child in root.children { child.unbindFromParent() } // emptied containers
    root.layout = .tiles
    root.changeOrientation(.h)
    windows[0].bind(to: root, adaptiveWeight: width * ratio, index: 0)
    if windows.count == 2 {
        windows[1].bind(to: root, adaptiveWeight: width * (1 - ratio), index: INDEX_BIND_LAST)
    } else {
        let stack = TilingContainer(parent: root, adaptiveWeight: width * (1 - ratio), .v, .tiles, index: INDEX_BIND_LAST)
        for window in windows.dropFirst() { window.bind(to: stack, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST) }
    }
}

@MainActor
private func hasMasterShape(_ root: TilingContainer, _ windows: [Window]) -> Bool {
    guard root.layout == .tiles, root.orientation == .h, root.children.count == 2, root.children[0] === windows[0] else { return false }
    if windows.count == 2 { return root.children[1] === windows[1] }
    guard let stack = root.children[1] as? TilingContainer, stack.layout == .tiles, stack.orientation == .v else { return false }
    return stack.children.count == windows.count - 1 && zip(stack.children, windows.dropFirst()).allSatisfy { $0 === $1 }
}

struct MasterCommand: Command {
    let args: MasterCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        let workspace = focus.workspace
        let windows = workspace.rootTilingContainer.allLeafWindowsRecursive
        switch args.action.val {
            case .on, .off, .toggle:
                let on = args.action.val == .toggle ? !isMasterWorkspace(workspace) : args.action.val == .on
                if on { masters.insert(workspace.name) } else { masters.remove(workspace.name) }
                if on { applyMasterLayout(workspace) }
                return .succ
            case .swap:
                guard isMasterWorkspace(workspace), let window = focus.windowOrNil, let index = windows.firstIndex(where: { $0 === window }),
                      windows.count >= 2 else { return .fail(io.err("No master layout or nothing to swap")) }
                var order = windows
                order.swapAt(0, index == 0 ? 1 : index)
                applyMasterLayout(workspace, order: order)
                return .succ
            case .focus:
                guard isMasterWorkspace(workspace), let master = windows.first else { return .fail(io.err("No master layout")) }
                return .from(bool: master.focusWindow())
        }
    }
}
