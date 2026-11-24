import Foundation
import Testing

@testable import WiFiLogger

@Test func outageDurationsUseMonotonicTimeAcrossCalendarCorrections() {
    let histories: [[TimeInterval]] = [[0, 1, 3, 4], [0, 1, 0.5, 1.5], [0, 1, 301, 302], [0, 1, -299, -298]]
    for times in histories {
        var session = WiFiSession()
        for index in times.indices {
            session.append(stabilityReading(Double(index), wallTime: times[index],
                state: index == 1 || index == 2 ? .disconnected : .connected))
        }
        #expect(session.outages.count == 1)
        #expect(session.outages.totalDuration == 2)
        #expect(session.outages.longestDuration == 2)
        #expect(session.events.first(where: { $0.kind == .reconnected })?.duration == 2)
    }
}

@Test func minuteWindowUsesElapsedTimeAndItsInclusiveBoundaryAcrossClockChanges() {
    var session = WiFiSession()
    session.append(stabilityReading(0, wallTime: 100, rssi: -110))
    session.append(stabilityReading(1, wallTime: 101, rssi: -80, noise: -100))
    session.append(stabilityReading(60, wallTime: -100, rssi: -70, noise: -95))
    session.append(stabilityReading(61, wallTime: -99, rssi: -60, noise: -92))
    #expect(session.rssiVariation.minimum == -80)
    #expect(session.rssiVariation.maximum == -60)
    #expect(session.snrVariation.minimum == 20)
    #expect(session.snrVariation.maximum == 32)
    session.append(stabilityReading(61.125, wallTime: 500, rssi: -60, noise: -92))
    #expect(session.rssiVariation.minimum == -70)
    #expect(session.rssiVariation.spread == 10)
    #expect(session.rssiVariation.change == 0)
    #expect(session.snrVariation.minimum == 25)
}

@Test func minuteWindowRetainsAllValuesAtHigherSamplingRates() {
    var session = WiFiSession()
    for index in 0 ... 1000 {
        session.append(stabilityReading(Double(index) / 10, rssi: index == 400 ? -100 : -60))
    }
    #expect(session.rssiVariation.minimum == -100)
    #expect(session.rssiVariation.maximum == -60)
    session.append(stabilityReading(100.125))
    #expect(session.rssiVariation.minimum == -60)
    #expect(session.rssiVariation.spread == 0)
}

@Test func minuteWindowResetsForNonIncreasingInjectedMonotonicTime() {
    var session = WiFiSession()
    session.append(stabilityReading(0, rssi: -100))
    session.append(stabilityReading(61, rssi: -60))
    session.append(stabilityReading(1, rssi: -70))
    #expect(session.rssiVariation.minimum == -70)
    #expect(session.rssiVariation.maximum == -70)
    #expect(session.rssiVariation.spread == nil)
    session.append(stabilityReading(1, rssi: -65))
    #expect(session.rssiVariation.minimum == -65)
    #expect(session.rssiVariation.spread == nil)
}

@Test func outageSummaryIncludesCompletedAndOngoingPeriods() {
    var session = WiFiSession()
    #expect(session.outages.count == 0)
    #expect(session.outages.totalDuration == 0)
    #expect(session.outages.longestDuration == 0)

    session.append(stabilityReading(0))
    session.append(stabilityReading(1, state: .disconnected))
    session.append(stabilityReading(2, state: .disconnected))
    session.append(stabilityReading(3, state: .poweredOff))
    session.append(stabilityReading(4))
    session.append(stabilityReading(5, state: .disconnected))
    session.append(stabilityReading(6, state: .disconnected))
    session.append(stabilityReading(7, state: .disconnected))

    #expect(session.outages.count == 2)
    #expect(session.outages.totalDuration == 5)
    #expect(session.outages.longestDuration == 3)
    session.append(stabilityReading(8))
    #expect(session.outages.count == 2)
    #expect(session.outages.totalDuration == 6)
    #expect(session.outages.longestDuration == 3)
}

