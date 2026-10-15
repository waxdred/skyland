// skyland: Hyprland-like scratchpad (special workspace), driven by bin/skyland-scratch.
// Its windows live on the hidden workspaces "scratch" / "scratch-<name>", which
// workspace prev/next, the overview and the Rules tab skip.

let scratchpadWorkspaceName = "scratch"

extension Workspace {
    /// "scratch" and the named scratchpads "scratch-<name>"
    var isScratchpad: Bool { name == scratchpadWorkspaceName || name.hasPrefix(scratchpadWorkspaceName + "-") }
}
