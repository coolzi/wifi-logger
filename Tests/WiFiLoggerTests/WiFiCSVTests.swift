import Foundation
import Testing

@testable import WiFiLogger

@Test func csvSessionPersistsShortPauseBoundariesAndElapsedTime() {
    var session = WiFiSession()
    session.append(csvReading(0))
    session.append(csvReading(1, state: .disconnected))
    session.append(csvReading(2, state: .disconnected), startsSegment: true)
    session.append(csvReading(3))

    let rows = String(decoding: WiFiCSV.encode(session, timeZone: .gmt), as: UTF8.self)
        .components(separatedBy: "\r\n").dropLast().map { $0.components(separatedBy: ",") }
    #expect(Array(rows[0].suffix(3)) == ["segment_id", "monotonic_seconds", "calculation_version"])
    #expect(rows.allSatisfy { $0.count == 28 })
    #expect(rows.dropFirst().map { Array($0.suffix(3)) } == [
        ["0", "0.0", "1"], ["0", "1.0", "1"], ["1", "2.0", "1"], ["1", "3.0", "1"],
    ])
    #expect(rows.dropFirst().allSatisfy { Array($0.dropFirst(16).prefix(3)) == ["1", "1.0", "1.0"] })
}

@Test func csvSessionCanReplayPausesClockChangesAndDerivedData() throws {
    var session = WiFiSession()
    session.append(csvReading(100, wallTime: 1000))
    session.append(csvReading(101, wallTime: 1001, state: .disconnected))
    session.append(csvReading(102, wallTime: 1301, state: .disconnected), startsSegment: true)
    session.append(csvReading(103, wallTime: 1302))
    session.append(csvReading(104, wallTime: 1303, number: 44, bssid: "second"))
    session.append(csvReading(105, wallTime: 1003, number: 44, bssid: "second"))
    session.append(csvReading(108, wallTime: 1006, state: .disconnected))
    session.append(csvReading(109, wallTime: 1007, state: .unknown))
    session.append(csvReading(110, wallTime: 1008))
    session.append(csvReading(171, wallTime: 1069, rssi: -70))
    let data = WiFiCSV.encode(session, timeZone: .gmt)
    let rows = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
        .dropFirst().dropLast().map { $0.components(separatedBy: ",") }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var replay = WiFiSession()
    var previousSegment: String?
    for row in rows {
        let time = try #require(formatter.date(from: row[0]))
        let state = try #require(WiFiState(rawValue: row[1]))
        let monotonicTime = try #require(Double(row[26]))
        func text(_ index: Int) -> String? { row[index].isEmpty ? nil : row[index] }
        // Fixture SSIDs are literal UTF-8. CSV stores only the displayed name.
        let fields = WiFiMeasurements(ssid: text(2), bssid: text(3), rssi: Int(row[4]), noise: Int(row[5]),
            channel: Int(row[8]).map { WiFiChannel(band: text(7), number: $0, width: Int(row[9])) },
            phyMode: text(10), transmitRate: Double(row[11]), ssidData: text(2).map { Data($0.utf8) })
        replay.append(WiFiSample(time: time, monotonicTime: monotonicTime, state: state, measurements: fields),
                      startsSegment: previousSegment != nil && previousSegment != row[25])
        previousSegment = row[25]
    }
    #expect(replay.outages.count == session.outages.count)
    #expect(replay.outages.totalDuration == session.outages.totalDuration)
    #expect(replay.outages.longestDuration == session.outages.longestDuration)
    #expect(replay.events.map(\.id) == session.events.map(\.id))
    #expect(replay.events.map(\.duration) == session.events.map(\.duration))
    for trend in WiFiTrend.allCases {
        #expect(replay.points(for: trend).map(\.segment) == session.points(for: trend).map(\.segment))
        #expect(replay.points(for: trend).map(\.value) == session.points(for: trend).map(\.value))
    }
    #expect(WiFiCSV.encode(replay, timeZone: .gmt) == data)
}

