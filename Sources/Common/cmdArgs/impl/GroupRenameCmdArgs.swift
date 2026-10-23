// skyland: name the group (accordion container) of the focused window
public struct GroupRenameCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .groupRename,
        help: group_rename_help_generated,
        flags: [:],
        posArgs: [ArgParser(\.name, upcastArgParserFun(parseGroupName))],
    )
    /// nil: ask for it in a popup
    public var name: String? = nil
}

/// The rest of the line, so `group-rename my group` needs no quotes.
private func parseGroupName(i: PosArgParserInput) -> ParsedCliArgs<String> {
    let words = i.nonFlagArgs()
    return .succ(words.joined(separator: " "), advanceBy: words.count)
}
