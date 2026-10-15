// skyland: Hyprland-like scratchpad (special workspace), driven by bin/skyland-scratch.
// Its windows live on the hidden workspace "scratch", which workspace prev/next
// and the overview skip.

let scratchpadWorkspaceName = "scratch"

extension Workspace {
    var isScratchpad: Bool { name == scratchpadWorkspaceName }
}
