import AppKit
import Common
import SwiftUI

// skyland settings, Rules tab: `[[on-window-detected]]` rules per app (Hyprland
// windowrule): float / tile and a workspace, for the apps that have a rule and the
// apps running now. A rule is written as its own block
//     [[on-window-detected]]
//     if.app-id = 'com.hnc.Discord' # Discord
//     run = ['layout floating', 'move-node-to-workspace 8']
// plus window properties ('window-rule size 60% 70%', 'window-rule center', opacity,
// rounding, noanim / nodim / noborder) under "More".
// Blocks with other conditions or commands are shown as custom, left as they are.
// "Apply to open windows" also runs the commands on the app's current windows.

struct AppRule: Identifiable {
    let appId: String
    var name: String
    var layout = "" // "", "floating", "tiling"
    var workspace = "" // "" or a workspace name
    var extras: [String] = [] // `window-rule ...` commands, in order
    var block: TomlBlock? = nil
    var custom = false
    var id: String { appId }
}

@MainActor
final class RulesModel: ObservableObject {
    @Published var rules: [AppRule] = []
    @Published var error: String? = nil
    @AppStorage("skyland.settings.rules.applyNow") var applyNow = true

    init() { load() }

    func load() {
        let text = (try? String(contentsOf: readConfig(forceConfigUrl: nil).configUrl, encoding: .utf8)) ?? ""
        var result: [AppRule] = []
        for block in tomlBlocks(text, name: "on-window-detected") {
            let appIdEntry = block.entries.first { $0.key == "if.app-id" }
            guard let appIdEntry else { continue } // title-only rules: not per app
            let appId = unquote(appIdEntry.value)
            var rule = AppRule(appId: appId, name: appIdEntry.comment.isEmpty ? appName(appId) : appIdEntry.comment, block: block)
            rule.custom = block.entries.contains { $0.key != "if.app-id" && $0.key != "run" }
            for command in runCommands(block.entries.first { $0.key == "run" }?.value ?? "") {
                if command == "layout floating" || command == "layout tiling" {
                    rule.layout = String(command.dropFirst("layout ".count))
                } else if command.hasPrefix("move-node-to-workspace "), !command.dropFirst(23).contains(" ") {
                    rule.workspace = String(command.dropFirst(23))
                } else if command.hasPrefix("window-rule ") {
                    rule.extras.append(command)
                } else {
                    rule.custom = true
                }
            }
            result.append(rule)
        }
        let ruled = Set(result.map(\.appId))
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && !ruled.contains($0.bundleIdentifier!) }
            .map { AppRule(appId: $0.bundleIdentifier!, name: $0.localizedName ?? $0.bundleIdentifier!) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        rules = result + running
    }

    func set(_ rule: AppRule, layout: String, workspace: String, extras: [String]? = nil) {
        var commands: [String] = []
        if !layout.isEmpty { commands.append("layout \(layout)") }
        if !workspace.isEmpty { commands.append("move-node-to-workspace \(workspace)") }
        commands += extras ?? rule.extras
        let run = commands.count == 1 ? "'\(commands[0])'" : "[" + commands.map { "'\($0)'" }.joined(separator: ", ") + "]"
        let lines = commands.isEmpty ? [] : ["[[on-window-detected]]", "if.app-id = '\(rule.appId)' # \(rule.name)", "run = \(run)"]
        let url = readConfig(forceConfigUrl: nil).configUrl
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { error = "cannot read \(url.path)"; return }
        guard rule.block != nil || !lines.isEmpty else { return }
        let newText = tomlReplaceBlock(text, name: "on-window-detected", rule.block, with: lines)
        let errors = parseConfig(newText).errors
        guard errors.isEmpty else { error = errors.map { $0.description(.error) }.joined(separator: "\n"); return }
        do {
            try newText.write(to: url.resolvingSymlinksInPath(), atomically: true, encoding: .utf8)
        } catch {
            self.error = "cannot write \(url.path): \(error.localizedDescription)"
            return
        }
        error = nil
        load()
        Task {
            _ = await reloadConfig_nonCancellable()
            guard applyNow else { return }
            for window in MacWindow.allWindows where window.app.rawAppBundleId == rule.appId {
                for command in commands { await runSkylandCommand("\(command) --window-id \(window.windowId)") }
            }
        }
    }

