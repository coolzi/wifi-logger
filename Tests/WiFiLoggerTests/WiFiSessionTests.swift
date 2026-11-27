import Foundation
import Testing

@testable import WiFiLogger

@Test func recordingSegmentsUseMonotonicGapsAndExplicitResumes() {
    var session = WiFiSession()
    session.append(reading(0))
    session.append(reading(1, wallTime: 100))
    session.append(reading(2, wallTime: 101, state: .unknown))
    session.append(reading(3, wallTime: 102))
    session.append(reading(3.5, wallTime: 102.5), startsSegment: true)
    session.append(reading(6, wallTime: 105))
    session.append(reading(8.5001, wallTime: 107.5001))
    session.append(reading(8.5001, wallTime: 108))
    session.append(reading(7, wallTime: 109))
    #expect(session.segmentIDs == [0, 0, 0, 0, 1, 1, 2, 3, 4])
    #expect(session.events.isEmpty)
    #expect(session.points(for: .signal).map(\.segment) == [0, 1, 3, 4, 4, 6, 7, 8])
}

@Test func outageShadingUsesRecordedEndpointsOnTheElapsedAxis() {
    var session = WiFiSession()
    session.append(reading(0, wallTime: 1000))
    session.append(reading(1, wallTime: 1001, state: .disconnected))
    session.append(reading(2, wallTime: 1003, state: .disconnected))
    session.append(reading(3, wallTime: 1004))
    let event = session.events.first(where: { $0.kind == .reconnected })
    #expect(event?.duration == 2)
    #expect(session.chartOutages(in: session.samples.indices) == [1 ... 3])
    #expect(session.chartTimes[1] == 1)
    #expect(session.chartTimes[3] == 3)
}

@Test func outageShadingDoesNotSpanCalendarGaps() {
    let histories: [[TimeInterval]] = [[0, 1, 301, 302], [0, 1, 0.5, 1.5]]
    for times in histories {
        var session = WiFiSession()
        for index in times.indices {
            session.append(reading(Double(index), wallTime: times[index],
                state: index == 1 || index == 2 ? .disconnected : .connected))
        }
        let event = session.events.first(where: { $0.kind == .reconnected })
        #expect(event?.duration == 2)
        #expect(session.chartOutages(in: session.samples.indices).isEmpty)
    }
}

@Test func snrChartUsesDBAndTheSameQualityScaleAsTheReadout() {
    #expect(WiFiChartLane.snr.trends == [.snr])
    #expect(WiFiChartLane.snr.axisTitle == "дБ")
    #expect(!WiFiChartLane.snr.usesCategories)
    #expect(WiFiTrend.snr.qualityMetric == .snr)
}

@Test func snrChartKeepsZeroAndExtremesAndBreaksAtMissingInputsAndCaptureGaps() {
    var session = WiFiSession()
    func append(_ seconds: Double, rssi: Int? = -60, noise: Int? = -95,
                state: WiFiState = .connected, startsSegment: Bool = false) {
        session.append(WiFiSample(time: Date(timeIntervalSince1970: seconds), monotonicTime: seconds, state: state,
                                  measurements: WiFiMeasurements(rssi: rssi, noise: noise)),
                       startsSegment: startsSegment)
    }
    append(0)
    append(1, rssi: -70)
    append(2, rssi: nil)
    append(3, noise: 0)
    append(4, rssi: -75)
    append(5, state: .disconnected)
    append(6, rssi: -76)
    append(7, state: .unknown)
    append(8, rssi: -95)
    append(9, rssi: -100)
    append(10, rssi: -45)
    append(11, startsSegment: true)
    append(20)
    append(19)

    let points = session.points(for: .snr)
    #expect(points.map(\.sampleIndex) == [0, 1, 4, 6, 8, 9, 10, 11, 12, 13])
    #expect(points.map(\.value) == [35, 25, 20, 19, 0, -5, 50, 35, 35, 35].map { .number(Double($0)) })
    #expect(points.map(\.segment) == [0, 0, 4, 6, 8, 8, 8, 11, 12, 13])
}

