// skyland: Hyprland pin, a floating window shown on every workspace of its monitor
public struct PinCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .pin,
        help: pin_help_generated,
        flags: ["--window-id": windowIdSubArgParser()],
        posArgs: [ArgParser(\.toggle, parseToggleEnum)],
    )
    public var toggle: ToggleEnum = .toggle
}
