import AppKit

@MainActor private var focusFollowsMouseMonitor: Any? = nil
@MainActor private var focusFollowsTask: Task<(), any Error>? = nil

@MainActor func syncFocusFollowsMouse(_ config: Config) {
    if config.focusFollowsMouse.enabled == (focusFollowsMouseMonitor != nil) {
        return
    }

    if !config.focusFollowsMouse.enabled {
        NSEvent.removeMonitor(focusFollowsMouseMonitor.orDie())
        focusFollowsMouseMonitor = nil
        focusFollowsTask?.cancel()
        focusFollowsTask = nil
        return
    }

    // Interestingly, this callback seems to not fire when the mouse is down which is good,
    // because this is how I want it to work for windows/tabs/files dragging
    focusFollowsMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { @MainActor event in
        let location = event.locationInWindow.withYAxisFlipped
        focusFollowsTask?.cancel()
        let focusAtMove = focus.windowOrNil
        // skyland: still over the focused tile (and no floating window that could be
        // above it): nothing to do, no AX call. Most mouse moves end here.
        if let focused = focus.windowOrNil, !focused.isFloating,
           focused.lastAppliedLayoutPhysicalRect?.contains(location) == true,
           focused.nodeWorkspace?.floatingWindowsContainer.children.isEmpty == true
        {
            focusFollowsTask = nil
            return
        }
        focusFollowsTask = Task.startUnstructured { @MainActor in
            // skyland: act once the mouse rests a moment (a move cancels this task),
            // not for each of the hundreds of moves per second
            try await Task.sleep(for: .milliseconds(20))
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            // skyland: the overview and modifier drags own the mouse; following it there
            // focused the window under the cursor on another screen (workspace switch)
            if activeMode == overviewModeId || skylandMouseDrag != nil { return }
            // skyland: a macOS prompt (unlock, permissions...) keeps the focus, else the
            // window under the mouse would come above it
            if !systemPromptWindows.isEmpty { return }
            // skyland: the focus moved meanwhile (a command, a Dock click, a warp): that wins over
            // a move made before it; and the cursor may have been warped since the event
            if focus.windowOrNil != focusAtMove { return }
            let location = NSEvent.mouseLocation.withYAxisFlipped
            try checkCancellation()
            // Ignores macOS menubar dropdown, but, unfortunately, it doesn't ignore non-native menu-like fake windows.
            // todo: It would be cool to somehow reuse isWindowHeuristic logic here
            if await isAxWindowUnderMouse(location) == false { return }
            try checkCancellation()
            let workspace = location.monitorApproximation.activeWorkspace
            // skyland: the window server's topmost window at the point (one query)
            // instead of an AX frame request per floating window
            var window = managedWindow(at: location)?.0.takeIf { $0.isFloating && $0.nodeWorkspace == workspace }
            if window == nil {
                window = location.findWindowRecursively(in: workspace.rootTilingContainer, virtual: false, fullscreenCoversAll: true)
            }
            if let window, window != focus.windowOrNil {
                try await runLightSession(.focusFollowsMouse, token) {
                    _ = window.focusWindow()
                    window.nativeFocus()
                }
            }
        }
    }
}

@concurrent
private nonisolated func isAxWindowUnderMouse(_ location: CGPoint) async -> Bool? {
    let systemwide = AXUIElementCreateSystemWide()
    var element: AXUIElement?
    if unsafe AXUIElementCopyElementAtPosition(systemwide, Float(location.x), Float(location.y), &element) != .success {
        return nil
    }
    guard let element else { return nil }
    return element.get(Ax.parentWindowRecursive) != nil || element.get(Ax.roleAttr) == kAXWindowRole
}

