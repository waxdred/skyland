import AppKit
import Common

// skyland: Hyprland master layout, per workspace. The tiling tree of a master
// workspace is kept as [master | vertical stack], or [left stack | master | right
// stack] with master-orientation center (auto: on ultrawide screens). The master (master-ratio percent wide), new windows go to the bottom of the
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

/// skyland: workspace rules (`layout = 'master' | 'dwindle'`)
@MainActor
func setMasterWorkspace(_ name: String, _ on: Bool) {
    if on != masters.contains(name) { if on { masters.insert(name) } else { masters.remove(name) } }
}

/// Window order of a master workspace, master first: the tree order is not enough
/// once the master sits in the middle (center orientation).
@MainActor private var orders: [String: [UInt32]] = [:]

/// Master first, then the stack top to bottom; new windows at the end.
@MainActor
func masterOrder(_ workspace: Workspace) -> [Window] {
    let current = workspace.rootTilingContainer.allLeafWindowsRecursive
    let byId = Dictionary(current.map { ($0.windowId, $0) }, uniquingKeysWith: { first, _ in first })
    let known = (orders[workspace.name] ?? []).compactMap { byId[$0] }
    let order = known + current.filter { window in !known.contains { $0 === window } }
    orders[workspace.name] = order.map(\.windowId)
    return order
}

/// Columns of the layout: [master, stack] or, centered, [left stack, master, right
/// stack] with the stack windows alternating right / left (Hyprland center).
@MainActor
private func masterColumns(_ workspace: Workspace, _ order: [Window]) -> [[Window]] {
    let rect = workspace.workspaceMonitor.visibleRect
    let center = switch config.masterOrientation {
        case "center": true
        case "auto": rect.width >= 2 * rect.height // ultrawide
        default: false
    }
    let stack = Array(order.dropFirst())
    guard center, stack.count >= 2 else { return [[order[0]], stack] }
    let right = stack.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
    let left = stack.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
    return [left, [order[0]], right]
}

/// Rebuild the tree to the master columns unless it already has them.
@MainActor
func applyMasterLayout(_ workspace: Workspace, order newOrder: [Window]? = nil) {
    if let newOrder { orders[workspace.name] = newOrder.map(\.windowId) }
    let order = masterOrder(workspace)
    guard order.count >= 2 else { laidOutCount[workspace.name] = order.count; return }
    let root = workspace.rootTilingContainer
    let columns = masterColumns(workspace, order)
    if newOrder == nil && hasColumns(root, columns) && laidOutCount[workspace.name] == order.count { return }
    laidOutCount[workspace.name] = order.count
    // weights are pixels (layoutTiles spreads what is left evenly): split the width
    let ratio = CGFloat(max(10, min(90, config.masterRatio))) / 100
    let width = root.lastAppliedLayoutPhysicalRect?.width ?? workspace.workspaceMonitor.visibleRect.width
    for window in order { window.unbindFromParent() }
    for child in root.children { child.unbindFromParent() } // emptied containers
    root.layout = .tiles
    root.changeOrientation(.h)
    for column in columns {
        let weight = column.first === order[0] ? width * ratio : width * (1 - ratio) / CGFloat(columns.count - 1)
        if column.count == 1 {
            column[0].bind(to: root, adaptiveWeight: weight, index: INDEX_BIND_LAST)
        } else {
            let stack = TilingContainer(parent: root, adaptiveWeight: weight, .v, .tiles, index: INDEX_BIND_LAST)
            for window in column { window.bind(to: stack, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST) }
        }
    }
}

@MainActor
private func hasColumns(_ root: TilingContainer, _ columns: [[Window]]) -> Bool {
    guard root.layout == .tiles, root.orientation == .h, root.children.count == columns.count else { return false }
    return zip(root.children, columns).allSatisfy { node, column in
        if column.count == 1 { return node === column[0] }
        guard let stack = node as? TilingContainer, stack.layout == .tiles, stack.orientation == .v,
              stack.children.count == column.count else { return false }
        return zip(stack.children, column).allSatisfy { $0 === $1 }
    }
}

struct MasterCommand: Command {
    let args: MasterCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        let workspace = focus.workspace
        let windows = masterOrder(workspace)
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
