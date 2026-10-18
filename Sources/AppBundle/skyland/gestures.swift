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
    MainActor.assumeIsolated { follow(touches, g) } // the tap runs on the main run loop
}

/// The swipe in progress (main thread): the screen it moves, the windows that follow.
private struct SwipeSession {
    let area: Rect // the screen
    let current: Workspace
    let windows: [(id: UInt32, rect: Rect)] // tiles of the current workspace
    var neighbor: (workspace: Workspace, next: Bool, windows: [(id: UInt32, rect: Rect)])? = nil
    var offset: CGFloat = 0 // along the axis, points; > 0 = right / down
}
@MainActor private var session: SwipeSession? = nil

/// Tiles of `workspace` with their last layout rect (a hidden workspace keeps it).
@MainActor
private func tiles(_ workspace: Workspace) -> [(id: UInt32, rect: Rect)] {
    workspace.rootTilingContainer.allLeafWindowsRecursive.compactMap { w in w.lastAppliedLayoutPhysicalRect.map { (w.windowId, $0) } }
}

/// Shows window `id` at `rect` at once and keeps it there (payload `animate`, 1 ms, hold).
@MainActor
private func place(_ id: UInt32, _ rect: Rect) {
    let r = "\(rect.topLeftX) \(rect.topLeftY) \(rect.width) \(rect.height)"
    skylandSa("animate \(id) \(r) 1 0 0 1 1 \(r) 1")
}

@MainActor
private func follow(_ touches: Set<NSTouch>, _ g: Gestures) {
    let vertical = g.direction == "vertical"
    let touching = touches.filter { $0.phase != .ended && $0.phase != .cancelled }
    guard touching.count == g.fingers, let size = touching.first?.deviceSize, size.width > 0 else {
        swipe = nil
        if session != nil { release(g) } // fingers lifted: complete or spring back
        return
    }
    let along = touching.map { vertical ? $0.normalizedPosition.y * size.height : $0.normalizedPosition.x * size.width }
    let position = along.reduce(0, +) / CGFloat(along.count)
    guard let current = unsafe swipe else {
        swipe = (position, false)
        return
    }
    guard TrayMenuModel.shared.isEnabled, config.animations.enabled, payloadCapabilities.contains("close") else {
        return discreteSwitch(position - current.start, g) // no payload: the switch alone
    }
    // the trackpad's y goes up, the screen's down
    let travel = (vertical ? -(position - current.start) : position - current.start) * (g.invert ? -1 : 1)
    if session == nil {
        let shown = mouseLocation.monitorApproximation.activeWorkspace
        session = SwipeSession(area: shown.workspaceMonitor.rect, current: shown, windows: tiles(shown))
        pauseAnimatedBorder(ms: 60_000) // back at the end
    }
    guard var s = session else { return }
    let length = vertical ? s.area.height : s.area.width
    // fingers right / down bring the previous workspace (macOS Spaces)
    let next = travel < 0
    if s.neighbor?.next != next {
        if let old = s.neighbor { for w in old.windows { skylandSa("untransform \(w.id)"); setSwipeAlpha(w.id, shown: false) } }
        let workspace = try? getNextPrevWorkspace(current: s.current, isNext: next, wrapAround: false, stdin: nil, target: s.current.toLiveFocus()).get()
        s.neighbor = workspace.map { ($0, next, tiles($0)) }
        for w in s.neighbor?.windows ?? [] { setSwipeAlpha(w.id, shown: true) }
    }
    // one screen per `distance` of finger travel; past the last workspace it barely moves
    var offset = travel / CGFloat(g.distance) * length
    offset = s.neighbor == nil ? offset * 0.15 : max(-length, min(length, offset))
    s.offset = offset
    session = s
    // the bar's selection follows the fingers (skylandbar, subscribe workspace-swipe)
    broadcastEvent(.workspaceSwipe(workspace: s.current.name, target: s.neighbor?.workspace.name,
                                   progress: s.neighbor == nil ? 0 : Double(abs(offset) / length)))
    let shift = { (r: Rect, by: CGFloat) in
        vertical ? r.copy(\.topLeftY, r.topLeftY + by) : r.copy(\.topLeftX, r.topLeftX + by)
    }
    for w in s.windows { place(w.id, shift(w.rect, offset)) }
    if let n = s.neighbor {
        for w in n.windows { place(w.id, shift(w.rect, offset + (next ? length : -length))) }
    }
}

