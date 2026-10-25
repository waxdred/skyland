import AppKit
import Common

// skyland: `enable toggle` (alt-r) turns window management off and on.
// AeroSpace unregisters every hotkey when disabled; skyland keeps the main mode
// bindings that run `enable`, so the same key turns it back on. Off puts windows
// back to the stock macOS look (opacity, corners, levels, border); a HUD in the
// middle of the screen shows the new state.

extension Shell {
    func contains(where predicate: (T) -> Bool) -> Bool {
        switch self {
            case .empty: false
            case .cmd(let command): predicate(command)
            case .pipe(let list), .and(let list), .or(let list), .seq(let list): list.contains { $0.contains(where: predicate) }
        }
    }
}

/// Main mode bindings that run `enable`: the only hotkeys while skyland is disabled.
@MainActor
func enableBindings() -> [String: HotkeyBinding] {
    (config.modes[mainModeId]?.bindings ?? [:]).filter { $0.value.commands.contains { $0 is EnableCommand } }
}

@MainActor
func skylandEnabledChanged(_ enabled: Bool) {
    if !enabled { restoreDecorations() }
    // The JankyBorders border follows the theme script: started by `skyland-theme apply`
    if enabled {
        runSkylandScript(["skyland-theme", "apply"])
    } else {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-x", "borders"]
        try? process.run()
    }
    showStateHud(enabled)
}

@MainActor private var hud: NSPanel? = nil
@MainActor private var hudGeneration = 0

/// "skyland on / off" in the middle of the screen, fades out after a second.
@MainActor
private func showStateHud(_ enabled: Bool) {
    hud?.orderOut(nil)
    let size = NSSize(width: 240, height: 140)
    let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
    let panel = NSPanel(contentRect: NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                                            width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
    panel.appearance = isGlyphStyle ? themeAppearance() : NSAppearance(named: .darkAqua)
    let glass = makePanelRoot(radius: 18, for: panel) // ui-style
    let theme = skylandThemeColors()
    glass.frame = NSRect(origin: .zero, size: size)
    panel.contentView = glass

    let icon = NSImageView(frame: NSRect(x: 0, y: 52, width: size.width, height: 76))
    icon.image = NSApp.applicationIconImage // resources/Skyland.icns
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.alphaValue = enabled ? 1 : 0.35
    glass.addSubview(icon)
    let label = NSTextField(labelWithString: PanelFont.caps(enabled ? "skyland on" : "skyland off"))
    label.font = isGlyphStyle ? PanelFont.dots(18) : .systemFont(ofSize: 17, weight: .semibold)
    if isGlyphStyle { label.textColor = theme["fg"] }
    label.alignment = .center
    label.frame = NSRect(x: 0, y: 26, width: size.width, height: 22)
    glass.addSubview(label)
    let detail = NSTextField(labelWithString: PanelFont.caps(enabled ? "tiling windows" : "windows left alone"))
    detail.font = isGlyphStyle ? PanelFont.label(10) : .systemFont(ofSize: 12)
    detail.textColor = isGlyphStyle ? theme["fg_dim"] ?? .secondaryLabelColor : .secondaryLabelColor
    detail.alignment = .center
    detail.frame = NSRect(x: 0, y: 8, width: size.width, height: 16)
    glass.addSubview(detail)

    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
    hud = panel
    hudGeneration += 1
    let generation = hudGeneration
    Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(1100))
        guard generation == hudGeneration else { return } // a newer HUD replaced it
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { if generation == hudGeneration { panel.orderOut(nil); hud = nil } }
        }
    }
}
