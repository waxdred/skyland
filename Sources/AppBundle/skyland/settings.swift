import AppKit
import Common
import SwiftUI

// skyland settings window (`settings` command, alt-i): the visual settings of
// the config as sliders, switches and pickers. Every change is checked with the
// config parser, written to its own line of the config file (comments kept, see
// tomlLines.swift) and applied at once: config reload, plus the skyland script
// that owns the setting (theme, media widget, lock screen).

struct SettingsCommand: Command {
    let args: SettingsCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        showSettingsWindow()
        return .succ
    }
}

/// <repo> of the running app (<repo>/.build/Skyland.app), where bin/ scripts live.
var skylandRepo: URL { Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent() }

@MainActor
func runSkylandScript(_ arguments: [String]) {
    let process = Process()
    process.executableURL = skylandRepo.appending(path: "bin/\(arguments[0])")
    process.arguments = Array(arguments.dropFirst())
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
}

struct SettingField: Identifiable {
    enum Kind {
        case int(ClosedRange<Int>, step: Int, unit: String)
        case bool
        case choice([String])
        case text
    }
    let section: String
    let key: String
    let label: String
    let kind: Kind
    var after: [String]? = nil // skyland script run after a change, e.g. ["skyland-theme", "apply"]
    var id: String { "\(section).\(key)" }
}

private let settingGroups: [(title: String, fields: [SettingField])] = [
    ("Gaps", [
        SettingField(section: "", key: "gaps.inner.horizontal", label: "Inner horizontal", kind: .int(0 ... 40, step: 1, unit: "px")),
        SettingField(section: "", key: "gaps.inner.vertical", label: "Inner vertical", kind: .int(0 ... 40, step: 1, unit: "px")),
        SettingField(section: "", key: "gaps.outer.top", label: "Outer top", kind: .int(0 ... 60, step: 1, unit: "px")),
        SettingField(section: "", key: "gaps.outer.right", label: "Outer right", kind: .int(0 ... 60, step: 1, unit: "px")),
        SettingField(section: "", key: "gaps.outer.bottom", label: "Outer bottom", kind: .int(0 ... 60, step: 1, unit: "px")),
        SettingField(section: "", key: "gaps.outer.left", label: "Outer left", kind: .int(0 ... 60, step: 1, unit: "px")),
    ]),
    ("Layout", [
        SettingField(section: "", key: "dwindle", label: "Dwindle", kind: .bool),
        SettingField(section: "", key: "dwindle-smart-split", label: "Smart split (follows the cursor)", kind: .bool),
        SettingField(section: "", key: "floating-center-percent", label: "Floating size", kind: .int(30 ... 100, step: 5, unit: "%")),
        SettingField(section: "", key: "focus-follows-mouse.enabled", label: "Focus follows mouse", kind: .bool),
        SettingField(section: "", key: "mouse-modifier", label: "Mouse move / resize key", kind: .choice(["alt", "cmd", "ctrl", "ctrl-alt", ""])),
    ]),
    ("Decoration", [
        SettingField(section: "decoration", key: "rounding", label: "Rounding", kind: .int(0 ... 24, step: 1, unit: "px")),
        SettingField(section: "decoration", key: "active-opacity", label: "Active opacity", kind: .int(30 ... 100, step: 1, unit: "%")),
        SettingField(section: "decoration", key: "inactive-opacity", label: "Inactive opacity", kind: .int(30 ... 100, step: 1, unit: "%")),
        SettingField(section: "decoration", key: "border-width", label: "Border width", kind: .int(0 ... 8, step: 1, unit: "px"), after: ["skyland-theme", "apply"]),
        SettingField(section: "decoration", key: "blur", label: "Ghostty blur", kind: .int(0 ... 20, step: 1, unit: ""), after: ["skyland-theme", "apply"]),
    ]),
    ("Animations", [
        SettingField(section: "animations", key: "enabled", label: "Enabled", kind: .bool),
        SettingField(section: "animations", key: "windows-ms", label: "Windows", kind: .int(0 ... 1500, step: 50, unit: "ms")),
        SettingField(section: "animations", key: "workspaces-ms", label: "Workspaces", kind: .int(0 ... 1500, step: 50, unit: "ms")),
        SettingField(section: "animations", key: "fade-ms", label: "Fades", kind: .int(0 ... 1500, step: 50, unit: "ms")),
        SettingField(section: "animations", key: "windows-bezier", label: "Windows curve", kind: .text),
        SettingField(section: "animations", key: "workspaces-bezier", label: "Workspaces curve", kind: .text),
    ]),
    ("Wallpaper", [
        SettingField(section: "wallpaper", key: "dynamic-colors", label: "Colors from the wallpaper", kind: .bool, after: ["skyland-theme", "apply"]),
        SettingField(section: "wallpaper", key: "scheme", label: "Color scheme", kind: .choice(["auto", "scheme-content", "scheme-tonal-spot", "scheme-vibrant", "scheme-expressive", "scheme-fidelity", "scheme-monochrome", "scheme-neutral", "scheme-rainbow", "scheme-fruit-salad"])),
        SettingField(section: "wallpaper", key: "dir", label: "Folder", kind: .text),
    ]),
    ("Media widget and lock screen", [
        SettingField(section: "media", key: "opacity", label: "Media widget opacity", kind: .int(10 ... 100, step: 1, unit: "%"), after: ["skyland-media", "restart"]),
        SettingField(section: "lock", key: "blur", label: "Lock wallpaper blur", kind: .int(0 ... 20, step: 1, unit: ""), after: ["skyland-lock", "refresh"]),
        SettingField(section: "lock", key: "name", label: "Lock name", kind: .text, after: ["skyland-lock", "refresh"]),
    ]),
]

