import Foundation
import Testing

@testable import WiFiLogger

@Test func generationLabelsMatchTheNegotiatedModeAndBand() {
    let cases: [(String?, String?, String?)] = [
        ("802.11n", "2,4 ГГц", "Wi-Fi 4"),
        ("802.11ac", "5 ГГц", "Wi-Fi 5"),
        ("802.11ax", "2,4 ГГц", "Wi-Fi 6"),
        ("802.11ax", "5 ГГц", "Wi-Fi 6"),
        ("802.11ax", "6 ГГц", "Wi-Fi 6E"),
        ("802.11ax", nil, "Wi-Fi 6"),
        ("802.11be", "6 ГГц", "Wi-Fi 7"),
        ("802.11be", "5 ГГц", "Wi-Fi 7"),
        ("802.11a", "5 ГГц", "Wi-Fi (a)"),
        ("802.11b", "2,4 ГГц", "Wi-Fi (b)"),
        ("802.11g", "2,4 ГГц", "Wi-Fi (g)"),
        ("future mode", nil, "future mode"), (nil, nil, nil),
    ]
    for (mode, band, label) in cases {
        let fields = WiFiMeasurements(channel: WiFiChannel(band: band, number: 1, width: 20), phyMode: mode)
        #expect(fields.wifiGenerationLabel == label)
        #expect(fields.phyMode == mode)
    }
}

@Test func linkStateUsesPowerAndAssociation() {
    #expect(WiFiState(powerOn: true, linkActive: true, stationMode: false) == .connected)
    #expect(WiFiState(powerOn: true, linkActive: false, stationMode: true) == .disconnected)
    #expect(WiFiState(powerOn: false, linkActive: false, stationMode: false) == .poweredOff)
    #expect(WiFiState(powerOn: false, linkActive: true, stationMode: true) == .unknown)
    #expect(WiFiState(powerOn: false, linkActive: nil, stationMode: false) == .unknown)
    #expect(WiFiState(powerOn: true, linkActive: nil, stationMode: true) == .connected)
    #expect(WiFiState(powerOn: true, linkActive: nil, stationMode: false) == .unknown)
}

@Test func sampleContainsExpectedFieldsAndUnits() {
    let sample = WiFiSample(
        time: Date(timeIntervalSince1970: 0), monotonicTime: 0,
        state: .connected,
        measurements: WiFiMeasurements(
            ssid: "Home", bssid: "02:00:00:00:00:01", rssi: -61, noise: -95,
            channel: WiFiChannel(band: "5 ГГц", number: 36, width: 80),
            phyMode: "802.11ac", transmitRate: 866
        )
    )

    #expect(sample.line(timestamp: "2026-11-17T12:00:01+03:00") ==
        "2026-11-17T12:00:01+03:00 | подключено | SSID=Home | BSSID=02:00:00:00:00:01 | RSSI=-61 дБм | шум=-95 дБм | SNR=34 дБ | 5 ГГц, канал 36, 80 МГц | 802.11ac | TX=866 Мбит/с")
}

@Test func connectionWithoutIdentifiersStillKeepsAvailableMeasurements() {
    let sample = WiFiSample(
        time: Date(timeIntervalSince1970: 0), monotonicTime: 0,
        state: .connected,
        measurements: WiFiMeasurements(rssi: -61, noise: 0, transmitRate: 0)
    )

    #expect(sample.line(timestamp: "t") ==
        "t | подключено | SSID=— | BSSID=— | RSSI=-61 дБм | шум=— | SNR=— | — | — | TX=—")
}

@Test func disconnectedSampleOmitsStaleMeasurements() {
    let sample = WiFiSample(
        time: Date(timeIntervalSince1970: 0), monotonicTime: 0,
        state: .disconnected,
        measurements: WiFiMeasurements(ssid: "Home", rssi: -61, noise: -95)
    )

    #expect(sample.line(timestamp: "t") ==
        "t | нет подключения | SSID=— | BSSID=— | RSSI=— | шум=— | SNR=— | — | — | TX=—")
}

@Test func networkNameStaysOnOneLineWithoutTerminalControls() {
    let sample = WiFiSample(
        time: Date(timeIntervalSince1970: 0), monotonicTime: 0,
        state: .connected,
        measurements: WiFiMeasurements(ssid: "Сеть\n\u{1B}[31m\u{2028} | \\")
    )

    #expect(sample.line(timestamp: "t").contains(#"SSID=Сеть\u{A}\u{1B}[31m\u{2028} \u{7C} \\ | BSSID="#))
}
