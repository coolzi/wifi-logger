import Foundation
import Testing

@testable import WiFiLogger

@Test(arguments: [
    WiFiReader.Association(state: .connected, ssid: "Second", bssid: "02:00:00:00:00:02",
                           ssidData: Data("Second".utf8)),
    WiFiReader.Association(state: .connected, ssid: "First", bssid: "02:00:00:00:00:02",
                           ssidData: Data("First".utf8)),
    WiFiReader.Association(state: .disconnected),
])
func changingAssociationDiscardsTheMixedSample(endingAt after: WiFiReader.Association) {
    var association = WiFiReader.Association(state: .connected, ssid: "First", bssid: "02:00:00:00:00:01",
                                             ssidData: Data("First".utf8))
    let time = Date(timeIntervalSince1970: 100)
    let sample = WiFiReader.sample(time: time, monotonicTime: 10, readAssociation: { association }) {
        association = after
        return WiFiMeasurements(rssi: -53, noise: -90)
    }

    #expect(sample.state == .unknown)
    #expect(sample.measurements.ssid == nil)
    #expect(sample.measurements.bssid == nil)
    #expect(sample.measurements.rssi == nil)
    #expect(sample.time == time)
    #expect(sample.monotonicTime == 10)
}

@Test(arguments: [
    WiFiReader.Association(state: .connected, ssid: "First", bssid: "02:00:00:00:00:01",
                           ssidData: Data("First".utf8)),
    WiFiReader.Association(state: .connected),
])
func stableAssociationPreservesRadioFields(_ association: WiFiReader.Association) {
    let sample = WiFiReader.sample(time: .now, monotonicTime: 10, readAssociation: { association }) {
        WiFiMeasurements(rssi: -53, noise: -90)
    }
    #expect(sample.state == .connected)
    #expect(sample.measurements.ssid == association.ssid)
    #expect(sample.measurements.bssid == association.bssid)
    #expect(sample.measurements.ssidData == association.ssidData)
    #expect(sample.measurements.rssi == -53)
    #expect(sample.measurements.snrDB == 37)
}
