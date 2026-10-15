import AppKit
import Common

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

@MainActor var skylandMouseDrag: MouseDrag? = nil

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
@MainActor private var tap: CFMachPort? = nil

@MainActor
func startMouseDragTap() {
    let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseDragged, .rightMouseUp]
    let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                            eventsOfInterest: mask, callback: mouseDragCallback, userInfo: nil)
    guard let tap else { return } // no Accessibility: nothing to do, AeroSpace still works
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
}

private func mouseDragCallback(_: CGEventTapProxy, type: CGEventType, event: CGEvent, _: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let location = event.location, flags = event.flags // CGEvent is not Sendable
    return MainActor.assumeIsolated { handleMouse(type, location, flags) } ? nil : Unmanaged.passUnretained(event)
}

/// Returns true when the event is consumed.
@MainActor
private func handleMouse(_ type: CGEventType, _ location: CGPoint, _ flags: CGEventFlags) -> Bool {
    switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
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
            let window = drag.window, resize = drag.resize
            Task { @MainActor in
                guard let token: RunSessionGuard = .isServerEnabled else { return }
                try? await runLightSession(.ax("skylandMouseDrag"), token) {
                    if resize { try await resizeWithMouse(window) } else { try await moveWithMouse(window) }
                }
            }
            return true
        case .leftMouseUp, .rightMouseUp:
            guard skylandMouseDrag != nil else { return false }
            skylandMouseDrag = nil
            Task { @MainActor in try? await resetManipulatedWithMouseIfPossible() }
            return true
        default:
            return false
    }
}

/// Topmost window managed by skyland under `point` (global, top-left origin), with its frame.
@MainActor
private func managedWindow(at point: CGPoint) -> (Window, CGRect)? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    for info in list where (info[kCGWindowLayer as String] as? Int) == 0 { // front to back
        guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.contains(point) else { continue }
        guard let id = info[kCGWindowNumber as String] as? UInt32, let window = MacWindow.allWindowsMap[id],
              !window.isHiddenInCorner else { return nil } // topmost window under the cursor is not ours
        return (window, rect)
    }
    return nil
}

