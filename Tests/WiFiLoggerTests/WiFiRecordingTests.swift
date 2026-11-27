import Combine
import Foundation
import Testing

@testable import WiFiLogger

@Test func chartKeyboardSelectionStaysWithinTheVisibleSamples() {
    let samples = 80..<85
    #expect(WiFiChartSelectionStep.previous.target(in: samples, from: nil) == 84)
    #expect(WiFiChartSelectionStep.previous.target(in: samples, from: 84) == 83)
    #expect(WiFiChartSelectionStep.previous.target(in: samples, from: 80) == nil)
    #expect(WiFiChartSelectionStep.next.target(in: samples, from: 84) == nil)
    #expect(WiFiChartSelectionStep.next.target(in: samples, from: 81) == 82)
}

@Test func chartKeyboardSelectionSkipsMissingPointsAndDoesNotWrap() {
    let nssPoints = [3, 8, 11]
    #expect(WiFiChartSelectionStep.previous.target(in: nssPoints, from: 7) == 3)
    #expect(WiFiChartSelectionStep.next.target(in: nssPoints, from: 7) == 8)
    #expect(WiFiChartSelectionStep.next.target(in: nssPoints, from: 11) == nil)
    #expect(WiFiChartSelectionStep.next.target(in: [Int](), from: nil) == nil)
}

@Test @MainActor func bothTabsUseTheSameTimeSpan() {
    let recording = timelineRecording(
        radio: [1000, 1100, 1170, 1290, 1300, 1360, 1390],
        modulation: [1010, 1095.5, 1293, 1335.5, 1395.5]
    )
    #expect(recording.timelinePlotUptimes == 1095.5...1395.5)
    #expect(recording.chartWindow.times == 95.5...395.5)
    #expect(recording.chartWindow.samples == 1..<7)
    #expect(recording.modulationWindow == 1..<5)

    recording.changeChartSpan(.oneMinute)
    recording.tab = .modulation
    #expect(recording.timelinePlotUptimes == 1335.5...1395.5)
    #expect(recording.chartWindow.times == 335.5...395.5)
    #expect(recording.chartWindow.samples == 5..<7)
    #expect(recording.modulationWindow == 3..<5)
}

@Test(arguments: WiFiChartLane.allCases)
@MainActor func pinningASampleKeepsTheSameChartSelection(lane: WiFiChartLane) {
    let recording = timelineRecording(radio: [1000, 1010, 1020], modulation: [])
    for trend in lane.trends { recording.setChartTrend(trend, visible: true) }
    for trend in WiFiTrend.allCases where !lane.trends.contains(trend) {
        recording.setChartTrend(trend, visible: false)
    }

    recording.selectRadioSample(1)

    #expect(recording.chartLanes == [lane])
    #expect(recording.chartTrends == Set(lane.trends))
    #expect(recording.displayedSample?.monotonicTime == 1010)
}

@Test func observationTimeAvoidsRepeatingTheSelectedInstantAndIncludesAnotherDate() {
    let midnight = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_795_000_000))
    let previousDay = midnight.addingTimeInterval(-0.25)
    let later = midnight.addingTimeInterval(0.5)

    #expect(WiFiInspectionTime.observation(midnight, comparedTo: midnight) == nil)
    #expect(WiFiInspectionTime.observation(later, comparedTo: midnight) == later.formatted(WiFiInspectionTime.clock))
    #expect(WiFiInspectionTime.observation(previousDay, comparedTo: midnight) == WiFiInspectionTime.timestamp(previousDay))
    #expect(WiFiInspectionTime.observation(midnight, comparedTo: nil) == WiFiInspectionTime.timestamp(midnight))
}

@Test @MainActor func switchingTabsKeepsTheSourceTimeWithoutSnappingItTwice() {
    let recording = timelineRecording(radio: [1000, 1010, 1020, 1030, 1040], modulation: [1012, 1024, 1038])
    recording.toggle()
    let id = recording.captureID
    recording.selectRadioSample(2)

    recording.tab = .modulation
    #expect(recording.selectedModulationIndex == 1)
    #expect(recording.inspectedAt == Date(timeIntervalSince1970: 1020))
    recording.tab = .recording
    #expect(recording.selectedIndex == 2)
    #expect(recording.inspectedAt == Date(timeIntervalSince1970: 1020))
    #expect(recording.captureID == id)

    recording.selectModulationSnapshot(0)
    #expect(recording.inspectedAt == Date(timeIntervalSince1970: 1012))
    #expect(recording.selectedIndex == 1)
    recording.returnToLatest()
    #expect(recording.selectedIndex == nil)
    #expect(recording.selectedModulationIndex == nil)
    #expect(!recording.isShowingHistory)
}

