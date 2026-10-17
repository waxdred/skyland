import AppKit
import Common
import HotKey

// skyland: bindings on arrow keys (ctrl-up, cmd-left, left in the overview mode...)
// go through a keyboard event tap instead of Carbon hotkeys: ctrl + arrows are
// macOS' own Mission Control / Spaces shortcuts, and a session tap sees the key
// press first and can consume it for skyland. Arrow events also carry hidden
// Function / numeric pad modifiers; the tap matches on cmd / alt / ctrl / shift.

private let arrowKeyCodes: Set<UInt32> = [123, 124, 125, 126] // left, right, down, up

func isArrowKey(_ key: Key) -> Bool { arrowKeyCodes.contains(key.carbonKeyCode) }

nonisolated(unsafe) private var keyTap: CFMachPort? = nil // set once at startup

@MainActor
func startArrowKeyTap() {
    keyTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                               eventsOfInterest: 1 << CGEventType.keyDown.rawValue, callback: arrowKeyCallback, userInfo: nil)
    guard let keyTap = unsafe keyTap else { return }
    addToEventTapThread(keyTap)
}

/// On the event tap thread: any key but an arrow goes through without waiting for the main thread.
private func arrowKeyCallback(_: CGEventTapProxy, type: CGEventType, event: CGEvent, _: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let keyTap = unsafe keyTap { CGEvent.tapEnable(tap: keyTap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode)), flags = event.flags // CGEvent is not Sendable
    guard type == .keyDown, arrowKeyCodes.contains(keyCode) else { return Unmanaged.passUnretained(event) }
    return onMainForTap { handleArrowKey(keyCode, flags) } ? nil : Unmanaged.passUnretained(event)
}

/// Returns true when the key press ran a binding (and is consumed).
@MainActor
private func handleArrowKey(_ keyCode: UInt32, _ flags: CGEventFlags) -> Bool {
    guard !hotkeysSuspended, let mode = activeMode,
          let binding = config.modes[mode]?.bindings.values.first(where: {
              $0.keyCode.carbonKeyCode == keyCode && $0.modifiers.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad, .capsLock]) == modifierFlags(flags)
          }) else { return false }
    Task.startUnstructured {
        broadcastEvent(.bindingTriggered(mode: mode, binding: binding.descriptionWithKeyNotation))
        if let token: RunSessionGuard = .isServerEnabled {
            try? await runLightSession(.hotkeyBinding, token) {
                _ = await binding.commands.run(.defaultEnv, .emptyStdin)
            }
        }
    }
    return true
}

/// cmd / alt / ctrl / shift of a key event, ignoring Function, numeric pad and caps lock.
func modifierFlags(_ flags: CGEventFlags) -> NSEvent.ModifierFlags {
    var result: NSEvent.ModifierFlags = []
    if flags.contains(.maskCommand) { result.insert(.command) }
    if flags.contains(.maskAlternate) { result.insert(.option) }
    if flags.contains(.maskControl) { result.insert(.control) }
    if flags.contains(.maskShift) { result.insert(.shift) }
    return result
}

