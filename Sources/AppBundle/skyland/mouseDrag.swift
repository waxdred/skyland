import AppKit
import Common
import os

// Hyprland `bindm = SUPER, mouse:272, movewindow` / `mouse:273, resizewindow`:
// with the mouse-modifier held, left drag anywhere on a window moves it, right
// drag resizes it from the nearest corner. skyland moves the window with AX and
// calls AeroSpace's mouse handling (moveWithMouse / resizeWithMouse) itself,
// which swaps tiles or redistributes their weights as when dragging a title bar
// or an edge: AeroSpace normally runs it on AX moved/resized notifications, and
// those are not delivered for changes made by skyland's own process.
// The clicks with the modifier are swallowed.
//
// mouse-modifier = 'alt'   # alt | cmd | ctrl | shift, combined with '-' (ctrl-alt); '' = off

struct MouseDrag {
    let window: Window
    let resize: Bool
    let startMouse: CGPoint
    let startRect: CGRect
    let fromLeft: Bool, fromTop: Bool // corner being dragged when resizing
    var lastApplied: TimeInterval = 0
    /// Cursor position from the tap: the drag events are swallowed, so
    /// NSEvent.mouseLocation stays frozen at the mouse down point.
    var current: CGPoint
}

@MainActor var skylandMouseDrag: MouseDrag? = nil {
    didSet { mouseDragActive.withLock { [active = skylandMouseDrag != nil] in $0 = active } }
}
/// skylandMouseDrag != nil, readable from the event tap thread
private let mouseDragActive = OSAllocatedUnfairLock(initialState: false)
/// Live feedback of the last drag event, while it runs (see `.leftMouseDragged`)
@MainActor private var dragFeedback: Task<Void, Never>? = nil
/// Drop point while mouse up catches up (`mouseLocation`)
@MainActor var skylandDropLocation: CGPoint? = nil

func parseMouseModifier(_ raw: String) -> CGEventFlags? {
    if raw.isEmpty { return nil }
    var flags: CGEventFlags = []
    for part in raw.lowercased().split(separator: "-") {
        switch part {
            case "alt", "option": flags.insert(.maskAlternate)
            case "cmd", "command": flags.insert(.maskCommand)
            case "ctrl", "control": flags.insert(.maskControl)
            case "shift": flags.insert(.maskShift)
            default: return nil
        }
    }
    return flags
}

private let modifierMask: CGEventFlags = [.maskAlternate, .maskCommand, .maskControl, .maskShift]
nonisolated(unsafe) private var tap: CFMachPort? = nil // set once at startup

@MainActor
func startMouseDragTap() {
    let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseDragged, .rightMouseUp]
    let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                            eventsOfInterest: mask, callback: mouseDragCallback, userInfo: nil)
    guard let tap = unsafe tap else { return } // no Accessibility: nothing to do, AeroSpace still works
    addToEventTapThread(tap)
}

/// On the event tap thread: a click without a modifier, or a drag that is not
/// skyland's, goes through without waiting for the main thread.
private func mouseDragCallback(_: CGEventTapProxy, type: CGEventType, event: CGEvent, _: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let location = event.location, flags = event.flags // CGEvent is not Sendable
    switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = unsafe tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .leftMouseDown, .rightMouseDown:
            if flags.intersection(modifierMask).isEmpty { return Unmanaged.passUnretained(event) }
        default:
            if !mouseDragActive.withLock({ $0 }) { return Unmanaged.passUnretained(event) }
    }
    return onMainForTap { handleMouse(type, location, flags) } ? nil : Unmanaged.passUnretained(event)
}