@Test func eventsPointToTheRecordedTransition() {
    var session = WiFiSession()
    session.append(reading(0, bssid: "02:00:00:00:00:01"))
    session.append(reading(1, state: .disconnected))
    session.append(reading(2, state: .poweredOff))
    session.append(reading(3, bssid: "02:00:00:00:00:01"))
    session.append(reading(4, bssid: "02:00:00:00:00:02"))
    session.append(reading(5, ssid: "Other", bssid: "02:00:00:00:00:03"))

    #expect(session.events.map(\.kind) == [.disconnected, .reconnected, .accessPointChanged])
    #expect(session.events.map(\.sampleIndex) == [1, 3, 4])
    #expect(session.events.first(where: { $0.kind == .reconnected })?.duration == 2)
}

@Test func distinctSSIDBytesDoNotCreateAnAccessPointChange() {
    var session = WiFiSession()
    session.append(reading(0, ssid: "Caf\u{E9}", bssid: "first"))
    session.append(reading(1, ssid: "Cafe\u{301}", bssid: "second"))
    session.append(reading(2, ssid: "Cafe\u{301}", bssid: "third"))

    #expect(session.events.map(\.sampleIndex) == [2])
    #expect(session.events.map(\.kind) == [.accessPointChanged])
}

@Test func roamingUsesTheRawIdentityEvenIfTheDisplayNameIsUnavailable() {
    var session = WiFiSession()
    let identity = Data([0x81])
    let observations = [
        WiFiMeasurements(ssid: "Home", bssid: "first", ssidData: identity),
        WiFiMeasurements(ssid: "Home", bssid: "second"),
        WiFiMeasurements(bssid: "third", ssidData: identity),
        WiFiMeasurements(bssid: "fourth", ssidData: identity),
    ]
    for (index, fields) in observations.enumerated() {
        let time = Double(index)
        session.append(WiFiSample(time: Date(timeIntervalSince1970: time), monotonicTime: time,
                                  state: .connected, measurements: fields))
    }

    #expect(session.events.map(\.kind) == [.accessPointChanged])
    #expect(session.events.map(\.sampleIndex) == [3])
}

@Test func aPauseOrUnknownStateDoesNotCreateFalseTransitions() {
    var session = WiFiSession()
    session.append(reading(0))
    session.append(reading(1, state: .disconnected), startsSegment: true)
    session.append(reading(2, state: .unknown))
    session.append(reading(3))
    session.append(reading(60, bssid: "02:00:00:00:00:02"))

    #expect(session.events.isEmpty)
    let signal = session.points(for: .signal)
    #expect(signal.map(\.sampleIndex) == [0, 3, 4])
    #expect(Set(signal.map(\.segment)).count == 3)
}

@Test func missingMetricsBreakOnlyTheirOwnLine() {
    var session = WiFiSession()
    session.append(reading(0))
    session.append(reading(1, rssi: 0))
    session.append(reading(2))
    session.append(reading(2.5), startsSegment: true)

    let signal = session.points(for: .signal)
    let noise = session.points(for: .noise)
    #expect(signal.map(\.sampleIndex) == [0, 2, 3])
    #expect(Set(signal.map(\.segment)).count == 3)
    #expect(noise.map(\.sampleIndex) == [0, 1, 2, 3])
    #expect(Set(noise.prefix(3).map(\.segment)).count == 1)
    #expect(noise.last?.segment != noise.first?.segment)
}

