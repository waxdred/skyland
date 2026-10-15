// skyland: open the settings window
public struct SettingsCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .settings,
        help: settings_help_generated,
        flags: [:],
        posArgs: [],
    )
}