@MainActor
final class SettingsModel: ObservableObject {
    /// Raw TOML values by field id (`'alt'`, `85`, `true`)
    @Published var values: [String: String] = [:]
    @Published var error: String? = nil
    private var pending: [String: Task<Void, Never>] = [:]

    init() { load() }

    var configUrl: URL { readConfig(forceConfigUrl: nil).configUrl }

    func load() {
        let text = (try? String(contentsOf: configUrl, encoding: .utf8)) ?? ""
        for group in settingGroups {
            for field in group.fields { values[field.id] = tomlValue(text, section: field.section, key: field.key) }
        }
    }

    /// Debounced so a slider drag writes once it settles.
    func set(_ field: SettingField, _ raw: String) {
        values[field.id] = raw
        pending[field.id]?.cancel()
        pending[field.id] = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            await write(field, raw)
        }
    }

    private func write(_ field: SettingField, _ raw: String) async {
        let url = configUrl
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { error = "cannot read \(url.path)"; return }
        let newText = tomlSet(text, section: field.section, key: field.key, value: raw)
        let errors = parseConfig(newText).errors
        guard errors.isEmpty else {
            error = errors.map { $0.description(.error) }.joined(separator: "\n")
            return
        }
        error = nil
        do {
            try newText.write(to: url.resolvingSymlinksInPath(), atomically: true, encoding: .utf8)
        } catch {
            self.error = "cannot write \(url.path): \(error.localizedDescription)"
            return
        }
        _ = await reloadConfig_nonCancellable()
        if let after = field.after { runSkylandScript(after) }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var keys: KeysModel
    @AppStorage("skyland.settings.tab") private var tab = "general" // reopens on the last tab

    var body: some View {
        TabView(selection: $tab) {
            GeneralView(model: model).tabItem { Text("General") }.tag("general")
            KeysView(model: keys).tabItem { Text("Keys") }.tag("keys")
        }
        .padding(.top, 8)
        .frame(minWidth: 620, minHeight: 560)
    }
}

private struct GeneralView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            if let error = model.error {
                Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled)
            }
            Section("Look") {
                HStack {
                    Button("Theme…") { runSkylandScript(["skyland-theme", "pick"]) }
                    Button("Wallpaper…") { runSkylandScript(["skyland-wallpaper", "pick"]) }
                    Button("Light / dark") { runSkylandScript(["skyland-theme", "toggle"]) }
                    Spacer()
                    Button("Open config file") { NSWorkspace.shared.open(model.configUrl) }
                }
            }
            ForEach(settingGroups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.fields) { field in row(field) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 520)
    }

    @ViewBuilder
    private func row(_ field: SettingField) -> some View {
        let raw = model.values[field.id]
        switch field.kind {
            case .int(let range, let step, let unit):
                let value = Int(raw ?? "") ?? range.lowerBound
                HStack {
                    Text(field.label)
                    Slider(
                        // no `step:`, it draws a tick per step; rounded to the step instead
                        value: Binding(get: { Double(value) }, set: {
                            let rounded = Int(($0 / Double(step)).rounded()) * step
                            if rounded != value { model.set(field, String(rounded)) }
                        }),
                        in: Double(range.lowerBound) ... Double(range.upperBound),
                    )
                    Text("\(value)\(unit)").monospacedDigit().frame(width: 64, alignment: .trailing)
                }
            case .bool:
                Toggle(field.label, isOn: Binding(get: { raw == "true" }, set: { model.set(field, $0 ? "true" : "false") }))
            case .choice(let options):
                Picker(field.label, selection: Binding(get: { unquote(raw) }, set: { model.set(field, "'\($0)'") })) {
                    ForEach(options, id: \.self) { Text($0.isEmpty ? "off" : $0).tag($0) }
                }
            case .text:
                TextField(field.label, text: Binding(get: { unquote(raw) }, set: { model.set(field, "'\($0)'") }))
        }
    }

    private func unquote(_ raw: String?) -> String {
        guard let raw, raw.count >= 2, raw.first == "'" || raw.first == "\"" else { return raw ?? "" }
        return String(raw.dropFirst().dropLast())
    }
}

@MainActor private var settingsWindow: NSWindow? = nil

@MainActor
func showSettingsWindow() {
    if settingsWindow == nil {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: SettingsModel(), keys: KeysModel())))
        window.title = "skyland settings"
        window.setContentSize(NSSize(width: 720, height: 760))
        window.isReleasedWhenClosed = false
        settingsWindow = window
    } else if let host = settingsWindow?.contentViewController as? NSHostingController<SettingsView> {
        host.rootView.model.load() // the file may have changed by hand
        host.rootView.keys.load()
    }
    guard let window = settingsWindow else { return }
    // on the screen under the mouse; orderFrontRegardless: a background app's activate can be ignored
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
        window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - window.frame.width / 2, y: screen.visibleFrame.midY - window.frame.height / 2))
    }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
}
