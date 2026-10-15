import CoreGraphics
/// skyland `bar-height`: a bar (sketchybar) drawn over the menu bar covers windows
/// when it is taller than the menu bar macOS reserves on that monitor (32 px on
/// a notched built-in display, ~24 px on external ones, 0 when it auto-hides).
func barOverlap(barHeight: Int, menuBarHeight: CGFloat) -> CGFloat {
    max(0, CGFloat(barHeight) - menuBarHeight)
}

extension MonitorInfo {
    @MainActor
    var visibleRectPaddedByOuterGaps: Rect {
        let topLeft = visibleRect.topLeftCorner
        let gaps = ResolvedGaps(gaps: config.gaps, monitor: self)
        // skyland: room for a bar taller than this monitor's menu bar (see barOverlap)
        let top = gaps.outer.top.toDouble() + barOverlap(barHeight: config.barHeight, menuBarHeight: visibleRect.topLeftY - rect.topLeftY)
        return Rect(
            topLeftX: topLeft.x + gaps.outer.left.toDouble(),
            topLeftY: topLeft.y + top,
            width: visibleRect.width - gaps.outer.left.toDouble() - gaps.outer.right.toDouble(),
            height: visibleRect.height - top - gaps.outer.bottom.toDouble(),
        )
    }

    var monitorId_oneBased: Int? {
        let sorted = sortedMonitorInfos
        let origin = self.rect.topLeftCorner
        return sorted.firstIndex { $0.rect.topLeftCorner == origin }.map { $0 + 1 }
    }
}