@Test @MainActor func anEmptyIntervalDoesNotSelectASnapshotFromAnotherPeriod() {
    let recording = timelineRecording(radio: [100, 150, 210], modulation: [110, 195])
    recording.changeChartSpan(.thirtySeconds)
    recording.moveRadioWindow(to: 1)
    recording.selectRadioSample(1)

    recording.tab = .modulation
    #expect(recording.timelinePlotUptimes == 120...150)
    #expect(recording.modulationWindow.isEmpty)
    #expect(recording.selectedModulationIndex == nil)
    #expect(recording.inspectedAt == Date(timeIntervalSince1970: 150))
    #expect(recording.selectedIndex == 1)
}

@Test @MainActor func aRadioSampleExactlyOnTheSharedBoundaryIsVisible() {
    let boundary = 89.36638914902495
    let recording = timelineRecording(
        radio: [6.539603192296318, 7.879417794650402, 45.922328519163734, 47.6871206977874, boundary],
        modulation: [boundary + 30]
    )
    recording.changeChartSpan(.thirtySeconds)
    #expect(recording.timelinePlotUptimes.lowerBound == boundary)
    #expect(recording.chartWindow.samples == 4..<5)
}

@Test @MainActor func spatialStreamsUseTheirOwnTimeAtTheEdgeOfTheSharedWindow() {
    let nssDate = Date(timeIntervalSince1970: 110.5)
    let snapshot = WiFiModulationSnapshot(
        interfaceName: "en0", startedAt: Date(timeIntervalSince1970: 109),
        finishedAt: Date(timeIntervalSince1970: 110), startedUptime: 109, finishedUptime: 110,
        phyMode: "802.11ax", channel: nil, mcs: 11, transmitRateMbps: 573,
        spatialStreams: WiFiSpatialStreamsReading(count: 2, receivedAt: nssDate, receivedUptime: 110.5)
    )
    let live = WiFiRecording(modulationSnapshots: [snapshot])
    #expect(live.timelineUptimes.upperBound == 110.5)
    live.selectModulationSnapshot(0, atNSS: true)
    #expect(live.inspectedAt == nssDate)

    var history = WiFiSession()
    for time in [100.0, 140.5, 141] {
        history.append(WiFiSample(time: Date(timeIntervalSince1970: time), monotonicTime: time,
                                  state: .connected, measurements: WiFiMeasurements()))
    }
    let recording = WiFiRecording(session: history, modulationSnapshots: [snapshot])
    recording.changeChartSpan(.thirtySeconds)
    #expect(recording.modulationWindow.isEmpty)
    recording.moveRadioWindow(to: 1)
    #expect(recording.timelineUptimes.lowerBound == 110.5)
    #expect(recording.modulationWindow == 0..<1)
    recording.selectModulationSnapshot(0, atNSS: true)
    #expect(recording.selectedModulationIndex == 0)
    #expect(recording.inspectedAt == nssDate)
    #expect(recording.timelineUptimes.upperBound == 140.5)
}

@Test @MainActor func selectingAStreamsPointKeepsItsSnapshotAfterAQuickResume() {
    let nssDate = Date(timeIntervalSince1970: 110.75)
    let first = WiFiModulationSnapshot(
        interfaceName: "en0", startedAt: Date(timeIntervalSince1970: 109),
        finishedAt: Date(timeIntervalSince1970: 110), startedUptime: 109, finishedUptime: 110,
        phyMode: "802.11ax", channel: nil, mcs: 11, transmitRateMbps: 573,
        spatialStreams: WiFiSpatialStreamsReading(count: 2, receivedAt: nssDate, receivedUptime: 110.75)
    )
    let afterResume = WiFiModulationSnapshot(
        interfaceName: "en0", startedAt: Date(timeIntervalSince1970: 110.875),
        finishedAt: Date(timeIntervalSince1970: 111), startedUptime: 110.875, finishedUptime: 111,
        phyMode: "802.11ax", channel: nil, mcs: 7, transmitRateMbps: 288
    )
    let recording = WiFiRecording(modulationSnapshots: [first, afterResume])

    recording.selectModulationSnapshot(0, atNSS: true)
    #expect(recording.inspectedAt == nssDate)
    #expect(recording.selectedModulationIndex == 0)
}