/// Fingers lifted: past `cancel-ratio` the switch completes from where the windows are,
/// else they spring back.
@MainActor
private func release(_ g: Gestures) {
    guard let s = session else { return }
    session = nil
    let vertical = g.direction == "vertical", length = vertical ? s.area.height : s.area.width
    let anim = config.animations, ms = max(1, anim.workspacesMs), bezier = anim.workspacesBezier.args
    let shift = { (r: Rect, by: CGFloat) in
        vertical ? r.copy(\.topLeftY, r.topLeftY + by) : r.copy(\.topLeftX, r.topLeftX + by)
    }
    let args = { (r: Rect) in "\(r.topLeftX) \(r.topLeftY) \(r.width) \(r.height)" }
    if let n = s.neighbor, abs(s.offset) >= length * CGFloat(g.cancelRatio) / 100 {
        let neighborOffset = s.offset + (n.next ? length : -length)
        for w in s.windows { swipeHandoff[w.id] = shift(w.rect, s.offset) }
        for w in n.windows { swipeHandoff[w.id] = shift(w.rect, neighborOffset) }
        let leave = n.next ? -length : length
        swipeLeave = vertical ? CGPoint(x: 0, y: leave) : CGPoint(x: leave, y: 0)
        Task { @MainActor in
            defer { swipeHandoff = [:] } // the windows the switch did not animate
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            try? await runLightSession(.hotkeyBinding, token) {
                if s.current != focus.workspace { _ = s.current.focusWorkspace() }
                _ = n.workspace.focusWorkspace()
            }
            resumeAnimatedBorder(afterMs: ms)
        }
        return
    }
    // spring back (a switch tells the bar with focused-workspace-changed instead)
    broadcastEvent(.workspaceSwipe(workspace: s.current.name, target: nil, progress: 0))
    for w in s.windows { skylandSa("animate \(w.id) \(args(shift(w.rect, s.offset))) \(ms) \(bezier)") }
    if let n = s.neighbor {
        for w in n.windows {
            let away = shift(w.rect, n.next ? length : -length)
            skylandSa("animate \(w.id) \(args(shift(w.rect, s.offset + (n.next ? length : -length)))) \(ms) \(bezier) \(args(away)) 1")
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(ms))
            for w in n.windows { skylandSa("untransform \(w.id)"); setSwipeAlpha(w.id, shown: false) }
        }
    }
    resumeAnimatedBorder(afterMs: ms)
}

/// Without the payload: the switch alone once the fingers travelled cancel-ratio % of distance.
@MainActor
private func discreteSwitch(_ travelAlongTrackpad: CGFloat, _ g: Gestures) {
    guard let current = unsafe swipe, !current.switched,
          abs(travelAlongTrackpad) >= CGFloat(g.distance * g.cancelRatio) / 100 else { return }
    swipe = (current.start, true) // one switch per swipe
    var next = g.direction == "vertical" ? travelAlongTrackpad > 0 : travelAlongTrackpad < 0
    if g.invert { next.toggle() }
    let direction = next
    Task { @MainActor in
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        try? await runLightSession(.hotkeyBinding, token) {
            let shown = mouseLocation.monitorApproximation.activeWorkspace
            if shown != focus.workspace { _ = shown.focusWorkspace() }
            _ = await runInternal("workspace \(direction ? "next" : "prev")")
        }
    }
}