    /// 'a' or ['a', 'b'] -> commands
    private func runCommands(_ value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") else { return [unquote(trimmed)] }
        return trimmed.dropFirst().dropLast().split(separator: ",").map { unquote($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func unquote(_ raw: String) -> String {
        guard raw.count >= 2, let first = raw.first, first == "'" || first == "\"", raw.last == first else { return raw }
        return String(raw.dropFirst().dropLast())
    }

    private func appName(_ appId: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: appId)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? appId
    }
}

struct RulesView: View {
    @ObservedObject var model: RulesModel
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search", text: $search).textFieldStyle(.roundedBorder)
                Toggle("Apply to open windows", isOn: $model.applyNow)
                Button("Refresh") { model.load() }
            }
            if let error = model.error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            List {
                ForEach(model.rules.filter { search.isEmpty || "\($0.name) \($0.appId)".localizedCaseInsensitiveContains(search) }) { rule in
                    RuleRow(model: model, rule: rule)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            Text("Apps with a rule first, then the running apps. Custom rules (other conditions or commands) are edited in the config file.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }
}

private struct RuleRow: View {
    @ObservedObject var model: RulesModel
    let rule: AppRule
    @State private var showMore = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.name)
                Text(rule.appId).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if rule.custom {
                Text("custom rule").foregroundStyle(.secondary)
            } else {
                Button(rule.extras.isEmpty ? "More" : "More (\(rule.extras.count))") { showMore.toggle() }
                    .popover(isPresented: $showMore, arrowEdge: .bottom) { RuleExtras(model: model, rule: rule) }
                Picker("", selection: Binding(get: { rule.layout }, set: { model.set(rule, layout: $0, workspace: rule.workspace) })) {
                    Text("default").tag("")
                    Text("float").tag("floating")
                    Text("tile").tag("tiling")
                }
                .frame(width: 110)
                Picker("", selection: Binding(get: { rule.workspace }, set: { model.set(rule, layout: rule.layout, workspace: $0) })) {
                    Text("any workspace").tag("")
                    ForEach(workspaceNames, id: \.self) { Text("workspace \($0)").tag($0) }
                }
                .frame(width: 150)
            }
        }
    }

    private var workspaceNames: [String] {
        let names = config.persistentWorkspaces.isEmpty ? Workspace.all.map(\.name) : Array(config.persistentWorkspaces)
        return Set(names + (rule.workspace.isEmpty ? [] : [rule.workspace]))
            .filter { !$0.isEmpty && !$0.hasPrefix(scratchpadWorkspaceName) }
            .sorted { (Int($0) ?? .max, $0) < (Int($1) ?? .max, $1) }
    }

    private var icon: NSImage {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.appId)
            .map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
    }
}

/// The window properties of a rule (`window-rule` commands): size and center need the
/// window floating.
private struct RuleExtras: View {
    @ObservedObject var model: RulesModel
    let rule: AppRule
    @State private var size = ""
    @State private var opacity = ""
    @State private var rounding = ""
    @State private var center = false
    @State private var noAnim = false
    @State private var noDim = false
    @State private var noBorder = false

    var body: some View {
        Form {
            TextField("Size (floating)", text: $size, prompt: Text("60% 70% or 900 600"))
            Toggle("Centered (floating)", isOn: $center)
            TextField("Opacity", text: $opacity, prompt: Text("95 or 95 80 (active inactive)"))
            TextField("Rounding", text: $rounding, prompt: Text("px"))
            Toggle("No animation", isOn: $noAnim)
            Toggle("No dim", isOn: $noDim)
            Toggle("No border", isOn: $noBorder)
            HStack {
                Spacer()
                Button("Save") { model.set(rule, layout: rule.layout, workspace: rule.workspace, extras: commands) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 360)
        .onAppear(perform: load)
    }

    private func value(_ name: String) -> String? {
        rule.extras.first { $0.hasPrefix("window-rule \(name)") }.map { String($0.dropFirst("window-rule \(name)".count)).trimmingCharacters(in: .whitespaces) }
    }

    private func load() {
        size = value("size") ?? ""
        opacity = value("opacity") ?? ""
        rounding = value("rounding") ?? ""
        center = value("center") != nil
        noAnim = value("noanim") != nil
        noDim = value("nodim") != nil
        noBorder = value("noborder") != nil
    }

    private var commands: [String] {
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespaces) }
        var result: [String] = []
        if !trim(size).isEmpty { result.append("window-rule size \(trim(size))") }
        if center { result.append("window-rule center") }
        if !trim(opacity).isEmpty { result.append("window-rule opacity \(trim(opacity))") }
        if !trim(rounding).isEmpty { result.append("window-rule rounding \(trim(rounding))") }
        if noAnim { result.append("window-rule noanim") }
        if noDim { result.append("window-rule nodim") }
        if noBorder { result.append("window-rule noborder") }
        return result
    }
}
