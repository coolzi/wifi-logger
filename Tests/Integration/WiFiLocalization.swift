import Foundation

guard CommandLine.arguments.count == 2,
      let app = Bundle(path: CommandLine.arguments[1]) else {
    fatalError("Expected a path to the built Wi-Fi Logger GUI app.")
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}

require(Set(app.localizations) == ["en", "ru"], "Expected English and Russian in the GUI app.")
require(app.developmentLocalization == "ru", "Expected Russian as the fallback language.")
require(Bundle.preferredLocalizations(from: app.localizations, forPreferences: ["en-GB"]).first == "en",
        "English variants must select the English localization.")
require(Bundle.preferredLocalizations(from: app.localizations, forPreferences: ["ru-RU"]).first == "ru",
        "Russian variants must select the Russian localization.")

guard let resources = app.resourceURL,
      let english = Bundle(url: resources.appendingPathComponent("en.lproj")) else {
    fatalError("The English resource directory is missing.")
}

for (key, value) in [
    ("Начать запись", "Start Recording"),
    ("Сбросить и начать", "Reset and Start"),
    ("Замеры Wi-Fi", "Wi-Fi Measurements"),
    ("дБм", "dBm"),
] {
    require(english.localizedString(forKey: key, value: nil, table: nil) == value,
            "Missing English UI translation for \(key).")
}
require(english.localizedString(forKey: "Записать замеры", value: nil, table: "Help") != "Записать замеры",
        "The help catalog must be included in the GUI bundle.")

for permission in ["NSLocationUsageDescription", "NSLocationWhenInUseUsageDescription"] {
    require(english.localizedString(forKey: permission, value: nil, table: "InfoPlist").contains("access point"),
            "Missing English location permission explanation for \(permission).")
}

print("Both GUI languages and English labels, help, and location descriptions are bundled.")
