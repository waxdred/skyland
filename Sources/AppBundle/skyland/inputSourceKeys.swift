import AppKit
import Carbon
import Common
import HotKey

// skyland: key-mapping.preset = 'input-source'
// Letters in bindings follow the active keyboard layout: alt-m is the key that
// types "m" in the current input source, so the same binding works in French
// AZERTY and in English QWERTY. Digits and named keys keep their physical
// (qwerty) position, so cmd-1 stays the top row key on AZERTY. The config is
// reloaded when the input source changes, which registers the hotkeys again.

/// Key code of each letter a-z in the active keyboard layout.
func inputSourceLetterKeys() -> [String: Key] {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
    let data = unsafe Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue() as Data
    var result: [String: Key] = [:]
    unsafe data.withUnsafeBytes { buffer in
        guard let layout = unsafe buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
        for keyCode in 0 ..< 64 as Range<UInt16> { // main block; keypad and function keys come later
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = unsafe UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                               OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, 4, &length, &chars)
            guard status == noErr, length == 1 else { continue }
            let char = String(utf16CodeUnits: chars, count: 1)
            if char.count == 1, ("a" ... "z").contains(char), result[char] == nil,
               let key = Key(carbonKeyCode: UInt32(keyCode))
            {
                result[char] = key
            }
        }
    }
    return result
}

@MainActor private var inputSourceObserver: NSObjectProtocol? = nil

@MainActor
func observeInputSourceChanges() {
    guard inputSourceObserver == nil else { return }
    inputSourceObserver = DistributedNotificationCenter.default().addObserver(
        forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
        object: nil,
        queue: .main,
    ) { _ in
        Task { @MainActor in
            if config.keyMapping.followsInputSource { _ = await reloadConfig_nonCancellable() }
        }
    }
}
