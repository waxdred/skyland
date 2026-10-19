// End-to-end check that no window is lost: opens throwaway windows (Calculator, one
// instance each) on two workspaces, then switches, moves, closes and opens windows in a
// loop, fast and slow. After each step, once the animations are over, every test window
// of the focused workspace must be on screen, inside a display, and not see-through
// (alpha 0.5 or more: inactive-opacity is above that).
//
//   swiftc -O tools/e2e-visibility.swift -o .build/e2e-visibility
//   .build/e2e-visibility [workspace-a] [workspace-b] [rounds]    # defaults: 11 12 40
//
// It switches workspaces on the running skyland: use workspaces you do not need, and keep
// your hands off for the minute it takes. The test windows are closed at the end and the
// workspace you were on is shown again. Exit code 1 when a window was lost.
import AppKit

let args = CommandLine.arguments
let wsA = args.count > 1 ? args[1] : "11", wsB = args.count > 2 ? args[2] : "12"
let rounds = args.count > 3 ? Int(args[3]) ?? 40 : 40

@discardableResult
func skyland(_ arguments: String...) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["skyland"] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

func sleep(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

/// window id -> pid, for the test windows skyland knows on a workspace
func windows(on workspace: String, pids: Set<pid_t>) -> [UInt32: pid_t] {
    var result: [UInt32: pid_t] = [:]
    for line in skyland("list-windows", "--workspace", workspace, "--format", "%{window-id} %{app-pid}").split(separator: "\n") {
        let parts = line.split(separator: " ")
        if parts.count == 2, let id = UInt32(parts[0]), let pid = pid_t(parts[1]), pids.contains(pid) { result[id] = pid }
    }
    return result
}

func openWindow(on workspace: String, pids: inout Set<pid_t>) {
    skyland("workspace", workspace)
    let before = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.calculator").map(\.processIdentifier))
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-n", "-a", "Calculator"]
    try? open.run()
    open.waitUntilExit()
    for _ in 0 ..< 40 { // its window, managed by skyland
        sleep(0.1)
        let new = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.calculator").map(\.processIdentifier)).subtracting(before)
        if let pid = new.first, windows(on: workspace, pids: [pid]).count > 0 {
            pids.insert(pid)
            return
        }
    }
    print("warning: a Calculator window did not show up on \(workspace)")
}

var failures: [String] = []

/// The test windows of the focused workspace, as the window server shows them.
func check(_ step: String, pids: Set<pid_t>) {
    let focused = skyland("list-workspaces", "--focused").trimmingCharacters(in: .whitespacesAndNewlines)
    let expected = windows(on: focused, pids: pids)
    let infos = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    let screens = NSScreen.screens.map { screen -> CGRect in // top-left origin, as CGWindowList
        let height = NSScreen.screens[0].frame.height
        return CGRect(x: screen.frame.minX, y: height - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
    }
    for (id, _) in expected {
        guard let info = infos.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == id }) else {
            failures.append("\(step): window \(id) on \(focused) is gone from the window server")
            continue
        }
        let alpha = info[kCGWindowAlpha as String] as? Double ?? 0
        let onscreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
        let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
        let visible = screens.contains { $0.intersection(bounds).width >= bounds.width * 0.5 && $0.intersection(bounds).height >= bounds.height * 0.5 }
        if alpha < 0.5 || !onscreen || !visible {
            failures.append("\(step): window \(id) on \(focused): alpha \(alpha), onscreen \(onscreen), frame \(bounds)")
        }
    }
}

/// The animations are over: a step is checked once its windows have settled.
func settle() { sleep(1.2) }

let start = skyland("list-workspaces", "--focused").trimmingCharacters(in: .whitespacesAndNewlines)
var pids = Set<pid_t>()
openWindow(on: wsA, pids: &pids)
openWindow(on: wsA, pids: &pids)
openWindow(on: wsB, pids: &pids)
settle()
check("setup", pids: pids)

var random = SystemRandomNumberGenerator()
for round in 1 ... rounds {
    let other = { (ws: String) in ws == wsA ? wsB : wsA }
    let focused = skyland("list-workspaces", "--focused").trimmingCharacters(in: .whitespacesAndNewlines)
    let step: String
    switch Int.random(in: 0 ..< 6, using: &random) {
        case 0:
            step = "switch"
            skyland("workspace", other(focused))
        case 1: // fast switches, the last one checked
            step = "fast switches"
            for _ in 0 ..< 6 {
                skyland("workspace", wsA)
                sleep(0.05)
                skyland("workspace", wsB)
                sleep(0.05)
            }
        case 2:
            step = "move a window"
            if let id = windows(on: focused, pids: pids).keys.randomElement(using: &random) {
                skyland("move-node-to-workspace", "--window-id", String(id), other(focused))
            }
        case 3:
            step = "move a window and follow it"
            if let id = windows(on: focused, pids: pids).keys.randomElement(using: &random) {
                skyland("move-node-to-workspace", "--window-id", String(id), "--focus-follows-window", other(focused))
            }
        case 4:
            step = "close a window"
            let mine = windows(on: focused, pids: pids)
            if mine.count > 1, let (_, pid) = mine.randomElement(using: &random) {
                NSRunningApplication(processIdentifier: pid)?.forceTerminate()
                pids.remove(pid)
            }
        default:
            step = "open a window"
            if pids.count < 6 { openWindow(on: focused, pids: &pids) }
    }
    settle()
    check("round \(round) (\(step))", pids: pids)
}

for pid in pids { NSRunningApplication(processIdentifier: pid)?.forceTerminate() }
skyland("workspace", start)
if failures.isEmpty {
    print("e2e-visibility ok: \(rounds) rounds, no window lost")
} else {
    failures.forEach { print("LOST \($0)") }
    exit(1)
}