@Test func chartRecordsChannelModeAndExactTransmitRate() {
    var session = WiFiSession()
    session.append(graphReading(0, band: .ghz5, mode: "802.11ac", rate: 432.5))
    session.append(graphReading(1, band: .ghz6, mode: "802.11ax", rate: 1201))

    #expect(session.points(for: .channel).map(\.value) == [
        .category("149 · 5 ГГц · 80 МГц"), .category("149 · 6 ГГц · 80 МГц"),
    ])
    #expect(session.points(for: .phyMode).map(\.value) == [.category("Wi-Fi 5"), .category("Wi-Fi 6E")])
    #expect(session.points(for: .transmitRate).map(\.value) == [.number(432.5), .number(1201)])
    let points = WiFiTrend.allCases.flatMap { session.points(for: $0) }
    #expect(Set(points.map(\.id)).count == points.count)
}

@Test func chartLeavesGapsForUnavailableMetricsAndPausedCapture() {
    var session = WiFiSession()
    session.append(graphReading(0))
    session.append(graphReading(1, number: nil, mode: nil, rate: .infinity))
    session.append(graphReading(2, rate: -1))
    session.append(graphReading(3, state: .disconnected))
    session.append(graphReading(4))
    session.append(graphReading(5, rate: 0), startsSegment: true)
    session.append(graphReading(6))

    for trend in [WiFiTrend.channel, .phyMode] {
        let points = session.points(for: trend)
        #expect(points.map(\.sampleIndex) == [0, 2, 4, 5, 6])
        #expect(points.map(\.segment) == [0, 2, 4, 5, 5])
    }
    let rate = session.points(for: .transmitRate)
    #expect(rate.map(\.sampleIndex) == [0, 4, 6])
    #expect(rate.map(\.segment) == [0, 4, 6])
    #expect(session.points(for: .signal).map(\.segment) == [0, 0, 0, 4, 5, 5])
}

@Test func chartSelectionFindsTheNearestRecordedSample() {
    var session = WiFiSession()
    #expect(session.sampleIndex(nearest: 0, in: session.samples.indices) == nil)

    session.append(reading(1))
    session.append(reading(2, state: .disconnected))
    session.append(reading(5), startsSegment: true)

    let range = session.samples.indices
    #expect(session.sampleIndex(nearest: -1, in: range) == 0)
    #expect(session.sampleIndex(nearest: 0.5, in: range) == 0)
    #expect(session.sampleIndex(nearest: 0.8, in: range) == 1)
    #expect(session.sampleIndex(nearest: 3, in: range) == 2)
    #expect(session.sampleIndex(nearest: 9, in: range) == 2)
}

@Test func chartPositionsStayOrderedAfterAnInjectedMonotonicReset() {
    var session = WiFiSession()
    session.append(reading(4))
    session.append(reading(2))
    session.append(reading(2))

    let range = session.samples.indices
    #expect(session.chartTimes == [0, 1, 2])
    #expect(session.segmentIDs == [0, 1, 2])
    #expect(session.sampleIndex(nearest: 1.5, in: range) == 1)
    #expect(session.sampleIndex(nearest: 2, in: range) == 2)
}

@Test func chartKeepsReusedCalendarTimesOutsideTheOlderOutage() {
    var session = WiFiSession()
    for (index, time) in [1000.0, 1001, 1002, 1003, 1001, 1002, 1003].enumerated() {
        session.append(reading(Double(index), wallTime: time,
                               state: index == 1 || index == 2 ? .disconnected : .connected))
    }
    let range = session.samples.indices
    #expect(session.samples[2].time == session.samples[5].time)
    #expect(session.chartOutages(in: range) == [1 ... 3])
    #expect(session.chartTimes[5] > session.chartTimes[3])
    #expect(session.sampleIndex(nearest: session.chartTimes[5], in: range) == 5)
}

