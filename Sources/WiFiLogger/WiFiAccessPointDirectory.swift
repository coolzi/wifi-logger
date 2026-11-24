import Foundation

enum WiFiAccessPointCSVError: LocalizedError, Equatable {
    case encoding, header, empty
    case row(line: Int), invalidName(line: Int), invalidBSSID(line: Int), conflictingName(line: Int)

    var errorDescription: String? {
        switch self {
        case .encoding: String(localized: "Сохраните CSV в кодировке UTF-8.")
        case .header: String(localized: "В первой строке должны быть заголовки bssid,ap_name.")
        case .empty: String(localized: "Добавьте в CSV хотя бы один BSSID и имя точки.")
        case .row(let line): String(localized: "Строка \(line). Укажите BSSID и имя точки в двух полях CSV.")
        case .invalidName(let line): String(localized: "Строка \(line). Укажите непустое имя точки без управляющих символов.")
        case .invalidBSSID(let line): String(localized: "Строка \(line). Проверьте BSSID, например 02:11:22:33:44:a1.")
        case .conflictingName(let line): String(localized: "Строка \(line). У этого BSSID уже указано другое имя.")
        }
    }
}

struct WiFiAccessPointDirectory: Sendable {
    struct ReplacementChanges: Equatable, Sendable {
        let added: Int
        let removed: Int
        let renamed: Int
    }

    private let csv: Data
    private let names: [String: String]

    var bssidCount: Int { names.count }
    var nameCount: Int { Set(names.values).count }

    static var applicationFile: URL {
        URL.applicationSupportDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "local.wifi-logger.gui", directoryHint: .isDirectory)
            .appending(path: "access-points.csv", directoryHint: .notDirectory)
    }

    init(csv: Data) throws {
        guard var text = String(data: csv, encoding: .utf8) else { throw WiFiAccessPointCSVError.encoding }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let first = lines.first, let (key, value) = Self.fields(in: first),
              key == "bssid", value == "ap_name" else { throw WiFiAccessPointCSVError.header }

        var names: [String: String] = [:]
        for (offset, line) in lines.enumerated().dropFirst() {
            let number = offset + 1
            if line.allSatisfy(\.isWhitespace) { continue }
            guard let (address, name) = Self.fields(in: line) else {
                throw WiFiAccessPointCSVError.row(line: number)
            }
            guard let bssid = Self.normalizedBSSID(address) else {
                throw WiFiAccessPointCSVError.invalidBSSID(line: number)
            }
            guard !name.isEmpty, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw WiFiAccessPointCSVError.invalidName(line: number)
            }
            if let previous = names[bssid], previous != name {
                throw WiFiAccessPointCSVError.conflictingName(line: number)
            }
            names[bssid] = name
        }
        guard !names.isEmpty else { throw WiFiAccessPointCSVError.empty }
        self.names = names
        self.csv = csv
    }

    func name(for bssid: String?) -> String? {
        guard let bssid, let key = Self.normalizedBSSID(bssid) else { return nil }
        return names[key]
    }

    func changes(from previous: Self) -> ReplacementChanges {
        var sharedCount = 0
        var renamedCount = 0
        for (bssid, name) in names {
            guard let previousName = previous.names[bssid] else { continue }
            sharedCount += 1
            if name != previousName { renamedCount += 1 }
        }
        return ReplacementChanges(added: names.count - sharedCount, removed: previous.names.count - sharedCount,
                                  renamed: renamedCount)
    }

    static func load(from url: URL) throws -> Self? {
        do {
            return try Self(csv: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try csv.write(to: url, options: .atomic)
    }

    private static func fields(in line: Substring) -> (String, String)? {
        let pattern = #/("(?:[^"]|"")*"|[^",]*),("(?:[^"]|"")*"|[^",]*)/#
        guard let (_, first, second) = line.wholeMatch(of: pattern)?.output else { return nil }
        return (fieldValue(first), fieldValue(second))
    }

    private static func fieldValue(_ field: Substring) -> String {
        let value = field.first == "\""
            ? field.dropFirst().dropLast().replacingOccurrences(of: "\"\"", with: "\"")
            : String(field)
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func normalizedBSSID(_ address: String) -> String? {
        let address = address.trimmingCharacters(in: .whitespaces).lowercased()
        if address.wholeMatch(of: #/(?:[0-9a-f]{2}:){5}[0-9a-f]{2}/#) != nil { return address }
        guard address.wholeMatch(of: #/(?:[0-9a-f]{4}-){2}[0-9a-f]{4}/#) != nil else { return nil }
        return address.split(separator: "-").flatMap { [$0.prefix(2), $0.suffix(2)] }.joined(separator: ":")
    }
}
