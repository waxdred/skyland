import AppKit
import Common
import SkylandAnimation

// skyland: Hyprland scratchpads (special workspaces, togglespecialworkspace), the
// `scratchpad` command. Their windows live on the hidden workspaces "scratch" /
// "scratch-<name>", which workspace prev/next, the overview and the Rules tab skip.
// Shown, they float centered over the focused workspace and slide in from the top
// (Hyprland specialWorkspace slidevert), with the windows animation.

let scratchpadWorkspaceName = "scratch"

extension Workspace {
    /// "scratch" and the named scratchpads "scratch-<name>"
    var isScratchpad: Bool { name == scratchpadWorkspaceName || name.hasPrefix(scratchpadWorkspaceName + "-") }
}

/// Windows of each scratchpad (by workspace name) out on a workspace
@MainActor private var shownScratchpads: [String: [UInt32]] = [:]
/// Scratchpads sliding out: the windows go back to their workspace at the end
@MainActor private var hiding: [String: (windows: [UInt32], task: Task<Void, Never>)] = [:]
/// Running slides, to start the next one where the window is now (a toggle during a slide)
@MainActor private var slides: [UInt32: (from: Rect, to: Rect, start: Date, ms: Double, curve: CubicBezier, track: WindowTrack?)] = [:]
/// An app started for a scratchpad, its first window awaited
@MainActor private var awaitingApp: [String: Task<Void, Never>] = [:]

struct ScratchpadCommand: Command {
    let args: ScratchpadCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        let workspace = args.name.map { "\(scratchpadWorkspaceName)-\($0)" } ?? scratchpadWorkspaceName
        switch args.action.val {
            case .move:
                guard let window = focus.windowOrNil else { return .fail(io.err("No window is focused")) }
                shownScratchpads[workspace]?.removeAll { $0 == window.windowId }
                return .from(bool: await moveToWorkspace(window.windowId, workspace))
            case .toggle:
                return .from(bool: await toggleScratchpad(workspace, app: args.app))
        }
    }
}

@MainActor
private func toggleScratchpad(_ workspace: String, app: String?) async -> Bool {
    // shown windows still floating (made tiling = taken out of the scratchpad)
    let shown = (shownScratchpads[workspace] ?? []).filter { Window.get(byId: $0)?.isFloating == true }
    let target = focus.workspace
    if let sliding = hiding.removeValue(forKey: workspace) { // toggled again while sliding out: back in
        sliding.task.cancel()
        return await show(sliding.windows.compactMap { Window.get(byId: $0) }, workspace, on: target)
    }
    if shown.contains(where: { Window.get(byId: $0)?.nodeWorkspace == target }) {
        await hide(shown, workspace)
        return true
    }
    var windows = (shown.compactMap { Window.get(byId: $0) } + (Workspace.get(byName: workspace).allLeafWindowsRecursive))
        .reduce(into: [Window]()) { if !$0.contains($1) { $0.append($1) } }
    if windows.isEmpty, let app {
        if let window = MacWindow.allWindows.first(where: { $0.app.rawAppBundleId == app }) {
            windows = [window]
        } else {
            startAppForScratchpad(app, workspace)
            return true
        }
    }
    if windows.isEmpty { return true }
    return await show(windows, workspace, on: target)
}

/// Brings the windows over `target`, floating and centered, sliding in from the top.
@MainActor
private func show(_ windows: [Window], _ workspace: String, on target: Workspace) async -> Bool {
    let monitor = target.workspaceMonitor
    for window in windows {
        guard await moveToWorkspace(window.windowId, target.name) else { continue }
        if !window.isFloating { _ = await runInternal("layout --window-id \(window.windowId) floating") }
        // out of its hiding corner now: the next layout would put it back where it was before
        (window as? MacWindow)?.unhideFromCorner()
        // centered, at floating-center-percent of the screen or its own size
        let area = monitor.visibleRect
        let size: CGSize = if config.floatingCenterPercent > 0 {
            centeredRect(in: area, percent: config.floatingCenterPercent).size
        } else {
            (try? await window.getAxSize(.nonCancellable)) ?? centeredRect(in: area, percent: 70).size
        }
        let rect = Rect(topLeftX: area.topLeftX + (area.width - size.width) / 2, topLeftY: area.topLeftY + (area.height - size.height) / 2,
                        width: size.width, height: size.height)
        window.setAxFrame(rect.topLeftCorner, size)
        // its opacity at once: hidden on the scratchpad workspace it was faded out, and a
        // fade in on top of the slide looked like a glitch
        showOpaqueNow(window.windowId, focused: window === windows.first)
        let from = slidingRect(window.windowId) ?? rect.copy(\.topLeftY, monitor.rect.topLeftY - size.height)
        animateScratchpad(window.windowId, from: from, to: rect, toRealFrame: true)
    }
    shownScratchpads[workspace] = windows.map(\.windowId)
    _ = windows.first?.focusWindow()
    return true
}