@Test func csvSessionKeepsExactMonotonicBoundariesForReplay() throws {
    let histories: [([Double], [WiFiState], [Int])] = [
        ([0.1, 3, 5.5], [.connected, .disconnected, .connected], [-60, -60, -60]),
        ([0.1, 5, 65], [.connected, .connected, .connected], [-60, -100, -60]),
    ]
    for (times, states, signals) in histories {
        var session = WiFiSession()
        for index in times.indices {
            session.append(WiFiSample(time: Date(timeIntervalSince1970: 1000 + Double(index)),
                monotonicTime: times[index], state: states[index],
                measurements: WiFiMeasurements(rssi: signals[index], noise: -110)))
        }
        let rows = String(decoding: WiFiCSV.encode(session, timeZone: .gmt), as: UTF8.self)
            .components(separatedBy: "\r\n").dropFirst().dropLast().map { $0.components(separatedBy: ",") }
        var replay = WiFiSession()
        var previousSegment: String?
        for (index, row) in rows.enumerated() {
            let monotonicTime = try #require(Double(row[26]))
            #expect(monotonicTime == times[index])
            replay.append(WiFiSample(time: Date(timeIntervalSince1970: 1000 + Double(index)),
                monotonicTime: monotonicTime, state: try #require(WiFiState(rawValue: row[1])),
                measurements: WiFiMeasurements(rssi: Int(row[4]), noise: Int(row[5]))),
                startsSegment: previousSegment != nil && previousSegment != row[25])
            previousSegment = row[25]
        }
        #expect(replay.segmentIDs == session.segmentIDs)
        #expect(replay.outages.totalDuration == session.outages.totalDuration)
        #expect(replay.rssiVariation.minimum == session.rssiVariation.minimum)
        #expect(replay.events.map(\.id) == session.events.map(\.id))
    }
}

@Test func csvExportsCompleteSessionInRecordingOrder() {
    let measurements = WiFiMeasurements(
        ssid: "Сеть", bssid: "02:00:00:00:00:01", rssi: -61, noise: -94,
        channel: WiFiChannel(band: "5 ГГц", number: 149, width: 80), phyMode: "802.11ax", transmitRate: 432.5
    )
    let samples = [
        WiFiSample(time: Date(timeIntervalSince1970: 1.25), monotonicTime: 1.25, state: .connected, measurements: measurements),
        WiFiSample(time: Date(timeIntervalSince1970: 2), monotonicTime: 2, state: .disconnected, measurements: measurements),
        WiFiSample(time: Date(timeIntervalSince1970: 1), monotonicTime: 1, state: .connected,
                   measurements: WiFiMeasurements(rssi: 0, noise: -94, transmitRate: .infinity)),
    ]

    let csv = String(decoding: WiFiCSV.encode(samples, timeZone: .gmt), as: UTF8.self)
    #expect(csv == [
        "timestamp,state,ssid,bssid,rssi_dbm,noise_dbm,snr_db,band,channel,channel_width_mhz,phy_mode,tx_rate_mbps",
        "1970-01-01T00:00:01.250Z,подключено,Сеть,02:00:00:00:00:01,-61,-94,33,5 ГГц,149,80,802.11ax,432.5",
        "1970-01-01T00:00:02.000Z,нет подключения,,,,,,,,,,",
        "1970-01-01T00:00:01.000Z,подключено,,,,-94,,,,,,",
        "",
    ].joined(separator: "\r\n"))
}

@Test func csvQuotesTextAndTreatsSpreadsheetFormulaPrefixesAsLiteralText() {
    let measurements = WiFiMeasurements(
        ssid: "Кафе, \"верх\"\r\nэтаж",
        channel: WiFiChannel(band: "2,4 ГГц", number: 6, width: 20)
    )
    let sample = WiFiSample(time: Date(timeIntervalSince1970: 0), monotonicTime: 0, state: .connected, measurements: measurements)
    let formulaName = WiFiSample(time: sample.time, monotonicTime: 0, state: .connected, measurements: WiFiMeasurements(ssid: "  =сеть"))
    let csv = String(decoding: WiFiCSV.encode([sample, formulaName], timeZone: .gmt), as: UTF8.self)

    #expect(csv.contains("подключено,\"Кафе, \"\"верх\"\"\r\nэтаж\",,,,,\"2,4 ГГц\",6,20,,\r\n"))
    #expect(csv.contains("подключено,'  =сеть,,,,,,,,,\r\n"))
}

@Test func csvRecognizesDelimitersAndFormulaPrefixesInsideGraphemeClusters() {
    let names = ["Home,\u{0301}cafe", "Home,\"\u{0301}cafe", "=\u{0301}сеть"]
    let samples = names.map { name in
        WiFiSample(time: Date(timeIntervalSince1970: 0), monotonicTime: 0, state: .connected, measurements: WiFiMeasurements(ssid: name))
    }
    let csv = String(decoding: WiFiCSV.encode(samples, timeZone: .gmt), as: UTF8.self)

    #expect(csv.contains("подключено,\"Home,\u{0301}cafe\",,,,,,,,,\r\n"))
    #expect(csv.contains("подключено,\"Home,\"\"\u{0301}cafe\",,,,,,,,,\r\n"))
    #expect(csv.contains("подключено,'=\u{0301}сеть,,,,,,,,,\r\n"))
}

