// skyland: Hyprland special workspaces (togglespecialworkspace)
public struct ScratchpadCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .scratchpad,
        help: scratchpad_help_generated,
        flags: ["--app": singleValueSubArgParser(\.app, "<app-bundle-id>") { .success($0) }],
        posArgs: [
            newMandatoryPosArgParser(\.action, parseScratchpadAction, placeholder: ScratchpadCmdArgs.Action.unionLiteral),
            ArgParser(\.name, upcastArgParserFun(parseScratchpadName)),
        ],
    )
    public var action: Lateinit<Action> = .uninitialized
    public var name: String? = nil
    public var app: String? = nil

    public enum Action: String, CaseIterable, Sendable {
        case toggle, move
    }
}

private func parseScratchpadAction(i: PosArgParserInput) -> ParsedCliArgs<ScratchpadCmdArgs.Action> {
    .init(parseEnum(i.arg, ScratchpadCmdArgs.Action.self), advanceBy: 1)
}

private func parseScratchpadName(i: PosArgParserInput) -> ParsedCliArgs<String> {
    i.arg.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        ? .succ(i.arg, advanceBy: 1)
        : .fail("Bad scratchpad name \(i.arg.singleQuoted): letters, digits, - and _", advanceBy: 1)
}
