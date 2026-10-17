// skyland: the height of a bar (SkylandBar, sketchybar) told by the bar itself, windows stay below it
public struct BarHeightCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .barHeight,
        help: bar_height_help_generated,
        flags: [:],
        posArgs: [ArgParser(\.height, upcastArgParserFun(parseBarHeight))],
    )
    /// nil: print the height in use; .some(nil): back to the config's `bar-height`
    public var height: Int?? = nil
}

private func parseBarHeight(i: PosArgParserInput) -> ParsedCliArgs<Int?> {
    if i.arg == "default" { return .succ(nil, advanceBy: 1) }
    guard let value = Int(i.arg), (0 ... 500).contains(value) else {
        return .fail("Expected a height in px (0-500) or 'default', got \(i.arg.singleQuoted)", advanceBy: 1)
    }
    return .succ(value, advanceBy: 1)
}
