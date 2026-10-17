/// The animations of Hyprland's animation tree, by their name in `animation = NAME, ...`.
/// A node without its own line takes its parent's whole line (on / off, speed, curve,
/// style), up to `global`.
public enum AnimationNode: String, CaseIterable, Hashable, Sendable {
    case global
    case windows, windowsIn, windowsOut, windowsMove
    case layers, layersIn, layersOut
    case fade, fadeIn, fadeOut, fadeSwitch, fadeShadow, fadeDim
    case fadeLayers, fadeLayersIn, fadeLayersOut
    case fadePopups, fadePopupsIn, fadePopupsOut, fadeDpms
    case border, borderangle
    case workspaces, workspacesIn, workspacesOut
    case specialWorkspace, specialWorkspaceIn, specialWorkspaceOut
    case zoomFactor, monitorAdded

    public var parent: AnimationNode? {
        switch self {
            case .global: nil
            case .windows, .layers, .fade, .border, .borderangle, .workspaces, .zoomFactor, .monitorAdded: .global
            case .windowsIn, .windowsOut, .windowsMove: .windows
            case .layersIn, .layersOut: .layers
            case .fadeIn, .fadeOut, .fadeSwitch, .fadeShadow, .fadeDim, .fadeLayers, .fadePopups, .fadeDpms: .fade
            case .fadeLayersIn, .fadeLayersOut: .fadeLayers
            case .fadePopupsIn, .fadePopupsOut: .fadePopups
            case .workspacesIn, .workspacesOut, .specialWorkspace: .workspaces
            case .specialWorkspaceIn, .specialWorkspaceOut: .specialWorkspace
        }
    }

    /// Hyprland animations with nothing to animate on macOS (shadows, Wayland popups, DPMS,
    /// screen zoom): accepted, so that a block pasted from hyprland.conf loads, and ignored.
    public var isIgnoredOnMacOS: Bool {
        switch self {
            case .fadeShadow, .fadePopups, .fadePopupsIn, .fadePopupsOut, .fadeDpms, .zoomFactor, .monitorAdded: true
            default: false
        }
    }

    /// Whether `style` can be this node's style: window and workspace styles for windows,
    /// layers and workspaces, once / loop for borderangle, none for the others.
    public func accepts(_ style: AnimationStyle) -> Bool {
        switch self {
            case .borderangle:
                style == .once || style == .loop
            case .windows, .windowsIn, .windowsOut, .windowsMove, .layers, .layersIn, .layersOut,
                 .workspaces, .workspacesIn, .workspacesOut, .specialWorkspace, .specialWorkspaceIn, .specialWorkspaceOut:
                style != .once && style != .loop
            default:
                false
        }
    }
}
