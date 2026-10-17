import AppKit
import Common

// skyland: Hyprland gestures:workspace_swipe, first version: a swipe with N fingers on the
// trackpad switches the screen under the cursor to its previous / next workspace once
// the fingers travelled `cancel-ratio` percent of `distance` (one switch per swipe, with
// the regular workspace animation). Fingers to the left (or up) go to the next one, like
// macOS Spaces.
//
// [gestures]
// workspace-swipe = false
// workspace-swipe-fingers = 3               # 3 | 4: turn the macOS gesture with as many fingers off
// workspace-swipe-direction = 'horizontal'  # | 'vertical'
// workspace-swipe-distance = 200            # finger travel in points (trackpad) of a whole switch
// workspace-swipe-cancel-ratio = 50         # percent of the distance that switches
// workspace-swipe-invert = false
struct Gestures: ConvenienceMutable, Equatable, Sendable {
    var workspaceSwipe = false
    var fingers = 3
    var direction = "horizontal"
    var distance = 200
    var cancelRatio = 50
    var invert = false
}

private let gesturesParser: [String: any ParserProtocol<Gestures>] = [
    "workspace-swipe": Parser(\.workspaceSwipe, parseBool),
    "workspace-swipe-fingers": Parser(\.fingers, parseInt),
    "workspace-swipe-direction": Parser(\.direction) { raw, backtrace in
        parseString(raw, backtrace).flatMap { value in
            ["horizontal", "vertical"].contains(value) ? .success(value)
                : .failure(.init(backtrace, "Expected 'horizontal' or 'vertical', got '\(value)'"))
        }
    },
    "workspace-swipe-distance": Parser(\.distance, parseInt),
    "workspace-swipe-cancel-ratio": Parser(\.cancelRatio, parseInt),
    "workspace-swipe-invert": Parser(\.invert, parseBool),
]

func parseGestures(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> Gestures {
    parseTable(raw, Gestures(), gesturesParser, backtrace, &c)
}

@MainActor private var gestureMonitor: Any? = nil
/// The swipe in progress: where the fingers started (along its axis), and if it switched already
@MainActor private var swipe: (start: CGFloat, switched: Bool)? = nil

/// On at startup and on config reload when `workspace-swipe` is on.
@MainActor
func syncGestures(_ config: Config) {
    if config.gestures.workspaceSwipe == (gestureMonitor != nil) { return }
    if let gestureMonitor {
        NSEvent.removeMonitor(gestureMonitor)
        swipe = nil
    }
    gestureMonitor = config.gestures.workspaceSwipe
        ? NSEvent.addGlobalMonitorForEvents(matching: .gesture) { event in MainActor.assumeIsolated { handleGesture(event) } }
        : nil
}

@MainActor
private func handleGesture(_ event: NSEvent) {
    let g = config.gestures, vertical = g.direction == "vertical"
    let touching = event.allTouches().filter { $0.phase != .ended && $0.phase != .cancelled }
    // another finger count (fingers landing one by one, lifted): a new swipe once there are N
    guard touching.count == g.fingers, let size = touching.first?.deviceSize, size.width > 0 else {
        swipe = nil
        return
    }
    let along = touching.map { vertical ? $0.normalizedPosition.y * size.height : $0.normalizedPosition.x * size.width }
    let position = along.reduce(0, +) / CGFloat(along.count)
    guard let current = swipe else {
        swipe = (position, false)
        return
    }
    let travel = position - current.start
    guard !current.switched, abs(travel) >= CGFloat(g.distance * g.cancelRatio) / 100 else { return }
    swipe = (current.start, true) // one switch per swipe
    var next = vertical ? travel > 0 : travel < 0 // the trackpad's y goes up
    if g.invert { next.toggle() }
    Task { @MainActor in
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        try? await runLightSession(.hotkeyBinding, token) {
            // the screen under the cursor, not the focused one
            let shown = mouseLocation.monitorApproximation.activeWorkspace
            if shown != focus.workspace { _ = shown.focusWorkspace() }
            _ = await runInternal("workspace \(next ? "next" : "prev")")
        }
    }
}
