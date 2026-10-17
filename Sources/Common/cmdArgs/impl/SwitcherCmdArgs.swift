// skyland: window switcher, recent windows of every workspace (hyprswitch, cmd-tab for windows)
public struct SwitcherCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .switcher,
        help: switcher_help_generated,
        flags: ["--workspace": singleValueSubArgParser(\.scope, "focused|all") { parseEnum($0, Scope.self) }],
        posArgs: [ArgParser(\.direction, upcastArgParserFun(parseSwitcherDirection))],
    )
    public var direction: Direction? = nil
    public var scope: Scope? = nil

    public enum Direction: String, CaseIterable, Sendable {
        case next, prev
    }

    public enum Scope: String, CaseIterable, Sendable {
        case focused, all
    }
}

private func parseSwitcherDirection(i: PosArgParserInput) -> ParsedCliArgs<SwitcherCmdArgs.Direction> {
    .init(parseEnum(i.arg, SwitcherCmdArgs.Direction.self), advanceBy: 1)
}
