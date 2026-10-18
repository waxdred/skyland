import Common

public struct ServerEvent: Codable, Sendable {
    private let _event: ServerEventType

    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var windowId: UInt32?
    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var workspace: String?
    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var prevWorkspace: String?
    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var monitorId: Int? // 1-based
    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var appBundleId: String?
    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var appName: String?
    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var mode: String?
    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var binding: String?
    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var targetWorkspace: String?
    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var progress: Double?

    public var eventType: ServerEventType { _event }

    public static func focusChanged(windowId: UInt32?, workspace: String) -> ServerEvent {
        ServerEvent(_event: .focusChanged, windowId: windowId, workspace: workspace)
    }

    public static func focusedMonitorChanged(workspace: String, monitorId_oneBased: Int) -> ServerEvent {
        ServerEvent(_event: .focusedMonitorChanged, workspace: workspace, monitorId: monitorId_oneBased)
    }

    public static func workspaceChanged(workspace: String, prevWorkspace: String) -> ServerEvent {
        ServerEvent(_event: .workspaceChanged, workspace: workspace, prevWorkspace: prevWorkspace)
    }

    public static func modeChanged(mode: String?) -> ServerEvent {
        ServerEvent(_event: .modeChanged, mode: mode)
    }

    public static func windowDetected(windowId: UInt32, workspace: String?, appBundleId: String?, appName: String?) -> ServerEvent {
        ServerEvent(_event: .windowDetected, windowId: windowId, workspace: workspace, appBundleId: appBundleId, appName: appName)
    }

    /// skyland: the fingers moved `workspace` `progress` (0...1) of the way to `target`; no
    /// target: the swipe ended (the switch, if any, follows as focused-workspace-changed).
    /// A bar can move its selection with the fingers.
    public static func workspaceSwipe(workspace: String, target: String?, progress: Double) -> ServerEvent {
        ServerEvent(_event: .workspaceSwipe, workspace: workspace, targetWorkspace: target, progress: progress)
    }

    public static func bindingTriggered(mode: String, binding: String) -> ServerEvent {
        ServerEvent(_event: .bindingTriggered, mode: mode, binding: binding)
    }
}
