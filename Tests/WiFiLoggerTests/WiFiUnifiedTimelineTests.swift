import Foundation
import Testing

@testable import WiFiLogger

@Test @MainActor func unifiedChartGroupsOnlyTheChosenMetrics() {
    let recording = WiFiRecording()
    #expect(recording.chartLanes == [.signalAndNoise, .gatewayRTT])
    recording.setChartTrend(.signal, visible: false)
    recording.setChartTrend(.noise, visible: false)
    recording.setChartTrend(.gatewayRTT, visible: false)
    #expect(recording.chartTrends == [.gatewayRTT])
    recording.setChartTrend(.snr, visible: true)
    #expect(recording.chartLanes == [.snr])
}

@Test func sharedGridProjectsEachAxisIndependently() {
    let left = WiFiChartScale(bounds: -100 ... -40)
    let right = WiFiChartScale(bounds: 0 ... 100)
    #expect(left.position(of: -70) == 0.5)
    #expect(right.position(of: 50) == 0.5)
    #expect(left.value(at: 0.75) == -55)
    #expect(right.value(at: 0.75) == 75)
    #expect(abs(right.value(at: left.position(of: -72)) - 46.6666667) < 0.000001)
}

@Test func sharedGridKeepsRTTLineGapsBetweenCapturesAndTimeouts() {
    let first = UUID()
    let second = UUID()
    let probes = [
        WiFiGatewayProbe(result: .reply(5), uptime: 1, captureID: first),
        WiFiGatewayProbe(result: .reply(6), uptime: 2, captureID: first),
        WiFiGatewayProbe(result: .timeout, uptime: 3, captureID: first),
        WiFiGatewayProbe(result: .reply(7), uptime: 4, captureID: first),
        WiFiGatewayProbe(result: .reply(8), uptime: 4.5, captureID: second),
        WiFiGatewayProbe(result: .reply(9), uptime: 8, captureID: second),
    ]
    let replies = WiFiGatewayChartPoint.replies(in: probes)
    #expect(replies.map(\.milliseconds) == [5, 6, 7, 8, 9])
    #expect(replies.map(\.segment) == [1, 1, 2, 3, 4])
}

@Test func sharedGridMergesRadioAndGatewayCursorPositions() {
    let probe = WiFiGatewayProbe(result: .timeout, time: Date(timeIntervalSince1970: 2), uptime: 2)
    let radio = [1.0, 3.0].map {
        WiFiTimelineObservation(time: $0, date: Date(timeIntervalSince1970: $0), source: .radio(Int($0)))
    }
    let gateway = WiFiTimelineObservation(time: 2, date: probe.time, source: .gateway(probe))
    let positions = WiFiTimelineObservation.merged(radio, [gateway])
    #expect(positions.map(\.time) == [1, 2, 3])
    #expect(positions.nearestIndex(to: 2, time: \.time) == 1)
    #expect(WiFiTimelineObservation.merged(radio, [radio[0], gateway]).map(\.time) == [1, 2, 3])
}

@Test func sharedGridTapOnAGatewayMarkWinsOverARadioSampleInTheSameColumn() {
    let reply = WiFiGatewayProbe(result: .reply(50), uptime: 99.2)
    let timeout = WiFiGatewayProbe(result: .timeout, uptime: 100.2)
    let scale = WiFiChartScale(bounds: 0...100)
    func x(_ uptime: Double) -> CGFloat? { uptime * 2 }
    func y(_ fraction: Double) -> CGFloat? { 200 * (1 - fraction) }

    #expect(WiFiTimelineChart.gatewayHit(in: [reply, timeout], at: CGPoint(x: 200, y: 190),
                                        scale: scale, x: x, y: y) == timeout)
    #expect(WiFiTimelineChart.gatewayHit(in: [reply, timeout], at: CGPoint(x: 199, y: 100),
                                        scale: scale, x: x, y: y) == reply)
    #expect(WiFiTimelineChart.gatewayHit(in: [reply, timeout], at: CGPoint(x: 200, y: 135),
                                        scale: scale, x: x, y: y) == nil)
    #expect(WiFiTimelineChart.gatewayHit(in: [reply, timeout], at: CGPoint(x: 203, y: 190),
                                        scale: scale, x: x, y: y) == nil)
    #expect(WiFiTimelineChart.gatewayHit(in: [reply, timeout], at: CGPoint(x: 200, y: 190),
                                        scale: scale, closerThan: 0.1, x: x, y: y) == nil)
}