/// Returns true when the event is consumed.
@MainActor
private func handleMouse(_ type: CGEventType, _ location: CGPoint, _ flags: CGEventFlags) -> Bool {
    switch type {
        case .leftMouseDown, .rightMouseDown:
            guard let wanted = parseMouseModifier(config.mouseModifier),
                  flags.intersection(modifierMask) == wanted,
                  let (window, rect) = managedWindow(at: location) else { return false }
            window.nativeFocus()
            let point = location
            skylandMouseDrag = MouseDrag(window: window, resize: type == .rightMouseDown, startMouse: point, startRect: rect,
                                         fromLeft: point.x < rect.midX, fromTop: point.y < rect.midY, current: point)
            return true
        case .leftMouseDragged, .rightMouseDragged:
            guard var drag = skylandMouseDrag else { return false }
            drag.current = location
            skylandMouseDrag = drag
            let now = ProcessInfo.processInfo.systemUptime
            if now - drag.lastApplied < 1.0 / 60 { return true } // AX is slow, 60 updates/s is plenty
            drag.lastApplied = now
            skylandMouseDrag = drag
            let dx = location.x - drag.startMouse.x, dy = location.y - drag.startMouse.y
            let r = drag.startRect
            if drag.resize {
                let minSize: CGFloat = 120
                let width = max(minSize, r.width + (drag.fromLeft ? -dx : dx))
                let height = max(minSize, r.height + (drag.fromTop ? -dy : dy))
                let x = drag.fromLeft ? r.maxX - width : r.minX
                let y = drag.fromTop ? r.maxY - height : r.minY
                drag.window.setAxFrame(CGPoint(x: x, y: y), CGSize(width: width, height: height))
            } else {
                drag.window.setAxFrame(CGPoint(x: r.minX + dx, y: r.minY + dy), nil)
            }
            updateAnimatedBorder() // the rotating border follows the window
            // Live feedback only (the tile under the cursor swaps in, the neighbours
            // resize): no refresh session per drag event, one complete refresh at mouse
            // up. A drag event that comes while the previous one is laid out is skipped,
            // the next one (or mouse up) catches up.
            if dragFeedback != nil || !TrayMenuModel.shared.isEnabled { return true }
            dragFeedback = Task { @MainActor in
                await dragFeedbackStep(drag)
                dragFeedback = nil
            }
            return true
        case .leftMouseUp, .rightMouseUp:
            guard let drag = skylandMouseDrag else { return false }
            skylandMouseDrag = nil
            let running = dragFeedback
            Task { @MainActor in
                await running?.value
                guard TrayMenuModel.shared.isEnabled else { return }
                // the last drag events may have been skipped: catch up at the drop point
                skylandDropLocation = drag.current
                await dragFeedbackStep(drag)
                skylandDropLocation = nil
                // one complete refresh (normalize, layout, decorations) for the whole drag
                if currentlyManipulatedWithMouseWindowId != nil {
                    try? await resetManipulatedWithMouseIfPossible()
                } else {
                    scheduleCancellableCompleteRefreshSession(.ax("skylandMouseDrag"))
                }
            }
            return true
        default:
            return false
    }
}

/// AeroSpace's mouse handling for the dragged window (tile swap, weights), then the
/// layout of the workspaces it touches: the other tiles follow the drag live.
@MainActor
private func dragFeedbackStep(_ drag: MouseDrag) async {
    let window = drag.window, before = window.nodeWorkspace
    if drag.resize { try? await resizeWithMouse(window) } else { try? await moveWithMouse(window) }
    if window.nodeWorkspace != before { normalizeContainers() } // moved to another monitor: no empty container left behind
    for workspace in Set([before, window.nodeWorkspace].compactMap { $0 }) where workspace.isVisible {
        try? await workspace.layoutWorkspace()
    }
}

/// Topmost window managed by skyland under `point` (global, top-left origin), with its frame.
/// One window server query instead of an AX round trip per window (focus follows mouse uses it too).
@MainActor
func managedWindow(at point: CGPoint) -> (Window, CGRect)? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    // front to back; skyland's own windows (the rotating border above the focused window) don't count
    for info in list where (info[kCGWindowLayer as String] as? Int) == 0 && (info[kCGWindowOwnerPID as String] as? pid_t) != myPid {
        guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.contains(point) else { continue }
        guard let id = info[kCGWindowNumber as String] as? UInt32, let window = MacWindow.allWindowsMap[id],
              !window.isHiddenInCorner else { return nil } // topmost window under the cursor is not ours
        return (window, rect)
    }
    return nil
}