/// The windows slide up out of the screen, then go back to their scratchpad workspace.
@MainActor
private func hide(_ ids: [UInt32], _ workspace: String) async {
    shownScratchpads[workspace] = nil
    let out = windowAnimator.settings.resolve(.specialWorkspaceOut)
    let ms = config.animations.enabled && out.enabled && payloadCapabilities.contains("track") ? Int(out.durationMs) : 0
    for id in ids {
        guard let window = Window.get(byId: id), let rect = try? await window.getAxRect(.nonCancellable) else { continue }
        let monitor = window.nodeWorkspace?.workspaceMonitor ?? mainMonitorInfo
        animateScratchpad(id, from: slidingRect(id) ?? rect, to: rect.copy(\.topLeftY, monitor.rect.topLeftY - rect.height), toRealFrame: false)
    }
    let task = Task { @MainActor in
        if ms > 0 { try? await Task.sleep(for: .milliseconds(ms)) }
        if Task.isCancelled { return }
        hiding[workspace] = nil
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        try? await runLightSession(.ax("scratchpad"), token) {
            for id in ids { _ = await moveToWorkspace(id, workspace) }
        }
        // back to its real frame once it is in its hiding corner (the AX move is applied
        // asynchronously). ponytail: fixed delay, wait for the window server frame if it ever shows
        try? await Task.sleep(for: .milliseconds(250))
        for id in ids where hiding[workspace] == nil && shownScratchpads[workspace]?.contains(id) != true { skylandSa("untransform \(id)") }
    }
    hiding[workspace] = (ids, task)
}

/// Starts the app and shows its first window once skyland sees it (no polling of the CLI).
@MainActor
private func startAppForScratchpad(_ app: String, _ workspace: String) {
    guard awaitingApp[workspace] == nil, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) else { return }
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    awaitingApp[workspace] = Task { @MainActor in
        defer { awaitingApp[workspace] = nil }
        for _ in 0 ..< 100 { // 10 s: the model, not the CLI, is asked every 0.1 s
            try? await Task.sleep(for: .milliseconds(100))
            guard let window = MacWindow.allWindows.first(where: { $0.app.rawAppBundleId == app }) else { continue }
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            try? await runLightSession(.ax("scratchpad"), token) { _ = await show([window], workspace, on: focus.workspace) }
            return
        }
    }
}

/// `toRealFrame`: the window ends at its real frame (`to`), else it stays shown out of the
/// screen until `untransform`: it is moved to its hidden workspace a bit after the slide,
/// and its real frame is still on screen until then (it flashed there).
/// The specialWorkspaceIn / Out animation (style, speed, curve) plays as a payload track;
/// a toggle during a slide goes on from where the window is, with the same timing.
@MainActor
private func animateScratchpad(_ windowId: UInt32, from: Rect, to: Rect, toRealFrame: Bool) {
    let spec = windowAnimator.settings.resolve(toRealFrame ? .specialWorkspaceIn : .specialWorkspaceOut)
    guard config.animations.enabled, spec.enabled, let window = Window.get(byId: windowId) else { return }
    // the window server frame is the sliding one until the end; going out, the window is
    // still focused at its real frame until it is moved away (the border flashed there)
    let pause = toRealFrame ? 0 : 500
    if slidingRect(windowId) == nil,
       let track = playTrack(toRealFrame ? .specialIn : .specialOut, window, rect: toRealFrame ? to : from, direction: -1,
                             mode: toRealFrame ? nil : .hold)
    {
        slides[windowId] = (from, to, .now, track.durationMs, spec.curve, track)
        pauseAnimatedBorder(ms: Int(track.durationMs) + pause)
        return
    }
    slides[windowId] = (from, to, .now, spec.durationMs, spec.curve, nil)
    let c = spec.curve, target = toRealFrame ? "" : " \(to.topLeftX) \(to.topLeftY) \(to.width) \(to.height) 1"
    skylandSa("animate \(windowId) \(from.topLeftX) \(from.topLeftY) \(from.width) \(from.height) \(Int(spec.durationMs)) \(c.x1) \(c.y1) \(c.x2) \(c.y2)\(target)")
    pauseAnimatedBorder(ms: Int(spec.durationMs) + pause)
}

/// Where a sliding window is shown now, nil when it is not sliding.
@MainActor
private func slidingRect(_ windowId: UInt32) -> Rect? {
    guard let slide = slides[windowId], slide.ms > 0 else { return nil }
    let elapsed = Date.now.timeIntervalSince(slide.start) * 1000
    if elapsed >= slide.ms { slides[windowId] = nil; return nil }
    if let track = slide.track { // where the payload shows it now
        let r = track.state(atMs: elapsed).rect
        return Rect(topLeftX: r.x, topLeftY: r.y, width: r.width, height: r.height)
    }
    let p = CGFloat(Bezier(x1: slide.curve.x1, y1: slide.curve.y1, x2: slide.curve.x2, y2: slide.curve.y2).ease(elapsed / slide.ms))
    let a = slide.from, b = slide.to
    return Rect(topLeftX: a.topLeftX + (b.topLeftX - a.topLeftX) * p, topLeftY: a.topLeftY + (b.topLeftY - a.topLeftY) * p,
                width: a.width + (b.width - a.width) * p, height: a.height + (b.height - a.height) * p)
}

@MainActor
private func moveToWorkspace(_ windowId: UInt32, _ workspace: String) async -> Bool {
    await runInternal("move-node-to-workspace --window-id \(windowId) \(workspace)")
}

/// Runs a command inside the current session, as a binding would.
@MainActor
func runInternal(_ command: String) async -> Bool {
    guard case .cmd(let shell) = parseCommand(command, allowExecAndForget: false, allowEval: false) else { return false }
    return await shell.run(.defaultEnv, .emptyStdin).exitCode.rawValue == 0
}
