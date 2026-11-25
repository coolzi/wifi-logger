import Testing

@testable import WiFiLogger

@Test(arguments: [
    [],
    ["-AppleLanguages", "(en)"],
    ["-AppleLocale", "ru_RU"],
    ["-AppleLocale", "en_US", "-AppleLanguages", "(en, ru)"],
])
func guiLaunchAcceptsFoundationArguments(_ arguments: [String]) {
    #expect(WiFiLogger.isGUILaunch(executable: "wifi-logger-app", arguments: arguments))
    #expect(!WiFiLogger.isGUILaunch(executable: "wifi-logger", arguments: arguments))
}

@Test(arguments: [
    ["-h"],
    ["--help"],
    ["--request-location"],
    ["--app-session", "123", "--request-location"],
    ["--read-spatial-streams", "en0"],
    ["--unknown"],
    ["-AppleLanguages"],
    ["-AppleLocale", ""],
    ["-AppleLocale", "--help"],
    ["-AppleLanguages", "(en)", "--request-location"],
])
func guiLaunchLeavesOtherArgumentsToTheExistingDispatch(_ arguments: [String]) {
    #expect(!WiFiLogger.isGUILaunch(executable: "wifi-logger-app", arguments: arguments))
}
