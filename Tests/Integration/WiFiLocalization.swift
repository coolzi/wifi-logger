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

let supported = ["ar", "bn", "en", "es", "fr", "hi", "id", "pt", "ru", "ur", "zh-Hans"]
require(Set(app.localizations) == Set(supported), "Expected all eleven languages in the GUI app.")
require(app.developmentLocalization == "ru", "Expected Russian as the fallback language.")
for (preference, expected) in [
    ("ar-SA", "ar"), ("bn-BD", "bn"), ("en-GB", "en"), ("es-MX", "es"), ("fr-CA", "fr"),
    ("hi-IN", "hi"), ("id-ID", "id"), ("pt-BR", "pt"), ("ru-RU", "ru"), ("ur-PK", "ur"), ("zh-CN", "zh-Hans"),
] {
    require(Bundle.preferredLocalizations(from: app.localizations, forPreferences: [preference]).first == expected,
            "Expected \(preference) to select \(expected).")
}

guard let resources = app.resourceURL else { fatalError("The app resources are missing.") }

func catalog(_ table: String, language: String) throws -> [String: String] {
    let file = resources.appendingPathComponent("\(language).lproj/\(table).strings")
    let data = try Data(contentsOf: file)
    let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    guard let strings = plist as? [String: String] else {
        fatalError("Invalid \(language)/\(table).strings")
    }
    return strings
}

let arguments = try NSRegularExpression(pattern: "%(?:[0-9]+\\$)?(?:@|lld)")
func placeholders(_ value: String) -> [String] {
    arguments.matches(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)).map {
        (value as NSString).substring(with: $0.range)
    }
}

for table in ["Localizable", "Help", "InfoPlist"] {
    let english = try catalog(table, language: "en")
    for language in supported where language != "en" && (language != "ru" || table == "InfoPlist") {
        let translated = try catalog(table, language: language)
        require(Set(english.keys) == Set(translated.keys), "Key mismatch in \(language)/\(table).strings.")
        for (key, value) in english {
            guard let translation = translated[key] else { fatalError("Missing \(language) key \(key)") }
            require(!translation.isEmpty, "Empty translation in \(language)/\(table).strings for \(key).")
            require(placeholders(translation) == placeholders(value),
                    "Placeholder mismatch in \(language)/\(table).strings for \(key).")
        }
    }
}

let englishUI = try catalog("Localizable", language: "en")
for (key, value) in [
    ("Начать запись", "Start Recording"),
    ("Сбросить и начать", "Reset and Start"),
    ("Замеры Wi-Fi", "Wi-Fi Measurements"),
    ("дБм", "dBm"),
] {
    require(englishUI[key] == value,
            "Missing English UI translation for \(key).")
}

let help = try catalog("Help", language: "en")
require(help["Записать замеры"] == "Record Wi-Fi Measurements", "Missing English help article title.")

let permissions = try catalog("InfoPlist", language: "en")
for permission in ["NSLocationUsageDescription", "NSLocationWhenInUseUsageDescription"] {
    require(permissions[permission]?.contains("access point") == true,
            "Missing English location permission explanation for \(permission).")
}

print("All eleven GUI languages and their expected strings, help, and permission descriptions are bundled.")
