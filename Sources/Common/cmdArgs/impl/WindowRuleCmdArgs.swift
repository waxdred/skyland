// skyland: per window properties (Hyprland windowrulev2 actions), for `run` of
// [[on-window-detected]] and the CLI
public struct WindowRuleCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .windowRule,
        help: window_rule_help_generated,
        flags: ["--window-id": windowIdSubArgParser()],
        posArgs: [
            newMandatoryPosArgParser(\.property, parseWindowRuleProperty, placeholder: WindowRuleCmdArgs.Property.unionLiteral),
            ArgParser(\.value1, upcastArgParserFun(consumeStrCliArg)),
            ArgParser(\.value2, upcastArgParserFun(consumeStrCliArg)),
        ],
    )
    public var property: Lateinit<Property> = .uninitialized
    public var value1: String? = nil
    public var value2: String? = nil

    public enum Property: String, CaseIterable, Sendable {
        case size, move, center, opacity, rounding, noborder, nodim, noanim
    }
}

private func parseWindowRuleProperty(i: PosArgParserInput) -> ParsedCliArgs<WindowRuleCmdArgs.Property> {
    .init(parseEnum(i.arg, WindowRuleCmdArgs.Property.self), advanceBy: 1)
}
