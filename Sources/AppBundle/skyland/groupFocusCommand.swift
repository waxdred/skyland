import AppKit
import Common

/// `group-focus next|prev`: the next / previous tab of the nearest group
/// (accordion container) of the focused window, wrapping around.
struct GroupFocusCommand: Command {
    let args: GroupFocusCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let window = focus.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
        var node: TreeNode = window
        while let parent = node.parent as? TilingContainer {
            if parent.layout == .accordion, let index = parent.children.firstIndex(where: { $0 === node }) {
                let step = args.direction.val == .next ? 1 : -1
                let target = parent.children[(index + step + parent.children.count) % parent.children.count]
                let targetWindow = (target as? Window) ?? target.mostRecentWindowRecursive
                return .from(bool: targetWindow?.focusWindow() ?? false)
            }
            node = parent
        }
        return .fail(io.err("The focused window is not in a group"))
    }
}
