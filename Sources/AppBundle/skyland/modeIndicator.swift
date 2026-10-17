import AppKit
import Common

// skyland: shows a binding mode other than main (Hyprland submap, `mode resize`), else
// easy to get stuck in. `mode-indicator = 'hud'` (default): a HUD at the bottom of the
// screen with the mode name and its bindings, while the mode is active. 'bar': the
// sketchybar item and event (bar.swift). The overview shows itself.

@MainActor private var modeHud: NSPanel? = nil
@MainActor private var barShowsMode = false

/// Called by activateMode_nonCancellable.
@MainActor
func modeIndicatorChanged(_ mode: String?) {
    let shown = mode.flatMap { $0 == mainModeId || $0 == overviewModeId ? nil : $0 }
    modeHud?.orderOut(nil)
    modeHud = nil
    if config.modeIndicator == "bar" || barShowsMode { // also hides it after a switch to 'hud' / 'off'
        barShowsMode = config.modeIndicator == "bar" && shown != nil
        updateBarMode(barShowsMode ? shown : nil)
    }
    guard let shown, config.modeIndicator == "hud" else { return }
    modeHud = makeModeHud(shown, bindings: config.modes[shown]?.bindings.values.sorted { $0.descriptionWithKeyNotation < $1.descriptionWithKeyNotation } ?? [])
}

@MainActor
private func makeModeHud(_ mode: String, bindings: [HotkeyBinding]) -> NSPanel {
    let theme = skylandThemeColors()
    let accent = theme["accent"] ?? .systemBlue
    let keyWidth = bindings.map(\.descriptionWithKeyNotation.count).max() ?? 0
    let text = NSMutableAttributedString(string: mode.uppercased() + "\n", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: accent,
    ])
    for binding in bindings.prefix(24) {
        let key = binding.descriptionWithKeyNotation.padding(toLength: keyWidth + 3, withPad: " ", startingAt: 0)
        text.append(NSAttributedString(string: "\n" + key, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.labelColor,
        ]))
        text.append(NSAttributedString(string: binding.commandText, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
    }
    let label = NSTextField(labelWithAttributedString: text)
    label.lineBreakMode = .byTruncatingTail
    let fit = label.fittingSize
    let size = NSSize(width: min(520, fit.width + 40), height: fit.height + 32)
    label.frame = NSRect(x: 20, y: 16, width: size.width - 40, height: fit.height)

    let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
    let panel = NSPanel(contentRect: NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 40,
                                            width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.ignoresMouseEvents = true
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
    panel.appearance = NSAppearance(named: .darkAqua)
    let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
    glass.material = .hudWindow
    glass.state = .active
    glass.maskImage = NSImage(size: size, flipped: false) { rect in // shapes the window outline too (toggle.swift)
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16).fill()
        return true
    }
    glass.addSubview(label)
    panel.contentView = glass
    panel.orderFrontRegardless()
    return panel
}
