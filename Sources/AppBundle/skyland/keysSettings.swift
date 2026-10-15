import AppKit
import Common
import HotKey
import SwiftUI

// skyland settings, Keys tab: the [mode.*.binding] tables as rows (key, command,
// description = trailing comment). Click a key to record a new one (skyland
// hotkeys are suspended meanwhile, esc cancels); duplicates in the mode and keys
// taken by macOS (System Settings > Keyboard > Shortcuts) are flagged. Each change
// is validated with the config parser and written to its own line (tomlLines.swift).

@MainActor
final class KeysModel: ObservableObject {
    @Published var mode = mainModeId
    @Published var entries: [TomlEntry] = []
    @Published var recording: String? = nil // key of the row being re-bound, "" for a new binding
    @Published var error: String? = nil
    private var monitor: Any? = nil

    var modes: [String] { config.modes.keys.sorted { $0 == mainModeId ? true : $1 == mainModeId ? false : $0 < $1 } }
    private var section: String { "mode.\(mode).binding" }

    init() { load() }

    func load() {
        let text = (try? String(contentsOf: readConfig(forceConfigUrl: nil).configUrl, encoding: .utf8)) ?? ""
        entries = tomlEntries(text, section: section)
    }

    /// Replace (or remove, nil) the binding of `key`, or add one when `key` is nil.
    func change(_ key: String?, to entry: TomlEntry?) {
        let url = readConfig(forceConfigUrl: nil).configUrl
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { error = "cannot read \(url.path)"; return }
        var newText: String
        if let key {
            newText = tomlReplace(text, section: section, key: key, with: entry)
        } else if let entry {
            newText = tomlSet(text, section: section, key: entry.key, value: entry.value)
            if !entry.comment.isEmpty { newText = tomlReplace(newText, section: section, key: entry.key, with: entry) }
        } else { return }
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
        Task { _ = await reloadConfig_nonCancellable() }
    }

    // MARK: recording

    func record(_ key: String) {
        stopRecording()
        recording = key
        Task { await setHotkeysSuspended(true) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.recorded(event) }
            return nil
        }
    }

    private func recorded(_ event: NSEvent) {
        guard let target = recording else { return }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53, mods.isEmpty { stopRecording(); return } // esc: cancel
        guard let name = keyName(UInt32(event.keyCode)) else { NSSound.beep(); return }
        let notation = mods.isEmpty ? name : "\(mods.toString())-\(name)"
        stopRecording()
        if target.isEmpty {
            change(nil, to: TomlEntry(key: notation, value: "'exec-and-forget echo'", comment: "new binding"))
        } else if let entry = entries.first(where: { $0.key == target }), notation != target {
            change(target, to: TomlEntry(key: notation, value: entry.value, comment: entry.comment))
        }
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording != nil { Task { await setHotkeysSuspended(false) } }
        recording = nil
    }

    /// Config notation of a key code; letters as the active layout types them (input-source preset).
    private func keyName(_ code: UInt32) -> String? {
        let names = config.keyMapping.resolve().filter { $0.value.carbonKeyCode == code }.keys
        return names.first { $0.count == 1 && $0.first!.isLetter } ?? names.sorted().first
    }

    // MARK: conflicts

    /// Why `key` is a problem in this mode, nil if it is fine.
    func conflict(_ key: String) -> String? {
        let normalized = normalize(key)
        if entries.filter({ normalize($0.key) == normalized }).count > 1 { return "used twice in this mode" }
        guard let (code, mods) = parse(key), !isArrowKey(Key(carbonKeyCode: code) ?? .a) else { return nil } // arrows: skyland's key tap wins
        return macOSShortcut(code, mods).map { "macOS shortcut: \($0)" }
    }

    private func normalize(_ key: String) -> String {
        let parts = key.split(separator: "-").map(String.init)
        return (parts.dropLast().sorted() + parts.suffix(1)).joined(separator: "-")
    }

    private func parse(_ key: String) -> (UInt32, NSEvent.ModifierFlags)? {
        let parts = key.split(separator: "-").map(String.init)
        guard let name = parts.last, let code = config.keyMapping.resolve()[name]?.carbonKeyCode else { return nil }
        var mods: NSEvent.ModifierFlags = []
        for part in parts.dropLast() { mods.insert(modifiersMap[part] ?? []) }
        return (code, mods)
    }
}

