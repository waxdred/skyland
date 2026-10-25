import AppKit
import Common

// skyland: a name for a group (accordion container), shown at the start of its tabs bar
// (groupBar.swift). `group-rename <name>` sets it, `group-rename` alone or a double click on
// the tabs bar asks for it in a popup in the panels' style (metal / glass): enter keeps it,
// esc cancels, an empty name removes it.
//
// A name belongs to the windows of its group, not to the container object: AeroSpace
// rebuilds containers as the tree is normalized (a second group made around the first one
// nests them), and a name kept by container stayed on the wrong one, or came back on a new
// container at a freed address (two groups with the same name).
// ponytail: in memory, gone when skyland restarts; persist by window id if that matters

/// A name and the windows of its group when last seen.
struct NamedGroup: Equatable {
    var name: String
    var windows: Set<UInt32>
}

@MainActor var namedGroups: [NamedGroup] = []
/// The names given to the groups now (matchGroupNames), by container: for drawing.
@MainActor var groupNames: [ObjectIdentifier: String] = [:]

/// Which group gets which name: the pairs whose windows overlap the most first (shared /
/// all of both, so an inner group and the outer one around it stay apart), each name on one
/// group and each group with one name. Returns the group index of each name, nil for a name
/// whose windows are in no group any more.
func matchGroupNames(_ names: [Set<UInt32>], _ groups: [Set<UInt32>]) -> [Int?] {
    var pairs: [(score: Double, name: Int, group: Int)] = []
    for (n, a) in names.enumerated() {
        for (g, b) in groups.enumerated() {
            let shared = a.intersection(b).count
            if shared > 0 { pairs.append((Double(shared) / Double(a.union(b).count), n, g)) }
        }
    }
    var result = [Int?](repeating: nil, count: names.count), taken = Set<Int>()
    for pair in pairs.sorted(by: { $0.score > $1.score }) where result[pair.name] == nil && !taken.contains(pair.group) {
        result[pair.name] = pair.group
        taken.insert(pair.group)
    }
    return result
}

/// Every group of every workspace with its windows.
@MainActor
private func allGroups() -> [(TilingContainer, Set<UInt32>)] {
    var groups: [(TilingContainer, Set<UInt32>)] = []
    func collect(_ container: TilingContainer) {
        if container.layout == .accordion { groups.append((container, Set(container.allLeafWindowsRecursive.map(\.windowId)))) }
        for child in container.children { if let sub = child as? TilingContainer { collect(sub) } }
    }
    for workspace in Workspace.all { collect(workspace.rootTilingContainer) }
    return groups
}

/// The names given to the groups as they are now; a name follows its group's windows, and
/// goes with the last of them.
@MainActor
func refreshGroupNames() {
    let groups = allGroups()
    let match = matchGroupNames(namedGroups.map(\.windows), groups.map(\.1))
    var kept: [NamedGroup] = [], names: [ObjectIdentifier: String] = [:]
    for (entry, index) in zip(namedGroups, match) {
        guard let index else { continue }
        kept.append(NamedGroup(name: entry.name, windows: groups[index].1))
        names[ObjectIdentifier(groups[index].0)] = entry.name
    }
    namedGroups = kept
    groupNames = names
}

/// The nearest group of a window: its accordion parent, or a grandparent's.
@MainActor
func groupOf(_ window: Window) -> TilingContainer? {
    var node: TreeNode = window
    while let parent = node.parent as? TilingContainer {
        if parent.layout == .accordion { return parent }
        node = parent
    }
    return nil
}

struct GroupRenameCommand: Command {
    let args: GroupRenameCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let window = focus.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
        guard let group = groupOf(window) else { return .fail(io.err("The focused window is not in a group")) }
        if let name = args.name {
            setGroupName(group, name)
        } else {
            askGroupName(group, refocus: window.windowId)
        }
        return .succ
    }
}

