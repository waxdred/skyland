// skyland: keyboard actions of the workspace overview (overview.swift), for [mode.overview.binding]
public struct OverviewCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .overview,
        help: overview_help_generated,
        flags: [:],
        posArgs: [newMandatoryPosArgParser(\.action, parseOverviewAction, placeholder: OverviewCmdArgs.Action.unionLiteral)],
    )
    public var action: Lateinit<Action> = .uninitialized

    public enum Action: String, CaseIterable, Sendable {
        case next, prev, confirm, close, search
    }
}

private func parseOverviewAction(i: PosArgParserInput) -> ParsedCliArgs<OverviewCmdArgs.Action> {
    .init(parseEnum(i.arg, OverviewCmdArgs.Action.self), advanceBy: 1)
}
