// skyland: focus the next / previous tab of the focused window's group (Hyprland changegroupactive)
public struct GroupFocusCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .groupFocus,
        help: group_focus_help_generated,
        flags: [:],
        posArgs: [newMandatoryPosArgParser(\.direction, parseGroupDirection, placeholder: GroupFocusCmdArgs.Direction.unionLiteral)],
    )
    public var direction: Lateinit<Direction> = .uninitialized

    public enum Direction: String, CaseIterable, Sendable {
        case next, prev
    }
}

private func parseGroupDirection(i: PosArgParserInput) -> ParsedCliArgs<GroupFocusCmdArgs.Direction> {
    .init(parseEnum(i.arg, GroupFocusCmdArgs.Direction.self), advanceBy: 1)
}
