import AppKit

@MainActor var currentlyManipulatedWithMouseWindowId: UInt32? = nil
var isLeftMouseButtonDown: Bool { NSEvent.pressedMouseButtons == 1 }

@MainActor
func isManipulatedWithMouse(_ window: Window) async throws -> Bool {
    // skyland: a modifier drag (mouseDrag.swift) knows its window; don't wait for
    // the native focus, which lags behind the first moves and made AeroSpace
    // treat them as non-mouse moves (relayout back into the tile, no swap).
    if let drag = skylandMouseDrag {
        return drag.window == window && !window.isHiddenInCorner
            && (currentlyManipulatedWithMouseWindowId == nil || window.windowId == currentlyManipulatedWithMouseWindowId)
    }
    return try await (!window.isHiddenInCorner && // Don't allow to resize/move windows of hidden workspaces
        isLeftMouseButtonDown &&
        (currentlyManipulatedWithMouseWindowId == nil || window.windowId == currentlyManipulatedWithMouseWindowId))
        .andAsync { @Sendable @MainActor in try await getNativeFocusedWindow(.cancellable) == window }
}

/// Same motivation as in monitorFrameNormalized
/// skyland: during a modifier drag the tap swallows the drag events and
/// NSEvent.mouseLocation stays at the mouse down point; use the tap's position.
@MainActor var mouseLocation: CGPoint { skylandMouseDrag?.current ?? skylandDropLocation ?? NSEvent.mouseLocation.withYAxisFlipped }
