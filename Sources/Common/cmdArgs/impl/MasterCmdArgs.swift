// skyland: Hyprland master layout of the focused workspace
public struct MasterCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .master,
        help: master_help_generated,
        flags: [:],
        posArgs: [newMandatoryPosArgParser(\.action, parseMasterAction, placeholder: MasterCmdArgs.Action.unionLiteral)],
    )
    public var action: Lateinit<Action> = .uninitialized

    public enum Action: String, CaseIterable, Sendable {
        case on, off, toggle, swap, focus
    }
}

private func parseMasterAction(i: PosArgParserInput) -> ParsedCliArgs<MasterCmdArgs.Action> {
    .init(parseEnum(i.arg, MasterCmdArgs.Action.self), advanceBy: 1)
}
