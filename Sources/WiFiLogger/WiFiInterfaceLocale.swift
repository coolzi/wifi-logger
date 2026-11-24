import Foundation

enum WiFiInterfaceLocale {
    static let current = Bundle.main.preferredLocalizations.first == "en"
        ? Locale.current : Locale(identifier: "ru_RU")
}
