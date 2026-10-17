import AppKit
import Common
import os

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

// A listen-only session event tap on gesture events (NSEvent global monitors do not get
// the touches). On the main run loop: on another thread NSEvent(cgEvent:).allTouches()
// comes back empty. Listen-only, it never holds any input back.
nonisolated(unsafe) private var gestureTap: CFMachPort? = nil // created once
/// The swipe in progress: where the fingers started (along its axis), and if it switched
/// already; only touched by the tap callback (main run loop)
nonisolated(unsafe) private var swipe: (start: CGFloat, switched: Bool)? = nil
/// The config read by the tap callback (set at reload)
private let swipeConfig = OSAllocatedUnfairLock<Gestures>(initialState: Gestures())

/// At startup and on config reload.
@MainActor
func syncGestures(_ config: Config) {
    swipeConfig.withLock { $0 = config.gestures }
    guard config.gestures.workspaceSwipe, gestureTap == nil else { return }
    gestureTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                   eventsOfInterest: 1 << CGEventMask(NSEvent.EventType.gesture.rawValue), callback: gestureCallback, userInfo: nil)
    if let tap = unsafe gestureTap {
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}

private func gestureCallback(_: CGEventTapProxy, type: CGEventType, event: CGEvent, _: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = unsafe gestureTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let g = swipeConfig.withLock { $0 }
    guard g.workspaceSwipe, let ns = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
    handleGesture(ns.allTouches(), g)
    return Unmanaged.passUnretained(event)
}

private func handleGesture(_ touches: Set<NSTouch>, _ g: Gestures) {
    let vertical = g.direction == "vertical"
    let touching = touches.filter { $0.phase != .ended && $0.phase != .cancelled }
    // another finger count (fingers landing one by one, lifted): a new swipe once there are N
    guard touching.count == g.fingers, let size = touching.first?.deviceSize, size.width > 0 else {
        swipe = nil
        return
    }
    let along = touching.map { vertical ? $0.normalizedPosition.y * size.height : $0.normalizedPosition.x * size.width }
    let position = along.reduce(0, +) / CGFloat(along.count)
    guard let current = unsafe swipe else {
        swipe = (position, false)
        return
    }
    let travel = position - current.start
    guard !current.switched, abs(travel) >= CGFloat(g.distance * g.cancelRatio) / 100 else { return }
    swipe = (current.start, true) // one switch per swipe
    var next = vertical ? travel > 0 : travel < 0 // the trackpad's y goes up
    if g.invert { next.toggle() }
    let direction = next
    Task { @MainActor in
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        try? await runLightSession(.hotkeyBinding, token) {
            // the screen under the cursor, not the focused one
            let shown = mouseLocation.monitorApproximation.activeWorkspace
            if shown != focus.workspace { _ = shown.focusWorkspace() }
            _ = await runInternal("workspace \(direction ? "next" : "prev")")
        }
    }
}
