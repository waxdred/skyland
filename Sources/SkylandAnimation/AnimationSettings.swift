import Foundation

/// An animation as it applies to a node: the node's own line, or the closest ancestor's.
public struct AnimationSpec: Equatable, Sendable {
    public var enabled: Bool
    public var durationMs: Double
    public var curve: CubicBezier
    public var style: AnimationStyle?

    public init(enabled: Bool, durationMs: Double, curve: CubicBezier, style: AnimationStyle?) {
        self.enabled = enabled
        self.durationMs = durationMs
        self.curve = curve
        self.style = style
    }
}

/// A problem with a `bezier` or `animation` line. A notice (`isError == false`) is a line
/// that loads but does nothing on macOS.
public struct AnimationDiagnostic: Equatable, Sendable, CustomStringConvertible {
    public let line: String
    public let message: String
    public let isError: Bool

    public init(line: String, message: String, isError: Bool) {
        self.line = line
        self.message = message
        self.isError = isError
    }

    static func error(_ line: String, _ message: String) -> AnimationDiagnostic {
        AnimationDiagnostic(line: line, message: message, isError: true)
    }

    static func notice(_ line: String, _ message: String) -> AnimationDiagnostic {
        AnimationDiagnostic(line: line, message: message, isError: false)
    }

    public var description: String { "\(isError ? "error" : "notice"): '\(line)': \(message)" }
}

/// Hyprland's animation config: named curves (`bezier = NAME, X0, Y0, X1, Y1`) and the
/// animation tree (`animation = NAME, ONOFF, SPEED, CURVE [, STYLE]`), same syntax and
/// meaning as hyprland.conf, so its lines can be pasted as they are.
public struct AnimationSettings: Equatable, Sendable {
    /// Hyprland's `animations { enabled = ... }`: off, nothing animates
    public var enabled: Bool = true
    /// The curves by name: Hyprland's built-in `default` and `linear`, then the `bezier` lines
    public private(set) var curves: [String: CubicBezier] = ["default": .hyprlandDefault, "linear": .linear]
    /// The nodes that have their own `animation` line
    var entries: [AnimationNode: Entry] = [:]

    struct Entry: Equatable, Sendable {
        var enabled: Bool
        var speed: Double // ds, Hyprland's unit: 1 = 100 ms
        var curve: String
        var style: AnimationStyle?
    }

    /// `global` when no line sets it: on, speed 8 (800 ms), the `default` curve, like Hyprland
    public static let globalDefault = AnimationSpec(enabled: true, durationMs: 800, curve: .hyprlandDefault, style: nil)

    public init() {}

    /// `bezier` lines first (an animation line may use a curve defined after it), then `animation`
    /// lines, both without the `bezier =` / `animation =` part. Bad lines are left out and
    /// reported.
    public static func parse(bezier: [String] = [], animation: [String] = []) -> (settings: AnimationSettings, diagnostics: [AnimationDiagnostic]) {
        var settings = AnimationSettings()
        var diagnostics: [AnimationDiagnostic] = []
        for line in bezier {
            if let diagnostic = settings.addCurve(line) { diagnostics.append(diagnostic) }
        }
        for line in animation {
            if let diagnostic = settings.addAnimation(line) { diagnostics.append(diagnostic) }
        }
        return (settings, diagnostics)
    }