@MainActor
func setGroupName(_ group: TilingContainer, _ name: String) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    refreshGroupNames()
    let windows = Set(group.allLeafWindowsRecursive.map(\.windowId))
    if let old = groupNames[ObjectIdentifier(group)], let index = namedGroups.firstIndex(where: { $0.name == old && $0.windows == windows }) {
        namedGroups.remove(at: index) // its previous name
    }
    if !name.isEmpty { namedGroups.append(NamedGroup(name: name, windows: windows)) }
    refreshGroupNames()
    scheduleGroupBarsRefresh()
}

@MainActor private var renamePanel: RenamePanel?

/// The popup, centered on the group (its laid out rect), or on the screen.
@MainActor
func askGroupName(_ group: TilingContainer, refocus windowId: UInt32?) {
    renamePanel?.finish(nil)
    refreshGroupNames()
    let panel = RenamePanel(current: groupNames[ObjectIdentifier(group)] ?? "") { name in
        if let name { setGroupName(group, name) }
        renamePanel = nil
        // the panel took the keyboard: back to the window that had it
        if let windowId { Task { @MainActor in await runSkylandCommand("focus --window-id \(windowId)") } }
    }
    renamePanel = panel
    let mainHeight = NSScreen.screens.first?.frame.maxY ?? 0
    let area = group.lastAppliedLayoutPhysicalRect.map {
        NSRect(x: $0.topLeftX, y: mainHeight - $0.topLeftY - $0.height, width: $0.width, height: $0.height)
    } ?? (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
    panel.show(centeredIn: area)
}

/// A small key panel: a title and a text field, in the panels' style.
@MainActor
private final class RenamePanel: NSPanel, NSTextFieldDelegate {
    private let field = NSTextField()
    private let done: (String?) -> Void
    private var finished = false

    init(current: String, done: @escaping (String?) -> Void) {
        self.done = done
        let size = NSSize(width: 340, height: 92)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .modalPanel
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let root = makePanelRoot(radius: 20, for: self)
        root.frame = NSRect(origin: .zero, size: size)
        root.autoresizingMask = [.width, .height]
        for sub in root.subviews { sub.frame = root.bounds; sub.autoresizingMask = [.width, .height] } // the glass shape
        let theme = skylandThemeColors()
        let fg = theme["fg"] ?? .white, dim = theme["fg_dim"] ?? .lightGray
        let title = NSTextField(labelWithString: PanelFont.caps("Group name"))
        title.font = isGlyphStyle ? PanelFont.label(11, weight: .bold) : .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = dim
        title.frame = NSRect(x: 18, y: size.height - 32, width: size.width - 36, height: 16)
        field.stringValue = current
        field.placeholderString = "empty: no name"
        field.font = PanelFont.text(15, weight: .medium)
        field.textColor = fg
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = isGlyphStyle ? theme["bg_card"] ?? .black : (theme["bg"] ?? .black).withAlphaComponent(0.35)
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.cornerRadius = 8
        field.delegate = self
        field.frame = NSRect(x: 16, y: 18, width: size.width - 32, height: 28)
        root.addSubview(title)
        root.addSubview(field)
        contentView = root
        if let bg = theme["bg"]?.usingColorSpace(.sRGB) { appearance = NSAppearance(named: bg.brightnessComponent < 0.5 ? .darkAqua : .aqua) }
    }

    override var canBecomeKey: Bool { true }

    func show(centeredIn area: NSRect) {
        setFrameOrigin(NSPoint(x: area.midX - frame.width / 2, y: area.midY - frame.height / 2))
        NSApp.activate(ignoringOtherApps: true) // the typed keys come to the active app's key panel
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Enter keeps the name, esc cancels.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
            case #selector(NSResponder.insertNewline(_:)): finish(field.stringValue)
            case #selector(NSResponder.cancelOperation(_:)): finish(nil)
            default: return false
        }
        return true
    }

    /// Clicked elsewhere: cancelled, as a menu would be.
    override func resignKey() {
        super.resignKey()
        finish(nil)
    }

    func finish(_ name: String?) {
        guard !finished else { return }
        finished = true
        orderOut(nil)
        done(name)
    }
}