@Test @MainActor func emptyShortWindowsNavigateByObservedTimeRatherThanPlotPadding() {
    let recording = timelineRecording(radio: [100, 101, 110], modulation: [102, 103])
    recording.changeChartSpan(.thirtySeconds)
    recording.moveRadioWindow(to: 0)
    #expect(recording.timelinePlotUptimes == 100...105)
    #expect(recording.modulationWindow == 0..<0)
    let neighbors = WiFiModulationView.neighboringSnapshots(
        selected: recording.selectedModulationIndex, visible: recording.modulationWindow)
    #expect(neighbors.previous == -1)
    #expect(neighbors.next == 0)
}

@Test @MainActor func liveWindowDoesNotShowARadioSampleOutsideTheSharedPeriod() {
    let recording = timelineRecording(radio: [100, 110], modulation: [150])
    recording.changeChartSpan(.thirtySeconds)
    #expect(recording.timelinePlotUptimes == 120...150)
    #expect(recording.chartWindow.samples.isEmpty)
    #expect(recording.displayedSample == nil)
}

@Test @MainActor func restartingAPausedRecordingClearsEveryViewOfTheOldSession() async throws {
    var history = WiFiSession()
    let states: [WiFiState] = [.connected, .disconnected, .connected]
    for (index, state) in states.enumerated() {
        let time = Double(index)
        history.append(WiFiSample(time: Date(timeIntervalSince1970: time), monotonicTime: time,
                                  state: state, measurements: WiFiMeasurements(rssi: -55)))
    }
    let recording = WiFiRecording(session: history)
    recording.setChartTrend(.snr, visible: true)
    let trends = recording.chartTrends
    recording.changeChartSpan(.fifteenMinutes)
    recording.selectRadioSample(1)

    recording.restart()

    #expect(recording.isRecording)
    #expect(recording.session.id != history.id)
    #expect(recording.session.samples.isEmpty)
    #expect(recording.session.segmentIDs.isEmpty)
    #expect(recording.session.events.isEmpty)
    #expect(recording.session.chartTimes.isEmpty)
    #expect(recording.session.outages.count == 0)
    #expect(recording.session.rssiVariation.minimum == nil)
    #expect(recording.displayedSample == nil)
    #expect(recording.selectedIndex == nil)
    #expect(!recording.isShowingHistory)
    #expect(recording.chartTrends == trends)
    #expect(recording.chartSpan == .fifteenMinutes)

    let currentID = try #require(recording.captureID)
    let capture = Task { await recording.capture(id: currentID) }
    defer { capture.cancel() }
    try #require(await waitForCapture { !recording.session.samples.isEmpty })
    recording.toggle()
    #expect(recording.session.segmentIDs == [0])
    #expect(recording.session.chartTimes == [0])
    #expect(recording.session.events.isEmpty)

    recording.toggle()
    let resumedID = try #require(recording.captureID)
    let resumed = Task { await recording.capture(id: resumedID) }
    defer { resumed.cancel() }
    try #require(await waitForCapture { recording.session.samples.count >= 2 })
    recording.toggle()
    #expect(recording.session.segmentIDs == [0, 1])
}

@Test @MainActor func changingSpanKeepsThePinnedEndAndClearsOnlyAHiddenSelection() {
    var history = WiFiSession()
    for time in [0.0, 20, 40, 60, 80, 100] {
        history.append(WiFiSample(time: Date(timeIntervalSince1970: time), monotonicTime: time,
                                  state: .connected, measurements: WiFiMeasurements()))
    }
    let recording = WiFiRecording(session: history)
    recording.moveRadioWindow(to: 4)
    recording.selectRadioSample(2)

    recording.changeChartSpan(.oneMinute)
    #expect(recording.timelinePlotUptimes.upperBound == 80)
    #expect(recording.chartWindow.samples == 1..<5)
    #expect(recording.selectedIndex == 2)

    recording.changeChartSpan(.thirtySeconds)
    #expect(recording.timelinePlotUptimes.upperBound == 80)
    #expect(recording.chartWindow.samples == 3..<5)
    #expect(recording.selectedIndex == nil)
}

