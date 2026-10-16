import AppKit

// skyland: macOS prompts (unlock, Accessibility / Automation / privacy requests,
// keychain, Touch ID) stay in front. While one is on screen, focus follows mouse
// is paused (moving over a window raised it above the prompt), and with the
// payload the prompt goes to the modal panel level, above floating windows.

// ponytail: known owner processes of the prompts; add one here when a prompt still hides
private let promptOwners: Set<String> = [
    "SecurityAgent", "universalAccessAuthWarn", "UserNotificationCenter", "coreautha",
    "CoreServicesUIAgent", "LocalAuthenticationRemoteService", "AccessibilityUIServer",
]

/// System prompt windows on screen, refreshed every 0.3 s.
@MainActor private(set) var systemPromptWindows: Set<UInt32> = []
@MainActor private var promptTimer: Timer? = nil

@MainActor
func startSystemPromptWatch() {
    guard promptTimer == nil else { return }
    promptTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
        MainActor.assumeIsolated { checkSystemPrompts() }
    }
}

@MainActor
private func checkSystemPrompts() {
    let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    var prompts: Set<UInt32> = [], low: Set<UInt32> = [] // low: under the modal panel level
    for window in onScreen {
        guard let owner = window[kCGWindowOwnerName as String] as? String, promptOwners.contains(owner),
              let windowId = window[kCGWindowNumber as String] as? UInt32 else { continue }
        prompts.insert(windowId)
        if (window[kCGWindowLayer as String] as? Int ?? 0) < NSWindow.Level.modalPanel.rawValue { low.insert(windowId) }
    }
    // raise only the low ones: some prompts (keychain) already sit higher
    if payloadCapabilities.contains("modal") {
        for windowId in low.subtracting(systemPromptWindows) { skylandSa("layer \(windowId) 2") }
    }
    systemPromptWindows = prompts
}
