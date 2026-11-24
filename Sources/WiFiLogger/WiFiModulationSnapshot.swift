import CoreFoundation
import Foundation

enum WiFiModulationType: String, CaseIterable, Sendable {
    case bpsk = "BPSK"
    case qpsk = "QPSK"
    case qam16 = "16-QAM"
    case qam64 = "64-QAM"
    case qam256 = "256-QAM"
    case qam1024 = "1024-QAM"
    case qam4096 = "4096-QAM"

    var bitsPerSymbol: Int {
        switch self {
        case .bpsk: 1
        case .qpsk: 2
        case .qam16: 4
        case .qam64: 6
        case .qam256: 8
        case .qam1024: 10
        case .qam4096: 12
        }
    }
}

struct WiFiSpatialStreamsReading: Sendable {
    let count: Int
    let receivedAt: Date
    let receivedUptime: TimeInterval
}

struct WiFiModulationSnapshot: Identifiable, Sendable {
    let id = UUID()
    let interfaceName: String
    let startedAt: Date
    let finishedAt: Date
    let startedUptime: TimeInterval
    let finishedUptime: TimeInterval
    let phyMode: String?
    let channel: WiFiChannel?
    let mcs: Int?
    let transmitRateMbps: Double?
    var spatialStreams: WiFiSpatialStreamsReading? = nil

    var lastObservationUptime: TimeInterval { spatialStreams?.receivedUptime ?? finishedUptime }

    var modulationType: WiFiModulationType? { scheme?.modulation }
    var modulation: String? { modulationType?.rawValue }
    var coding: String? { scheme?.coding.label }
    var informationBitFraction: Double? { scheme?.coding.informationFraction }

    private enum CodingRate {
        case half, twoThirds, threeQuarters, fiveSixths

        private var bits: (information: Int, coded: Int) {
            switch self {
            case .half: (1, 2)
            case .twoThirds: (2, 3)
            case .threeQuarters: (3, 4)
            case .fiveSixths: (5, 6)
            }
        }

        var label: String {
            let counts = bits
            return "\(counts.information)/\(counts.coded)"
        }

        var informationFraction: Double {
            let counts = bits
            return Double(counts.information) / Double(counts.coded)
        }
    }

    // IEEE 802.11 HT/VHT/HE/EHT MCS tables. HT 0...31 repeats with the number of
    // spatial streams. HT 33...76 can use unequal modulation between streams.
    // EHT 14...15 are special modes outside the ordinary MCS table below.
    private var scheme: (modulation: WiFiModulationType, coding: CodingRate)? {
        guard let mcs, mcs >= 0 else { return nil }
        switch phyMode {
        case "802.11n" where mcs < 32: return Self.schemes[mcs % 8]
        case "802.11n" where mcs == 32: return Self.schemes[0]
        case "802.11ac" where mcs <= 9: return Self.schemes[mcs]
        case "802.11ax" where mcs <= 11: return Self.schemes[mcs]
        case "802.11be" where mcs <= 13: return Self.schemes[mcs]
        default: return nil
        }
    }

    private static let schemes: [(modulation: WiFiModulationType, coding: CodingRate)] = [
        (.bpsk, .half),
        (.qpsk, .half),
        (.qpsk, .threeQuarters),
        (.qam16, .half),
        (.qam16, .threeQuarters),
        (.qam64, .twoThirds),
        (.qam64, .threeQuarters),
        (.qam64, .fiveSixths),
        (.qam256, .threeQuarters),
        (.qam256, .fiveSixths),
        (.qam1024, .threeQuarters),
        (.qam1024, .fiveSixths),
        (.qam4096, .threeQuarters),
        (.qam4096, .fiveSixths),
    ]

    static func parse(_ data: Data, interfaceName: String,
                      startedAt: Date, finishedAt: Date,
                      startedUptime: TimeInterval, finishedUptime: TimeInterval) throws -> Self? {
        let report = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let sections = report?["SPAirPortDataType"] as? [[String: Any]] ?? []
        let interfaces = sections.lazy.flatMap { section in
            section["spairport_airport_interfaces"] as? [[String: Any]] ?? []
        }
        guard let interface = interfaces.first(where: { $0["_name"] as? String == interfaceName }),
              let current = interface["spairport_current_network_information"] as? [String: Any] else {
            return nil
        }

        let phyMode = string(current["spairport_network_phymode"])
        let channel = parseChannel(current["spairport_network_channel"])
        let mcs = number(current["spairport_network_mcs"]).flatMap(UInt8.init(exactly:)).map(Int.init)
        // Reject corrupt rates above 1 Tbit/s before they can distort or overflow the plot.
        let rate = number(current["spairport_network_rate"]).flatMap { (0 < $0 && $0 <= 1_000_000) ? $0 : nil }
        guard phyMode != nil || channel != nil || mcs != nil || rate != nil else { return nil }
        return Self(interfaceName: interfaceName, startedAt: startedAt, finishedAt: finishedAt,
                    startedUptime: startedUptime, finishedUptime: finishedUptime, phyMode: phyMode,
                    channel: channel, mcs: mcs, transmitRateMbps: rate)
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.doubleValue
        }
        return string(value).flatMap(Double.init)
    }

    private static func parseChannel(_ value: Any?) -> WiFiChannel? {
        if let number = number(value).flatMap(Int.init(exactly:)), number > 0 {
            return WiFiChannel(band: nil, number: number, width: nil)
        }
        guard let text = string(value),
              let channelMatch = text.firstMatch(of: #/^([0-9]+)(?:\s|\(|$)/#),
              let channelNumber = Int(channelMatch.1), channelNumber > 0 else { return nil }
        let band: String? = switch text.firstMatch(of: #/(?i)\b(2(?:[.,]4)?|5|6)\s*GHz\b/#)?.1 {
        case "2", "2.4", "2,4": "2,4 ГГц"
        case "5": "5 ГГц"
        case "6": "6 ГГц"
        default: nil
        }
        let width = text.firstMatch(of: #/(?i)\b([0-9]+)\s*MHz\b/#)
            .flatMap { Int($0.1) }.flatMap { $0 > 0 ? $0 : nil }
        return WiFiChannel(band: band, number: channelNumber, width: width)
    }
}