@Test @MainActor func restartingAnActiveRecordingFencesTheSleepingCapture() async throws {
    let recording = WiFiRecording()
    recording.toggle()
    let oldID = try #require(recording.captureID)
    var oldCaptureFinished = false
    let oldCapture = Task {
        await recording.capture(id: oldID)
        oldCaptureFinished = true
    }
    defer { oldCapture.cancel() }
    try #require(await waitForCapture { !recording.session.samples.isEmpty })

    recording.restart()
    let currentID = try #require(recording.captureID)
    #expect(currentID != oldID)
    try #require(await waitForCapture { oldCaptureFinished })
    #expect(recording.isRecording)
    #expect(recording.session.samples.isEmpty)

    await recording.capture(id: oldID)
    #expect(recording.session.samples.isEmpty)
}

@Test @MainActor func cancelledCaptureCanReattachWithTheSameID() async throws {
    let recording = WiFiRecording()
    recording.toggle()
    let id = try #require(recording.captureID)
    let previous = Task { await recording.capture(id: id) }
    defer { previous.cancel() }
    try #require(await waitForCapture { !recording.session.samples.isEmpty })

    // The old consumer cannot finish on the main actor before the new call suspends.
    previous.cancel()
    let pauseWhenReattached = Task {
        defer { recording.toggle() }
        return try await waitForCapture { recording.session.segmentIDs.last == 1 }
    }
    await recording.capture(id: id)
    await previous.value

    let openedNewSegment = try await pauseWhenReattached.value
    #expect(openedNewSegment)
    #expect(Set(recording.session.segmentIDs) == [0, 1])
    #expect(!recording.isRecording)
}

@Test @MainActor func captureUpdatesUnsharedHistoryInPlaceAndNotifiesItsObservers() async throws {
    let historyCount = 100
    let recording = timelineRecording(radio: (0..<historyCount).map(Double.init), modulation: [])
    try #require(recording.session.samples.capacity > historyCount)
    let previousAddress = recording.session.samples.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
    recording.toggle()
    let id = try #require(recording.captureID)
    var countsBeforeUpdates: [Int] = []
    let observation = recording.objectWillChange.sink {
        countsBeforeUpdates.append(recording.session.samples.count)
    }
    defer { observation.cancel() }

    let capture = Task { await recording.capture(id: id) }
    defer { capture.cancel() }
    try #require(await waitForCapture { recording.session.samples.count > historyCount })
    let currentAddress = recording.session.samples.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
    #expect(countsBeforeUpdates.first == historyCount)
    #expect(currentAddress == previousAddress)
}

@Test func fixedChartContentChangesWhenAnOutageEndsBeyondTheWindow() {
    var session = WiFiSession()
    func append(_ second: TimeInterval, _ state: WiFiState, to session: inout WiFiSession) {
        session.append(WiFiSample(time: Date(timeIntervalSince1970: second), monotonicTime: second,
                                  state: state, measurements: WiFiMeasurements()))
    }

    append(0, .connected, to: &session)
    append(1, .disconnected, to: &session)
    append(2, .disconnected, to: &session)
    let window = WiFiChartWindow(samples: 0..<3, times: 0...5)
    func chart(_ session: WiFiSession, selection: Int? = 0,
               trends: Set<WiFiTrend> = [.signal, .noise]) -> WiFiTimelineChart.Content {
        .init(session: session, window: window, selectedIndex: selection, trends: trends)
    }

    let original = chart(session)
    append(3, .disconnected, to: &session)
    #expect(chart(session) == original)
    append(4, .connected, to: &session)
    let restored = chart(session)
    #expect(restored != original)
    #expect(restored.lastOutage == 1...4)
    append(5, .connected, to: &session)
    #expect(chart(session) == restored)
    #expect(chart(session, selection: 2) != restored)
    #expect(chart(session, trends: [.snr]) != restored)
}

@MainActor
private func timelineRecording(radio: [Double], modulation: [Double]) -> WiFiRecording {
    var session = WiFiSession()
    for uptime in radio {
        session.append(WiFiSample(time: Date(timeIntervalSince1970: uptime), monotonicTime: uptime,
                                  state: .connected, measurements: WiFiMeasurements()))
    }
    let snapshots = modulation.map { end in
        WiFiModulationSnapshot(interfaceName: "en0", startedAt: Date(timeIntervalSince1970: end - 1),
            finishedAt: Date(timeIntervalSince1970: end), startedUptime: end - 1, finishedUptime: end,
            phyMode: "802.11ax", channel: nil, mcs: 11, transmitRateMbps: 573)
    }
    return WiFiRecording(session: session, modulationSnapshots: snapshots)
}

@MainActor
private func waitForCapture(_ predicate: () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while !predicate(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    return predicate()
}