@Test func csvSessionExportsOutageTotalsAndChannelTransitionsOnTheirSamples() {
    var session = WiFiSession()
    session.append(csvReading(0))
    session.append(csvReading(1, state: .disconnected))
    session.append(csvReading(2, state: .disconnected))
    session.append(csvReading(3))
    session.append(csvReading(4, band: "6 ГГц", bssid: "second"))
    session.append(csvReading(5, band: "6 ГГц", number: 40, bssid: "second"))
    session.append(csvReading(6, band: "6 ГГц", number: 40, width: 160, bssid: "second"))
    session.append(csvReading(7, state: .disconnected))
    session.append(csvReading(8.25, state: .disconnected))

    let csv = String(decoding: WiFiCSV.encode(session, timeZone: .gmt), as: UTF8.self)
    let rows = csv.components(separatedBy: "\r\n").dropLast().map { $0.components(separatedBy: ",") }
    #expect(rows.count == 10)
    #expect(rows.allSatisfy { $0.count == 28 })
    #expect(Array(rows[0].dropFirst(12).prefix(7)) == [
        "channel_changed", "previous_band", "previous_channel", "previous_channel_width_mhz",
        "session_outage_count", "session_outage_total_seconds", "session_outage_longest_seconds",
    ])
    #expect(rows.dropFirst().allSatisfy { Array($0.dropFirst(16).prefix(3)) == ["2", "3.25", "2.0"] })
    #expect(rows.dropFirst().map { Array($0.dropFirst(12).prefix(4)) } == [
        ["0", "", "", ""], ["0", "", "", ""], ["0", "", "", ""], ["0", "", "", ""],
        ["1", "5 ГГц", "36", "80"], ["1", "6 ГГц", "36", "80"], ["1", "6 ГГц", "40", "80"],
        ["0", "", "", ""], ["0", "", "", ""],
    ])
    let originalRows = String(decoding: WiFiCSV.encode(session.samples, timeZone: .gmt), as: UTF8.self)
        .components(separatedBy: "\r\n").dropLast()
    #expect(zip(rows, originalRows).allSatisfy { $0.prefix(12).joined(separator: ",") == $1 })
    #expect(rows[5][0] == "1970-01-01T00:00:04.000Z")
    #expect(Array(rows[5][7 ... 9]) == ["6 ГГц", "36", "80"])
}

@Test func csvSessionUsesRecordedPausesAndAnImmutableSnapshot() {
    var session = WiFiSession()
    session.append(csvReading(0))
    session.append(csvReading(1, number: 44), startsSegment: true)
    session.append(csvReading(2, number: 48))
    session.append(csvReading(3, state: .disconnected))
    session.append(csvReading(4, state: .disconnected))
    session.append(csvReading(4.5, state: .disconnected), startsSegment: true)
    session.append(csvReading(5))
    let snapshot = session
    session.append(csvReading(6, state: .disconnected))
    session.append(csvReading(7))

    let rows = String(decoding: WiFiCSV.encode(snapshot, timeZone: .gmt), as: UTF8.self)
        .components(separatedBy: "\r\n").dropFirst().dropLast().map { $0.components(separatedBy: ",") }
    #expect(rows.count == 7)
    #expect(rows.allSatisfy { Array($0.dropFirst(16).prefix(3)) == ["1", "1.5", "1.0"] })
    #expect(Array(rows[1].dropFirst(12).prefix(4)) == ["0", "", "", ""])
    #expect(Array(rows[2].dropFirst(12).prefix(4)) == ["1", "5 ГГц", "44", "80"])
}

@Test func csvSessionExportsAnEmptyHeaderAndZeroSummary() {
    var session = WiFiSession()
    let empty = String(decoding: WiFiCSV.encode(session, timeZone: .gmt), as: UTF8.self)
    #expect(empty.components(separatedBy: "\r\n").count == 2)
    #expect(empty.hasSuffix("segment_id,monotonic_seconds,calculation_version\r\n"))

    session.append(csvReading(0))
    let csv = String(decoding: WiFiCSV.encode(session, timeZone: .gmt), as: UTF8.self)
    #expect(csv.hasSuffix(",0,,,,0,0.0,0.0,-60,-60,,32,32,,0,0.0,1\r\n"))
}