@Test @MainActor func unifiedCursorShowsTheProbeActualTimeAndDoesNotReuseAStaleProbe() throws {
    var session = WiFiSession()
    for second in [100.0, 100.25, 100.5, 103.0] {
        session.append(WiFiSample(time: Date(timeIntervalSince1970: second), monotonicTime: second,
                                  state: .connected, measurements: WiFiMeasurements(rssi: -50)))
    }
    let probe = WiFiGatewayProbe(result: .timeout, time: Date(timeIntervalSince1970: 100.1), uptime: 100.1)
    session.append(probe)
    let recording = WiFiRecording(session: session)

    recording.selectRadioSample(2)
    #expect(recording.inspectedAt == Date(timeIntervalSince1970: 100.5))
    #expect(recording.radioCursorIndex == 2)
    #expect(recording.displayedGatewayProbe == probe)
    recording.selectRadioSample(3)
    #expect(recording.displayedGatewayProbe == nil)
    recording.moveRadioWindow(to: 2)
    recording.selectGatewayProbe(probe)
    #expect(recording.inspectedAt == probe.time)
    #expect(recording.selectedIndex == 0)
    #expect(recording.radioCursorIndex == nil)
    #expect(recording.displayedGatewayProbe == probe)
    #expect(try #require(recording.inspectedUptime) == probe.uptime)
    recording.changeChartSpan(.thirtySeconds)
    let period = recording.timelineUptimes
    #expect(period == 100...100.5)
    recording.setChartTrend(.gatewayRTT, visible: false)
    recording.setChartTrend(.snr, visible: true)
    #expect(recording.inspectedUptime == probe.uptime)
    #expect(recording.chartSpan == .thirtySeconds)
    #expect(recording.timelineUptimes == period)
}

@Test @MainActor func unifiedChartDoesNotMatchARadioSampleToAProbeBeforeResume() {
    var session = WiFiSession()
    let before = Date(timeIntervalSince1970: 100)
    session.append(WiFiSample(time: before, monotonicTime: 100, state: .connected,
                              measurements: WiFiMeasurements(rssi: -50)))
    session.append(WiFiGatewayProbe(result: .reply(4.5), time: before, uptime: 100))
    session.append(WiFiSample(time: before.addingTimeInterval(0.5), monotonicTime: 100.5, state: .connected,
                              measurements: WiFiMeasurements(rssi: -50)), startsSegment: true)
    let recording = WiFiRecording(session: session)

    #expect(recording.displayedGatewayProbe == nil)
    recording.selectRadioSample(1)
    #expect(recording.displayedGatewayProbe == nil)
}

@Test @MainActor func unifiedCursorDoesNotReuseARadioSampleAcrossAGap() {
    var session = WiFiSession()
    for second in [100.0, 110.0] {
        session.append(WiFiSample(time: Date(timeIntervalSince1970: second), monotonicTime: second,
                                  state: .connected, measurements: WiFiMeasurements(rssi: -50)))
    }
    let probe = WiFiGatewayProbe(result: .timeout, time: Date(timeIntervalSince1970: 103), uptime: 103)
    session.append(probe)
    let recording = WiFiRecording(session: session)

    recording.selectGatewayProbe(probe)
    #expect(recording.selectedIndex == nil)
    #expect(recording.displayedSample == nil)
    #expect(recording.displayedGatewayProbe == probe)
}

@Test func unifiedCursorKeyboardStepsAroundTheSelectedTime() {
    let points = 4..<9
    func time(of index: Int) -> Double { Double(index) }
    #expect(WiFiChartSelectionStep.previous.target(in: points, from: 6.5, timeOf: time) == 6)
    #expect(WiFiChartSelectionStep.next.target(in: points, from: 6.5, timeOf: time) == 7)
    #expect(WiFiChartSelectionStep.previous.target(in: points, from: 3.5, timeOf: time) == nil)
    #expect(WiFiChartSelectionStep.next.target(in: points, from: 8.5, timeOf: time) == nil)
}
