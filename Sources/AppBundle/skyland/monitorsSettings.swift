import AppKit
import Common
import SwiftUI

// skyland settings, Monitors tab: the screens laid out as in System Settings > Displays,
// each workspace a chip on the screen it is on. Dropping a chip on a screen (or its menu)
// writes the workspace's line of [workspace-to-monitor-force-assignment]
//     5 = [2, 1]  # monitor 2, else monitor 1 when it is not plugged
// "No rule" removes the line: the workspace goes where it is focused.

struct MonitorBox: Identifiable {
    let id: Int // sequence number from left to right, the pattern written
    let name: String
    let rect: Rect
    let isMain: Bool
}

/// The pattern for monitor `id`: the monitor, then the ones on its left as fallbacks,
/// so the workspace still lands somewhere with fewer screens plugged.
func monitorAssignmentValue(_ id: Int) -> String {
    id <= 1 ? "1" : "[" + stride(from: id, through: 1, by: -1).map(String.init).joined(separator: ", ") + "]"
}

@MainActor
final class MonitorsModel: ObservableObject {
    @Published var monitors: [MonitorBox] = []
    /// workspace -> raw TOML pattern of its assignment line
    @Published var assigned: [String: String] = [:]
    /// workspace -> monitor it is on now
    @Published var current: [String: Int] = [:]
    @Published var error: String? = nil
    static let section = "workspace-to-monitor-force-assignment"

    init() { load() }

    func load() {
        monitors = sortedMonitorInfos.enumerated().map { MonitorBox(id: $0.offset + 1, name: $0.element.name, rect: $0.element.rect, isMain: $0.element.isMain) }
        let text = (try? String(contentsOf: readConfig(forceConfigUrl: nil).configUrl, encoding: .utf8)) ?? ""
        assigned = Dictionary(tomlEntries(text, section: Self.section).map { (unquote($0.key), $0.value) }, uniquingKeysWith: { $1 })
        current = Dictionary(workspaces.map { ($0, Workspace.get(byName: $0).workspaceMonitor.monitorId_oneBased ?? 1) }, uniquingKeysWith: { $1 })
    }

    var workspaces: [String] {
        let names = config.persistentWorkspaces.isEmpty ? Workspace.all.map(\.name) : Array(config.persistentWorkspaces)
        return Set(names + assigned.keys)
            .filter { !$0.isEmpty && !$0.hasPrefix(scratchpadWorkspaceName) }
            .sorted { (Int($0) ?? .max, $0) < (Int($1) ?? .max, $1) }
    }

    /// Writes (nil: removes) the workspace's line, reloads, puts the workspace there now.
    func assign(_ workspace: String, to monitor: Int?) {
        let url = readConfig(forceConfigUrl: nil).configUrl
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { error = "cannot read \(url.path)"; return }
        let key = tomlEntries(text, section: Self.section).first { unquote($0.key) == workspace }?.key
            ?? (workspace.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } ? workspace : "'\(workspace)'")
        let newText = if let monitor {
            tomlSet(text, section: Self.section, key: key, value: monitorAssignmentValue(monitor))
        } else {
            tomlReplace(text, section: Self.section, key: key, with: nil)
        }
        guard newText != text else { return }
        let errors = parseConfig(newText).errors
        guard errors.isEmpty else { error = errors.map { $0.description(.error) }.joined(separator: "\n"); return }
        do {
            try newText.write(to: url.resolvingSymlinksInPath(), atomically: true, encoding: .utf8)
        } catch {
            self.error = "cannot write \(url.path): \(error.localizedDescription)"
            return
        }
        error = nil
        Task {
            _ = await reloadConfig_nonCancellable()
            load()
        }
    }

    private func unquote(_ raw: String) -> String {
        guard raw.count >= 2, let first = raw.first, first == "'" || first == "\"", raw.last == first else { return raw }
        return String(raw.dropFirst().dropLast())
    }
}