@Test func csvSessionEscapesPreviousChannelFieldsAndNetworkNames() {
    var session = WiFiSession()
    let sample = WiFiSample(time: Date(timeIntervalSince1970: 0), monotonicTime: 0, state: .connected,
        measurements: WiFiMeasurements(ssid: "Кафе, \"верх\"\r\nэтаж",
            channel: WiFiChannel(band: "2,4 ГГц", number: 6, width: 20)))
    session.append(sample)
    session.append(csvReading(1, ssid: "=сеть"))

    let csv = String(decoding: WiFiCSV.encode(session, timeZone: .gmt), as: UTF8.self)
    #expect(csv.contains("подключено,\"Кафе, \"\"верх\"\"\r\nэтаж\""))
    #expect(csv.contains("подключено,'=сеть,"))
    #expect(csv.hasSuffix(",1,\"2,4 ГГц\",6,20,0,0.0,0.0,-60,-60,,32,32,,0,1.0,1\r\n"))
}

@Test func csvSessionExportsMinuteVariationsFromTheConfirmedSnapshot() {
    var session = WiFiSession()
    session.append(csvReading(0, rssi: -100, noise: -110))
    session.append(csvReading(1, rssi: -80, noise: -100))
    session.append(csvReading(30, rssi: -70, noise: 0))
    session.append(csvReading(59, state: .disconnected, rssi: -120, noise: -121))
    session.append(csvReading(60, rssi: -65, noise: -95))
    session.append(csvReading(61, rssi: -60, noise: -92))
    let snapshot = session
    session.append(csvReading(62, rssi: -20, noise: -90))

    let rows = String(decoding: WiFiCSV.encode(snapshot, timeZone: .gmt), as: UTF8.self)
        .components(separatedBy: "\r\n").dropLast().map { $0.components(separatedBy: ",") }
    #expect(rows.count == 7)
    #expect(rows.allSatisfy { $0.count == 28 })
    #expect(Array(rows[0].dropFirst(19).prefix(6)) == [
        "rssi_min_60s_dbm", "rssi_max_60s_dbm", "rssi_spread_60s_db",
        "snr_min_60s_db", "snr_max_60s_db", "snr_spread_60s_db",
    ])
    #expect(rows.dropFirst().allSatisfy { Array($0.dropFirst(19).prefix(6)) == ["-80", "-60", "20", "20", "32", "12"] })
}

@Test func csvSessionDistinguishesMissingAndZeroVariation() {
    var session = WiFiSession()
    session.append(csvReading(0, rssi: 0, noise: 0))
    #expect(csvVariationFields(session) == ["", "", "", "", "", ""])
    session.append(csvReading(1, rssi: -60, noise: 0))
    #expect(csvVariationFields(session) == ["-60", "-60", "", "", "", ""])
    session.append(csvReading(2, rssi: nil, noise: -92))
    #expect(csvVariationFields(session) == ["-60", "-60", "", "", "", ""])
    session.append(csvReading(3))
    #expect(csvVariationFields(session) == ["-60", "-60", "0", "32", "32", ""])
    session.append(csvReading(4))
    #expect(csvVariationFields(session) == ["-60", "-60", "0", "32", "32", "0"])
    session.append(csvReading(65, state: .disconnected, rssi: -120, noise: -121))
    #expect(csvVariationFields(session) == ["", "", "", "", "", ""])
}

private func csvVariationFields(_ session: WiFiSession) -> [String] {
    let rows = String(decoding: WiFiCSV.encode(session, timeZone: .gmt), as: UTF8.self)
        .components(separatedBy: "\r\n").dropLast()
    return Array((rows.last ?? "").components(separatedBy: ",").dropFirst(19).prefix(6))
}

private func csvReading(_ seconds: TimeInterval, wallTime: TimeInterval? = nil, state: WiFiState = .connected,
                        band: String = "5 ГГц", number: Int = 36, width: Int = 80,
                        ssid: String = "Home", bssid: String = "first",
                        rssi: Int? = -60, noise: Int? = -92) -> WiFiSample {
    WiFiSample(time: Date(timeIntervalSince1970: wallTime ?? seconds), monotonicTime: seconds, state: state,
               measurements: WiFiMeasurements(ssid: ssid, bssid: bssid, rssi: rssi, noise: noise,
                   channel: WiFiChannel(band: band, number: number, width: width), ssidData: Data(ssid.utf8)))
}
