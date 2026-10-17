import AppKit
import Common

// skyland: smart gaps / smart border (Hyprland `workspace = w[tv1], gapsout:0, gapsin:0`
// with `bordersize 0` on it, formerly no_gaps_when_only) and per workspace rules.
//
// smart-gaps = true        # a single tiled window on the workspace: no gaps (bar-height kept)
// smart-border = true      # ...and no rotating border nor rounded corners on it
//
// [workspace-rules.8]      # Hyprland `workspace = 8, ...`
// gaps.outer = 0
// gaps.inner = 0
// layout = 'master'        # master | dwindle (at load; the master command still toggles)

struct WorkspaceRule: ConvenienceMutable, Equatable, Sendable {
    var gaps = RuleGaps()
    var layout: String? = nil
}

struct RuleGaps: ConvenienceMutable, Equatable, Sendable {
    var outer: Int? = nil
    var inner: Int? = nil
}

private let ruleGapsParser: [String: any ParserProtocol<RuleGaps>] = [
    "outer": Parser(\.outer) { raw, backtrace in parseInt(raw, backtrace).map { Optional($0) } },
    "inner": Parser(\.inner) { raw, backtrace in parseInt(raw, backtrace).map { Optional($0) } },
]

private let ruleParser: [String: any ParserProtocol<WorkspaceRule>] = [
    "gaps": Parser(\.gaps) { raw, backtrace, c in parseTable(raw, RuleGaps(), ruleGapsParser, backtrace, &c) },
    "layout": Parser(\.layout) { raw, backtrace in
        parseString(raw, backtrace).flatMap { value in
            ["master", "dwindle"].contains(value) ? .success(value)
                : .failure(.init(backtrace, "Expected 'master' or 'dwindle', got '\(value)'"))
        }
    },
]

func parseWorkspaceRules(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> [String: WorkspaceRule] {
    guard case .dict(let table) = raw else {
        c.errors.append(expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, backtrace))
        return [:]
    }
    var rules: [String: WorkspaceRule] = [:]
    for (name, value) in table { rules[name] = parseTable(value, WorkspaceRule(), ruleParser, backtrace + .key(name), &c) }
    return rules
}

extension Workspace {
    /// The only tiled window of the workspace, when smart gaps / border apply to it
    @MainActor
    var onlyTiledWindow: Window? {
        let tiles = rootTilingContainer.allLeafWindowsRecursive
        return tiles.count == 1 ? tiles.first : nil
    }

    /// Gaps of this workspace: the global ones, its rule's, none for a single tiled window
    /// with smart-gaps.
    @MainActor
    var resolvedGaps: ResolvedGaps {
        let base = ResolvedGaps(gaps: config.gaps, monitor: workspaceMonitor)
        if config.smartGaps && onlyTiledWindow != nil { return ResolvedGaps(inner: 0, outer: 0) }
        guard let rule = config.workspaceRules[name]?.gaps else { return base }
        return ResolvedGaps(
            inner: .init(vertical: rule.inner ?? base.inner.vertical, horizontal: rule.inner ?? base.inner.horizontal),
            outer: rule.outer.map { .init(left: $0, bottom: $0, top: $0, right: $0) } ?? base.outer,
        )
    }

    /// The monitor's visible rect padded by this workspace's outer gaps (and bar-height).
    @MainActor
    var visibleRectPaddedByOuterGaps: Rect { workspaceMonitor.visibleRect(paddedBy: resolvedGaps) }
}

/// Smart border: the single tiled window of its workspace has no border nor rounding.
@MainActor
func isSmartBorderless(_ window: Window) -> Bool {
    config.smartBorder && !window.isFloating && window.nodeWorkspace?.onlyTiledWindow === window
}

/// At config load: workspaces with `layout = 'master'` go to the master layout,
/// `'dwindle'` ones leave it (the master command toggles them afterwards).
@MainActor
func applyWorkspaceRuleLayouts() {
    for (name, rule) in config.workspaceRules {
        guard let layout = rule.layout else { continue }
        setMasterWorkspace(name, layout == "master")
    }
}