struct MonitorsView: View {
    @ObservedObject var model: MonitorsModel
    @State private var target: Int? = nil // the screen a chip is dragged over

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Drag a workspace onto a screen, or click it.").foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { model.load() }
            }
            if let error = model.error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            GeometryReader { geometry in
                let layout = Layout(model.monitors, in: geometry.size)
                ZStack(alignment: .topLeading) {
                    ForEach(model.monitors) { monitor in
                        screen(monitor).frame(width: layout.frame(monitor).width, height: layout.frame(monitor).height)
                            .offset(x: layout.frame(monitor).minX, y: layout.frame(monitor).minY)
                    }
                }
            }
            .frame(minHeight: 300)
            Text("A workspace with a rule (pin) always opens on its screen, or the screens on its left when that one is unplugged. Without a rule it goes where it is focused. Written to [workspace-to-monitor-force-assignment].")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }

    private func screen(_ monitor: MonitorBox) -> some View {
        let workspaces = model.workspaces.filter { model.current[$0] == monitor.id }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(monitor.id)").font(.system(.headline, design: .monospaced)).foregroundStyle(Color.accentColor)
                Text(monitor.name).font(.callout).lineLimit(1)
                if monitor.isMain { Text("main").font(.caption2).padding(.horizontal, 5).background(Capsule().fill(.quaternary)) }
                Spacer()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(workspaces, id: \.self) { chip($0) }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(target == monitor.id ? 0.25 : 0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(target == monitor.id ? 1 : 0.4), lineWidth: target == monitor.id ? 2 : 1))
        .dropDestination(for: String.self) { items, _ in
            guard let workspace = items.first else { return false }
            model.assign(workspace, to: monitor.id)
            return true
        } isTargeted: { inside in
            if inside { target = monitor.id } else if target == monitor.id { target = nil }
        }
    }

    private func chip(_ workspace: String) -> some View {
        let rule = model.assigned[workspace]
        return Menu {
            ForEach(model.monitors) { monitor in
                Button("\(monitor.id) · \(monitor.name)") { model.assign(workspace, to: monitor.id) }
            }
            Divider()
            Button("No rule (where it is focused)") { model.assign(workspace, to: nil) }.disabled(rule == nil)
        } label: {
            HStack(spacing: 3) {
                if rule != nil { Image(systemName: "pin.fill").font(.system(size: 8)) }
                Text(workspace).font(.system(.callout, design: .monospaced).weight(.semibold))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(rule != nil ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.2)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain) // the chip as drawn, not a bordered button
        .menuIndicator(.hidden)
        .fixedSize()
        .help(rule.map { "rule: \(workspace) = \($0)" } ?? "no rule")
        .draggable(workspace)
    }

    /// The screens' arrangement scaled into the view, centered, with a little room between them.
    private struct Layout {
        let scale: CGFloat, offset: CGPoint, bounds: CGRect

        init(_ monitors: [MonitorBox], in size: CGSize) {
            let rects = monitors.map { CGRect(x: $0.rect.topLeftX, y: $0.rect.topLeftY, width: $0.rect.width, height: $0.rect.height) }
            bounds = rects.reduce(rects.first ?? .zero) { $0.union($1) }
            scale = bounds.width > 0 && bounds.height > 0 ? min(size.width / bounds.width, size.height / bounds.height) : 1
            offset = CGPoint(x: (size.width - bounds.width * scale) / 2, y: (size.height - bounds.height * scale) / 2)
        }

        func frame(_ monitor: MonitorBox) -> CGRect {
            CGRect(x: offset.x + (monitor.rect.topLeftX - bounds.minX) * scale, y: offset.y + (monitor.rect.topLeftY - bounds.minY) * scale,
                   width: monitor.rect.width * scale, height: monitor.rect.height * scale).insetBy(dx: 4, dy: 4)
        }
    }
}