@Test @MainActor func chartWindowBoundsRenderingAndKeepsOlderSamplesReachable() {
    var session = WiFiSession()
    #expect(WiFiRecording().chartWindow.samples.isEmpty)
    for index in 0..<900 {
        session.append(reading(Double(index), state: (200..<330).contains(index) ? .disconnected : .connected))
    }
    let recording = WiFiRecording(session: session)
    let latest = recording.chartWindow.samples
    recording.moveRadioWindow(to: 299)
    let first = recording.chartWindow.samples
    recording.moveRadioWindow(to: 499)
    let middle = recording.chartWindow.samples
    #expect(first == 0..<300)
    recording.moveRadioWindow(to: 119)
    #expect(recording.chartWindow.samples == 0..<120)
    #expect(middle == 199..<500)
    #expect(latest == 599..<900)
    #expect(session.points(for: .signal, in: latest).map(\.sampleIndex) == Array(latest))
    #expect(session.points(for: .signal, in: middle).map(\.sampleIndex) == [199] + Array(330..<500))
    #expect(session.chartEvents(in: middle).map(\.sampleIndex) == [200, 330])
    #expect(session.chartOutages(in: first) == [200 ... 330])
    #expect(session.chartOutages(in: 220..<240) == [200 ... 330])
    #expect(session.chartOutages(in: 199..<200).isEmpty)
    #expect(session.chartOutages(in: latest).isEmpty)
    #expect(session.sampleIndex(nearest: 400, in: latest) == 599)
    #expect(session.sampleIndex(nearest: 750.5, in: latest) == 750)
    #expect(session.samples.count == 900)
}

@Test func chartClickUsesPlotCoordinatesIncludingItsEdges() {
    let plot = CGRect(x: 40, y: 10, width: 600, height: 180)

    #expect(WiFiTimelineChart.plotX(at: CGPoint(x: 40, y: 10), in: plot) == 0)
    #expect(WiFiTimelineChart.plotX(at: CGPoint(x: 340, y: 100), in: plot) == 300)
    #expect(WiFiTimelineChart.plotX(at: CGPoint(x: 640, y: 190), in: plot) == plot.width.nextDown)
    #expect(WiFiTimelineChart.plotX(at: CGPoint(x: 39, y: 100), in: plot) == nil)
    #expect(WiFiTimelineChart.plotX(at: CGPoint(x: 340, y: 191), in: plot) == nil)
    #expect(WiFiTimelineChart.plotX(at: .zero, in: .zero) == nil)
}

@Test @MainActor func chartSpanUsesElapsedTimeAndIncludesTheBoundaryAcrossPauses() {
    var session = WiFiSession()
    for time in [0.0, 29, 30, 32, 59, 60, 88, 89, 90] {
        session.append(reading(time, wallTime: 1000 - time))
    }

    let recording = WiFiRecording(session: session)
    #expect(recording.chartWindow.samples == 0..<9)
    recording.changeChartSpan(.oneMinute)
    #expect(recording.chartWindow.samples == 2..<9)
    recording.changeChartSpan(.thirtySeconds)
    #expect(recording.chartWindow.samples == 5..<9)
    recording.moveRadioWindow(to: 5)
    #expect(recording.chartWindow.samples == 2..<6)
    #expect(session.chartEndIndex(atOrBefore: 58) == 3)
    #expect(session.chartEndIndex(atOrBefore: 60) == 5)
}

@Test @MainActor func chartSpanKeepsTheFullTimeDomainWhenAWindowContainsOneSample() {
    var session = WiFiSession()
    session.append(reading(0))
    #expect(WiFiRecording(session: session).chartWindow.times == 0...5)
    session.append(reading(600, wallTime: -50))

    let window = WiFiRecording(session: session).chartWindow
    #expect(window.samples == 1..<2)
    #expect(window.times == 300...600)
}