/// Enabled macOS symbolic hotkeys (System Settings > Keyboard > Shortcuts) matching a key.
private func macOSShortcut(_ code: UInt32, _ mods: NSEvent.ModifierFlags) -> String? {
    let names = ["28": "screenshot", "29": "screenshot to clipboard", "30": "screenshot area", "31": "screenshot area to clipboard",
                 "32": "Mission Control", "33": "application windows", "36": "show desktop", "60": "previous input source",
                 "61": "next input source", "64": "Spotlight", "65": "Finder search", "79": "move left a space",
                 "81": "move right a space", "118": "switch to Desktop 1", "184": "screenshot options"]
    guard let hotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") else { return nil }
    for (id, raw) in hotkeys {
        guard let item = raw as? [String: Any], item["enabled"] as? Bool == true,
              let parameters = (item["value"] as? [String: Any])?["parameters"] as? [Int], parameters.count == 3,
              UInt32(parameters[1]) == code else { continue }
        let theirs = NSEvent.ModifierFlags(rawValue: UInt(parameters[2])).intersection([.command, .option, .control, .shift])
        if theirs == mods { return names[id] ?? "id \(id)" }
    }
    return nil
}

struct KeysView: View {
    @ObservedObject var model: KeysModel
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Mode", selection: $model.mode) {
                    ForEach(model.modes, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 200)
                .onChange(of: model.mode) { _ in model.load() }
                TextField("Search", text: $search).textFieldStyle(.roundedBorder)
                Button("Add") { model.record("") }
            }
            if model.recording == "" { Text("Press the new key combination (esc cancels)").foregroundStyle(.secondary) }
            if let error = model.error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            List {
                ForEach(model.entries.filter { search.isEmpty || "\($0.key) \($0.value) \($0.comment)".localizedCaseInsensitiveContains(search) },
                        id: \.key) { entry in
                    KeyRow(model: model, entry: entry)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            Text("Click a key to record a new one. Command and description are saved on return.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .onDisappear { model.stopRecording() }
    }
}

private struct KeyRow: View {
    @ObservedObject var model: KeysModel
    let entry: TomlEntry
    @State private var command = ""
    @State private var comment = ""

    var body: some View {
        HStack(spacing: 8) {
            let conflict = model.conflict(entry.key)
            Button(model.recording == entry.key ? "press keys…" : prettyKey(entry.key)) { model.record(entry.key) }
                .font(.system(.body, design: .monospaced))
                .frame(width: 130, alignment: .leading)
                .foregroundStyle(conflict == nil ? Color.primary : Color.orange)
                .help(conflict ?? entry.key)
            TextField("command", text: $command)
                .onSubmit { model.change(entry.key, to: TomlEntry(key: entry.key, value: tomlCommandValue(command), comment: entry.comment)) }
            TextField("description", text: $comment)
                .foregroundStyle(.secondary)
                .onSubmit { model.change(entry.key, to: TomlEntry(key: entry.key, value: entry.value, comment: comment)) }
            Button { model.change(entry.key, to: nil) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
        .onAppear { command = displayCommand(entry.value); comment = entry.comment }
        .onChange(of: entry) { _ in command = displayCommand(entry.value); comment = entry.comment }
    }
}

/// 'close' -> close; arrays stay as TOML (['workspace 1', 'mode main'])
private func displayCommand(_ value: String) -> String {
    guard value.count >= 2, value.first == "'" && value.last == "'" else { return value }
    return String(value.dropFirst().dropLast())
}

private func tomlCommandValue(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("[") { return trimmed }
    if !trimmed.contains("'") { return "'\(trimmed)'" }
    return "\"" + trimmed.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

private func prettyKey(_ key: String) -> String {
    let symbols = ["cmd": "⌘", "alt": "⌥", "ctrl": "⌃", "shift": "⇧", "enter": "↩", "tab": "⇥",
                   "left": "←", "right": "→", "up": "↑", "down": "↓"]
    return key.split(separator: "-").map { symbols[String($0)] ?? $0.uppercased() }.joined()
}
