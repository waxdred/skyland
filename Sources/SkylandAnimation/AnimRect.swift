import Foundation

/// A rect in screen points with a top-left origin, like AeroSpace's `Rect` and the
/// window bounds SkyLight reports.
public struct AnimRect: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    public func contains(x px: Double, y py: Double) -> Bool { px >= x && px < maxX && py >= y && py < maxY }

    public func offsetBy(dx: Double, dy: Double) -> AnimRect { AnimRect(x: x + dx, y: y + dy, width: width, height: height) }

    /// Scaled by `fx` horizontally and `fy` vertically around its center.
    public func scaled(_ fx: Double, _ fy: Double) -> AnimRect {
        let w = width * fx, h = height * fy
        return AnimRect(x: midX - w / 2, y: midY - h / 2, width: w, height: h)
    }

    /// The same center, at least `minimum` wide and high (the payload does not show smaller rects).
    public func atLeast(_ minimum: Double) -> AnimRect {
        if width >= minimum && height >= minimum { return self }
        let w = max(minimum, width), h = max(minimum, height)
        return AnimRect(x: midX - w / 2, y: midY - h / 2, width: w, height: h)
    }

    public var description: String { "(\(x), \(y), \(width), \(height))" }

    public static func lerp(_ a: AnimRect, _ b: AnimRect, _ t: Double) -> AnimRect {
        AnimRect(x: mix(a.x, b.x, t), y: mix(a.y, b.y, t), width: mix(a.width, b.width, t), height: mix(a.height, b.height, t))
    }

    /// The edges of this monitor that touch another one of `screens`: a window sliding
    /// through them would be drawn on the neighbouring screen.
    public func neighbourEdges(among screens: [AnimRect]) -> Set<SlideEdge> {
        var edges = Set<SlideEdge>()
        for other in screens where other != self {
            let overlapsVertically = other.y < maxY && other.maxY > y
            let overlapsHorizontally = other.x < maxX && other.maxX > x
            if overlapsVertically && abs(other.x - maxX) < 2 { edges.insert(.right) }
            if overlapsVertically && abs(other.maxX - x) < 2 { edges.insert(.left) }
            if overlapsHorizontally && abs(other.y - maxY) < 2 { edges.insert(.bottom) }
            if overlapsHorizontally && abs(other.maxY - y) < 2 { edges.insert(.top) }
        }
        return edges
    }
}

/// A screen edge, for `slide top|bottom|left|right` and the edges shared with another screen.
public enum SlideEdge: String, CaseIterable, Hashable, Sendable {
    case top, bottom, left, right
}

/// Exactly `a` at 0 and `b` at 1
func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a * (1 - t) + b * t }

func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { min(high, max(low, value)) }