@Test @MainActor func chartPagingCrossesAPauseLongerThanTheVisibleSpan() throws {
    var session = WiFiSession()
    for time in [0.0, 1, 1000, 1001] {
        session.append(reading(time))
    }

    let span = WiFiChartSpan.oneMinute
    let recording = WiFiRecording(session: session)
    recording.changeChartSpan(span)
    let latest = recording.chartWindow
    #expect(latest.samples == 2..<4)
    let previousEnd = latest.samples.lowerBound - 1
    recording.moveRadioWindow(to: previousEnd)
    #expect(recording.chartWindow.samples == 0..<2)
    let nextEnd = try #require(session.nextChartEnd(after: previousEnd, span: span))
    #expect(nextEnd == 2)
    recording.moveRadioWindow(to: nextEnd)
    #expect(recording.chartWindow.samples == 2..<3)
    #expect(session.nextChartEnd(after: nextEnd, span: span) == 3)
    #expect(session.nextChartEnd(after: 3, span: span) == nil)
}

@Test func channelChangesIncludeBandWidthAndSimultaneousRoaming() {
    var session = WiFiSession()
    session.append(channelReading(0))
    session.append(channelReading(1, number: 44))
    session.append(channelReading(2, band: .ghz6, number: 44))
    session.append(channelReading(3, band: .ghz6, number: 44, width: 160))
    session.append(channelReading(4, band: .ghz6, number: 48, width: 160, bssid: "second"))

    #expect(session.events.map(\.sampleIndex) == [1, 2, 3, 4, 4])
    #expect(session.events.map { $0.kind.title } == [
        "Изменились параметры канала", "Изменились параметры канала", "Изменились параметры канала",
        "Смена точки доступа", "Изменились параметры канала",
    ])
    #expect(Set(session.events.map(\.id)).count == session.events.count)
}

@Test func unavailableChannelsAndCaptureGapsDoNotCreateChannelEvents() {
    var session = WiFiSession()
    session.append(channelReading(0, band: nil, width: nil))
    session.append(channelReading(1))
    session.append(channelReading(2, number: nil))
    session.append(channelReading(3, number: 44))
    session.append(channelReading(4, number: 48), startsSegment: true)
    session.append(channelReading(60, number: 36))
    session.append(channelReading(61, state: .unknown, number: 44))
    session.append(channelReading(62, number: 48))
    session.append(channelReading(63, state: .disconnected))
    session.append(channelReading(64, number: 44))
    session.append(channelReading(65, number: 0))
    session.append(channelReading(66, number: 48))

    #expect(session.events.map { $0.kind.title } == ["Связь прервалась", "Связь восстановилась"])
}

private func graphReading(_ seconds: TimeInterval,
                          state: WiFiState = .connected,
                          band: WiFiBand = .ghz5, number: Int? = 149,
                          mode: String? = "802.11ax", rate: Double? = 866) -> WiFiSample {
    WiFiSample(time: Date(timeIntervalSince1970: seconds), monotonicTime: seconds, state: state,
               measurements: WiFiMeasurements(rssi: -60, noise: -92,
                   channel: WiFiChannel(band: band, number: number, width: 80),
                   phyMode: mode, transmitRate: rate))
}

private func reading(_ seconds: TimeInterval, wallTime: TimeInterval? = nil, state: WiFiState = .connected,
                     ssid: String = "Home", bssid: String = "02:00:00:00:00:01",
                     rssi: Int = -60) -> WiFiSample {
    WiFiSample(time: Date(timeIntervalSince1970: wallTime ?? seconds), monotonicTime: seconds, state: state,
               measurements: WiFiMeasurements(ssid: ssid, bssid: bssid, rssi: rssi, noise: -92,
                                              ssidData: Data(ssid.utf8)))
}

private func channelReading(_ seconds: TimeInterval, state: WiFiState = .connected,
                            band: WiFiBand? = .ghz5, number: Int? = 36, width: Int? = 80,
                            bssid: String = "first") -> WiFiSample {
    WiFiSample(time: Date(timeIntervalSince1970: seconds), monotonicTime: seconds, state: state,
               measurements: WiFiMeasurements(ssid: "Home", bssid: bssid,
                   channel: WiFiChannel(band: band, number: number, width: width), ssidData: Data("Home".utf8)))
}