@Test func outageSummaryExcludesPausesUnknownStatesAndInvalidMonotonicIntervals() {
    var session = WiFiSession()
    session.append(stabilityReading(0, state: .disconnected))
    session.append(stabilityReading(1, state: .disconnected))
    session.append(stabilityReading(2))
    #expect(session.outages.count == 0)
    #expect(session.outages.totalDuration == 2)

    session.append(stabilityReading(3))
    session.append(stabilityReading(4, state: .disconnected))
    session.append(stabilityReading(5, state: .disconnected))
    session.append(stabilityReading(6, state: .disconnected), startsSegment: true)
    session.append(stabilityReading(7, state: .disconnected))
    session.append(stabilityReading(8, state: .unknown))
    session.append(stabilityReading(9, state: .disconnected))
    session.append(stabilityReading(10, state: .disconnected))
    session.append(stabilityReading(70))
    session.append(stabilityReading(71))
    session.append(stabilityReading(72, state: .disconnected))
    session.append(stabilityReading(73, state: .disconnected))
    session.append(stabilityReading(72, state: .disconnected))
    session.append(stabilityReading(73, state: .disconnected))
    session.append(stabilityReading(73, state: .disconnected))

    #expect(session.outages.count == 2)
    #expect(session.outages.totalDuration == 7)
    #expect(session.outages.longestDuration == 2)
}

@Test func signalVariationsHandleEmptyAndSingleValueWindows() {
    var session = WiFiSession()
    #expect(session.rssiVariation.minimum == nil)
    #expect(session.snrVariation.maximum == nil)
    #expect(session.rssiVariation.spread == nil)
    #expect(session.snrVariation.change == nil)
    session.append(stabilityReading(0))
    #expect(session.rssiVariation.minimum == -60)
    #expect(session.rssiVariation.maximum == -60)
    #expect(session.rssiVariation.spread == nil)
    #expect(session.snrVariation.minimum == 32)
    #expect(session.snrVariation.change == nil)
}

@Test func signalVariationsUseAnInclusiveMinuteAndAvailableConnectedValues() {
    var session = WiFiSession()
    session.append(stabilityReading(0, rssi: -100, noise: -110))
    session.append(stabilityReading(1, rssi: -80, noise: -100))
    session.append(stabilityReading(30, rssi: -70, noise: 0))
    session.append(stabilityReading(59, state: .disconnected, rssi: -120, noise: -121))
    session.append(stabilityReading(60, rssi: -65, noise: -95))
    session.append(stabilityReading(61, rssi: -60, noise: -92))

    #expect(session.rssiVariation.minimum == -80)
    #expect(session.rssiVariation.maximum == -60)
    #expect(session.rssiVariation.spread == 20)
    #expect(session.rssiVariation.change == 5)
    #expect(session.snrVariation.minimum == 20)
    #expect(session.snrVariation.maximum == 32)
    #expect(session.snrVariation.spread == 12)
    #expect(session.snrVariation.change == 2)
}

@Test func signalChangesRequireAdjacentValuesWithinAnObservedSegment() {
    var session = WiFiSession()
    session.append(stabilityReading(0))
    session.append(stabilityReading(1, rssi: -65, noise: 0))
    #expect(session.rssiVariation.change == -5)
    #expect(session.snrVariation.change == nil)
    session.append(stabilityReading(2))
    #expect(session.rssiVariation.change == 5)
    #expect(session.snrVariation.change == nil)
    session.append(stabilityReading(3), startsSegment: true)
    #expect(session.rssiVariation.change == nil)
    session.append(stabilityReading(6))
    #expect(session.snrVariation.change == nil)
    session.append(stabilityReading(5))
    #expect(session.rssiVariation.change == nil)
    session.append(stabilityReading(5))
    #expect(session.snrVariation.change == nil)
    session.append(stabilityReading(6, state: .unknown))
    session.append(stabilityReading(7))
    #expect(session.rssiVariation.change == nil)
    session.append(stabilityReading(8, rssi: 0))
    #expect(session.rssiVariation.change == nil)
    #expect(session.snrVariation.change == nil)
    session.append(stabilityReading(9))
    #expect(session.rssiVariation.change == nil)
    session.append(stabilityReading(70, state: .disconnected))
    #expect(session.rssiVariation.minimum == nil)
    #expect(session.snrVariation.maximum == nil)
}

private func stabilityReading(_ seconds: TimeInterval, wallTime: TimeInterval? = nil, state: WiFiState = .connected,
                              rssi: Int = -60, noise: Int = -92) -> WiFiSample {
    WiFiSample(time: Date(timeIntervalSince1970: wallTime ?? seconds), monotonicTime: seconds, state: state,
               measurements: WiFiMeasurements(rssi: rssi, noise: noise))
}
