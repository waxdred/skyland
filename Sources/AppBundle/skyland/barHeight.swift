import Common

// skyland: `bar-height <px>|default`. A bar sends its own height over the socket
// (`skyland bar-height 36` when it starts or resizes) instead of `bar-height` in the
// config; windows are laid out below it on every monitor. `default` goes back to the
// config value (the bar quits), no argument prints the height in use.

/// Set by the bar, over the config's `bar-height`. Kept across config reloads.
@MainActor private var barHeightFromBar: Int? = nil

@MainActor var barHeight: Int { barHeightFromBar ?? config.barHeight }

struct BarHeightCommand: Command {
    let args: BarHeightCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let height = args.height else { return .succ(io.out("\(barHeight)")) }
        barHeightFromBar = height
        return .succ // the session's refresh lays the windows out again
    }
}
