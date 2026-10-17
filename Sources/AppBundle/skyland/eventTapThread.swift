import AppKit
import os

// skyland: the session event taps (arrow key bindings, mouse-modifier drags) run on
// their own thread. Every key press and click of every app goes through them: on the
// main run loop they waited for whatever skyland's main thread was busy with (refresh
// sessions, layouts, payload calls). The callbacks let the events skyland does not
// want through right away, and only hop to the main thread for the ones it may consume.

nonisolated(unsafe) private let tapRunLoop: CFRunLoop = {
    let ready = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var loop: CFRunLoop? = nil
    let thread = Thread {
        loop = CFRunLoopGetCurrent()
        RunLoop.current.add(NSMachPort(), forMode: .default) // keeps the run loop alive until a tap is added
        ready.signal()
        RunLoop.current.run()
    }
    thread.name = "skyland event taps"
    thread.qualityOfService = .userInteractive
    thread.start()
    ready.wait()
    return unsafe loop!
}()

/// Runs `tap` on the event tap thread.
func addToEventTapThread(_ tap: CFMachPort) {
    CFRunLoopAddSource(tapRunLoop, CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    CFRunLoopWakeUp(tapRunLoop)
}

/// From an event tap callback: runs `body` on the main thread and waits for it.
func onMainForTap<T: Sendable>(_ body: @MainActor () -> T) -> T {
    DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
}
