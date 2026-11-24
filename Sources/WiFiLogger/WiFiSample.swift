import Foundation

enum WiFiState: String, Sendable {
    case connected = "подключено"
    case disconnected = "нет подключения"
    case poweredOff = "Wi-Fi выключен"
    case unknown = "состояние неизвестно"

    var displayName: String {
        switch self {
        case .connected: String(localized: "подключено")
        case .disconnected: String(localized: "нет подключения")
        case .poweredOff: String(localized: "Wi-Fi выключен")
        case .unknown: String(localized: "состояние неизвестно")
        }
    }

    init(powerOn: Bool, linkActive: Bool?, stationMode: Bool) {
        switch (powerOn, linkActive) {
        case (true, true): self = .connected
        case (true, false): self = .disconnected
        case (false, false) where !stationMode: self = .poweredOff
        case (true, nil) where stationMode: self = .connected
        default: self = .unknown
        }
    }
}

struct WiFiChannel: Sendable {
    let band: String?
    let number: Int?
    let width: Int?

    var label: String {
        [band, number.map { "канал \($0)" }, width.map { "\($0) МГц" }]
            .map { $0 ?? "—" }
            .joined(separator: ", ")
    }

    var chartLabel: String? {
        guard let number, number > 0 else { return nil }
        return [String(number), band, width.map { "\($0) МГц" }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var displayChartLabel: String? {
        guard let number, number > 0 else { return nil }
        return [String(number), displayBand, displayWidth]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var displayLabel: String {
        displayChartLabel ?? [displayBand, number.map { String(localized: "канал \($0)") }, displayWidth]
            .map { $0 ?? "—" }
            .joined(separator: ", ")
    }

    private var displayBand: String? {
        let frequency: Double
        switch band {
        case "2,4 ГГц": frequency = 2.4
        case "5 ГГц": frequency = 5
        case "6 ГГц": frequency = 6
        default: return band
        }
        return String(localized: "\(frequency.formatted(.number.locale(WiFiInterfaceLocale.current))) ГГц")
    }

    private var displayWidth: String? {
        width.map { String(localized: "\($0) МГц") }
    }

    func hasChanged(from previous: WiFiChannel) -> Bool {
        guard let number, let oldNumber = previous.number, number > 0, oldNumber > 0 else {
            return false
        }
        if number != oldNumber { return true }
        if let band, let oldBand = previous.band, band != oldBand { return true }
        if let width, let oldWidth = previous.width, width > 0, oldWidth > 0, width != oldWidth {
            return true
        }
        return false
    }
}

struct WiFiMeasurements: Sendable {
    var ssid: String?
    var bssid: String?
    var rssi: Int?
    var noise: Int?
    var channel: WiFiChannel?
    var phyMode: String?
    var transmitRate: Double?
    var ssidData: Data?

    var signalDBm: Int? { rssi.flatMap { $0 == 0 ? nil : $0 } }
    var noiseDBm: Int? { noise.flatMap { $0 == 0 ? nil : $0 } }
    var snrDB: Int? { signalDBm.flatMap { signal in noiseDBm.map { signal - $0 } } }

    var wifiGenerationLabel: String? {
        switch phyMode {
        case "802.11n": "Wi-Fi 4"
        case "802.11ac": "Wi-Fi 5"
        case "802.11ax": channel?.band == "6 ГГц" ? "Wi-Fi 6E" : "Wi-Fi 6"
        case "802.11be": "Wi-Fi 7"
        case "802.11a": "Wi-Fi (a)"
        case "802.11b": "Wi-Fi (b)"
        case "802.11g": "Wi-Fi (g)"
        default: phyMode
        }
    }

    var transmitRateMbps: Double? {
        guard let transmitRate, transmitRate.isFinite, transmitRate > 0 else { return nil }
        return transmitRate
    }

    var transmitRateLabel: String? {
        guard let transmitRate = transmitRateMbps else { return nil }
        let format = FloatingPointFormatStyle<Double>.number
            .locale(Locale(identifier: "en_US_POSIX"))
            .precision(.fractionLength(0...1))
            .grouping(.never)
        return "\(transmitRate.formatted(format)) Мбит/с"
    }

    var displayTransmitRate: String? {
        transmitRateMbps.map {
            String(localized: "\($0.formatted(.number.precision(.fractionLength(0...1)).grouping(.never))) Мбит/с")
        }
    }
}

struct WiFiSample: Sendable {
    let time: Date
    let monotonicTime: TimeInterval
    let state: WiFiState
    let measurements: WiFiMeasurements

    var connectedMeasurements: WiFiMeasurements {
        state == .connected ? measurements : WiFiMeasurements()
    }

    func line(timestamp: String) -> String {
        let fields = connectedMeasurements
        return [
            timestamp,
            state.rawValue,
            "SSID=\(fields.ssid.map(Self.escapeNetworkName) ?? "—")",
            "BSSID=\(fields.bssid ?? "—")",
            "RSSI=\(fields.signalDBm.map { "\($0) дБм" } ?? "—")",
            "шум=\(fields.noiseDBm.map { "\($0) дБм" } ?? "—")",
            "SNR=\(fields.snrDB.map { "\($0) дБ" } ?? "—")",
            fields.channel?.label ?? "—",
            fields.phyMode ?? "—",
            "TX=\(fields.transmitRateLabel ?? "—")",
        ].joined(separator: " | ")
    }

    private static func escapeNetworkName(_ name: String) -> String {
        name.unicodeScalars.map { scalar in
            if scalar == "\\" { return "\\\\" }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                return "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            default:
                return scalar == "|" ? "\\u{7C}" : String(scalar)
            }
        }.joined()
    }
}

enum WiFiMonotonicClock {
    private static let origin = ContinuousClock.now

    static var now: TimeInterval {
        let elapsed = origin.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
}
