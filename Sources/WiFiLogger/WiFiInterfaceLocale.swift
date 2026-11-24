import Foundation

enum WiFiInterfaceLocale {
    private static let language = Bundle.main.preferredLocalizations.first ?? "ru"
    static let current = language == "ru" ? Locale(identifier: "ru_RU") : Locale.current
    static let isRightToLeft = Locale.Language(identifier: language).characterDirection == .rightToLeft
}
