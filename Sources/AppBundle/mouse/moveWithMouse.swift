import AppKit
import Common

@MainActor
private var moveWithMouseTask: Task<(), any Error>? = nil

func movedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let windowId = ax.containingWindowId()
    let notif = notif as String
    Task.startUnstructured { @MainActor in
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        guard let windowId, let window = Window.get(byId: windowId), try await isManipulatedWithMouse(window) else {
            scheduleCancellableCompleteRefreshSession(.ax(notif))
            return
        }
        moveWithMouseTask?.cancel()
        moveWithMouseTask = Task.startUnstructured {
            try checkCancellation()
            try await runLightSession(.ax(notif), token) {
                try await moveWithMouse(window)
            }
        }
    }
}

@MainActor
func moveWithMouse(_ window: Window) async throws { // skyland: internal, called by mouseDrag.swift // todo cover with tests
    resetClosedWindowsCache()
    switch window.windowParentCases {
        case .floatingWindowsContainer:
            try await moveFloatingWindow(window)
        case .macosFullscreenWindowsContainer, .macosMinimizedWindowsContainer, .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
            return // Unconventional windows can't be moved with mouse
        case .tilingContainer:
            moveTilingWindow(window)
        case .unbound: return
    }
}

@MainActor
private func moveFloatingWindow(_ window: Window) async throws {
    guard let targetWorkspace = try await window.getCenter(.cancellable)?.monitorApproximation.activeWorkspace else { return }
    guard let parent = window.parent else { return }
    if targetWorkspace != parent {
        window.bindAsFloatingWindow(to: targetWorkspace)
    }
}

@MainActor
private func moveTilingWindow(_ window: Window) {
    currentlyManipulatedWithMouseWindowId = window.windowId
    window.lastAppliedLayoutPhysicalRect = nil
    let mouseLocation = mouseLocation
    let targetWorkspace = mouseLocation.monitorApproximation.activeWorkspace
    let swapTarget = mouseLocation
        .findWindowRecursively(in: targetWorkspace.rootTilingContainer, virtual: false, fullscreenCoversAll: false)?
        .takeIf { $0 != window }
    if targetWorkspace != window.nodeWorkspace { // Move window to a different monitor
        let index: Int = if let swapTarget, let parent = swapTarget.parent as? TilingContainer, let targetRect = swapTarget.lastAppliedLayoutPhysicalRect {
            mouseLocation.getProjection(parent.orientation) >= targetRect.center.getProjection(parent.orientation)
                ? swapTarget.ownIndex.orDie() + 1
                : swapTarget.ownIndex.orDie()
        } else {
            0
        }
        window.bind(
            to: swapTarget?.parent ?? targetWorkspace.rootTilingContainer,
            adaptiveWeight: WEIGHT_AUTO,
            index: index,
        )
    } else if let swapTarget, let targetRect = swapTarget.lastAppliedLayoutPhysicalRect,
              let side = dropSide(mouseLocation, targetRect)
    {
        // skyland: on a tile's edge, the window goes beside it, on that side (#82); while
        // dragging only a preview of the place, the tree changed at the drop
        if skylandDropLocation == nil {
            showDropPreview(dropPreviewRect(targetRect, side))
        } else {
            hideDropPreview()
            insertBeside(window, swapTarget, side)
        }
    } else if let swapTarget {
        hideDropPreview()
        swapWindows(mruDominant: window, swapTarget)
    } else {
        hideDropPreview()
    }
}

/// skyland: the side of a tile the mouse is on, its outer quarter; nil in the middle (a swap).
func dropSide(_ point: CGPoint, _ rect: Rect) -> CardinalDirection? {
    let fx = (point.x - rect.topLeftX) / max(rect.width, 1), fy = (point.y - rect.topLeftY) / max(rect.height, 1)
    let distances: [(CardinalDirection, CGFloat)] = [(.left, fx), (.right, 1 - fx), (.up, fy), (.down, 1 - fy)]
    guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 < 0.25 else { return nil }
    return nearest.0
}

/// The half of the tile the window would take.
func dropPreviewRect(_ rect: Rect, _ side: CardinalDirection) -> Rect {
    switch side {
        case .left: Rect(topLeftX: rect.topLeftX, topLeftY: rect.topLeftY, width: rect.width / 2, height: rect.height)
        case .right: Rect(topLeftX: rect.topLeftX + rect.width / 2, topLeftY: rect.topLeftY, width: rect.width / 2, height: rect.height)
        case .up: Rect(topLeftX: rect.topLeftX, topLeftY: rect.topLeftY, width: rect.width, height: rect.height / 2)
        case .down: Rect(topLeftX: rect.topLeftX, topLeftY: rect.topLeftY + rect.height / 2, width: rect.width, height: rect.height / 2)
    }
}

/// `window` beside `target` on `side`: in the target's split when it runs that way, else the
/// target and the window in a new split of their own, where the target was.
@MainActor
func insertBeside(_ window: Window, _ target: Window, _ side: CardinalDirection) {
    if window == target { return }
    window.unbindFromParent()
    let orientation: Orientation = side == .left || side == .right ? .h : .v
    let after = side == .right || side == .down
    if let parent = target.parent as? TilingContainer, parent.layout == .tiles, parent.orientation == orientation {
        window.bind(to: parent, adaptiveWeight: WEIGHT_AUTO, index: target.ownIndex.orDie() + (after ? 1 : 0))
        return
    }
    let binding = target.unbindFromParent()
    let split = TilingContainer(parent: binding.parent, adaptiveWeight: binding.adaptiveWeight, orientation, .tiles, index: binding.index)
    target.bind(to: split, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    window.bind(to: split, adaptiveWeight: WEIGHT_AUTO, index: after ? INDEX_BIND_LAST : 0)
}

@MainActor
func swapWindows(mruDominant window1: Window, _ window2: Window) {
    if window1 == window2 { return }

    let binding2 = window2.unbindFromParent()
    let binding1 = window1.unbindFromParent()

    window2.bind(to: binding1.parent, adaptiveWeight: binding1.adaptiveWeight, index: binding1.index)
    window1.bind(to: binding2.parent, adaptiveWeight: binding2.adaptiveWeight, index: binding2.index)
}

extension CGPoint {
    @MainActor
    func findWindowRecursively(
        in tree: TilingContainer,
        virtual: Bool,
        fullscreenCoversAll: Bool,
    ) -> Window? {
        if fullscreenCoversAll {
            if let window = tree.mostRecentWindowRecursive, window.isFullscreen {
                return window
            }
        }
        return _findWindowRecursively(in: tree, virtual: virtual)
    }

    @MainActor
    private func _findWindowRecursively(in tree: TilingContainer, virtual: Bool) -> Window? {
        let point = self
        let target: TreeNode? = switch tree.layout {
            case .tiles:
                tree.children.first(where: {
                    (virtual ? $0.lastAppliedLayoutVirtualRect : $0.lastAppliedLayoutPhysicalRect)?.contains(point) == true
                })
            case .accordion:
                tree.mostRecentChild
        }
        guard let target else { return nil }
        return switch target.tilingTreeNodeCasesOrDie() {
            case .window(let window): window
            case .tilingContainer(let container): _findWindowRecursively(in: container, virtual: virtual)
        }
    }
}