    /// The animation part of a hyprland.conf: its `bezier = ...` and `animation = ...` lines,
    /// and `enabled = ...` of the `animations { }` block (or `animations:enabled = ...`).
    /// Everything else is skipped.
    public static func parse(hyprlandConf text: String) -> (settings: AnimationSettings, diagnostics: [AnimationDiagnostic]) {
        var bezier: [String] = []
        var animation: [String] = []
        var enabled: Bool? = nil
        var blocks: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = withoutComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line == "}" {
                _ = blocks.popLast()
                continue
            }
            if line.hasSuffix("{") {
                blocks.append(String(line.dropLast()).trimmingCharacters(in: .whitespaces))
                continue
            }
            guard let equal = line.firstIndex(of: "=") else { continue }
            let key = line[..<equal].trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equal)...])
            switch key {
                case "bezier", "animations:bezier": bezier.append(value)
                case "animation", "animations:animation": animation.append(value)
                case "enabled" where blocks.last == "animations", "animations:enabled":
                    // `enabled = yes, please :)` (Hyprland's own config)
                    let word = value.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    enabled = parseOnOff(word) ?? true
                default: continue
            }
        }
        var result = parse(bezier: bezier, animation: animation)
        if let enabled { result.settings.enabled = enabled }
        return result
    }

    /// One `bezier` line: "NAME, X0, Y0, X1, Y1". Returns the problem, if any.
    @discardableResult
    public mutating func addCurve(_ line: String) -> AnimationDiagnostic? {
        let fields = Self.fields(line)
        guard fields.count == 5, !fields[0].isEmpty else { return .error(line, "expected 'NAME, X0, Y0, X1, Y1'") }
        let values = fields.dropFirst().compactMap { Double($0) }.filter(\.isFinite)
        guard values.count == 4 else { return .error(line, "X0, Y0, X1 and Y1 must be numbers") }
        guard (0 ... 1).contains(values[0]), (0 ... 1).contains(values[2]) else { return .error(line, "X0 and X1 must be in [0, 1]") }
        curves[fields[0]] = CubicBezier(values[0], values[1], values[2], values[3])
        return nil
    }

    /// One `animation` line: "NAME, ONOFF, SPEED, CURVE [, STYLE]", or "NAME, 0" to turn an
    /// animation off. Returns the problem, if any.
    @discardableResult
    public mutating func addAnimation(_ line: String) -> AnimationDiagnostic? {
        let fields = Self.fields(line)
        guard let node = AnimationNode(rawValue: fields[0]) else { return .error(line, "no animation named '\(fields[0])'") }
        guard fields.count >= 2, let on = Self.parseOnOff(fields[1]) else {
            return .error(line, "expected 'NAME, ONOFF, SPEED, CURVE [, STYLE]'")
        }
        var entry = Entry(enabled: on, speed: Self.globalDefault.durationMs / 100, curve: "default", style: nil)
        if fields.count == 2 && !on {
            // `NAME, 0`: off, the rest can be left out
        } else {
            guard fields.count == 4 || fields.count == 5 else { return .error(line, "expected 'NAME, ONOFF, SPEED, CURVE [, STYLE]'") }
            guard let speed = Double(fields[2]), speed.isFinite, speed > 0 else {
                return .error(line, "SPEED must be a number above 0, in tenths of a second")
            }
            guard curves[fields[3]] != nil else { return .error(line, "no curve named '\(fields[3])'") }
            entry.speed = speed
            entry.curve = fields[3]
            if fields.count == 5 && !fields[4].isEmpty {
                guard let style = AnimationStyle.parse(fields[4]) else { return .error(line, "no style '\(fields[4])'") }
                guard node.accepts(style) else { return .error(line, "\(node.rawValue) has no style '\(fields[4])'") }
                entry.style = style
            }
        }
        entries[node] = entry
        if node.isIgnoredOnMacOS { return AnimationDiagnostic.notice(line, "\(node.rawValue) has nothing to animate on macOS, ignored") }
        return nil
    }

    /// The animation of `node`: its own line or the closest ancestor's.
    public func resolve(_ node: AnimationNode) -> AnimationSpec {
        var current: AnimationNode? = node
        while let candidate = current {
            if let entry = entries[candidate] {
                return AnimationSpec(enabled: enabled && entry.enabled, durationMs: entry.speed * 100,
                                     curve: curves[entry.curve] ?? .hyprlandDefault, style: entry.style)
            }
            current = candidate.parent
        }
        var spec = Self.globalDefault
        spec.enabled = spec.enabled && enabled
        return spec
    }

    /// Whether `node` has its own `animation` line.
    public func hasOwnLine(_ node: AnimationNode) -> Bool { entries[node] != nil }

    /// The fields of a line split on commas, trimmed, without a `#` comment.
    static func fields(_ line: String) -> [String] {
        withoutComment(line).split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func withoutComment(_ line: String) -> String {
        guard let hash = line.firstIndex(of: "#") else { return line }
        return String(line[..<hash])
    }

    static func parseOnOff(_ word: String) -> Bool? {
        switch word.lowercased() {
            case "1", "true", "yes", "on": true
            case "0", "false", "no", "off": false
            default: nil
        }
    }
}
