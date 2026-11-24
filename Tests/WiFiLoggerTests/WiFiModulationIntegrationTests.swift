import Foundation
import Testing

@testable import WiFiLogger

@Test func requestBandRequiresANonemptyVisibleIntervalBeforeTheResponse() {
    let window = 100.0...110.0
    #expect(WiFiModulationView.requestBand(start: 98, end: 104, in: window) == 100..<104)
    #expect(WiFiModulationView.requestBand(start: 103, end: 110, in: window) == 103..<110)
    #expect(WiFiModulationView.requestBand(start: 98, end: 100, in: window) == nil)
    #expect(WiFiModulationView.requestBand(start: 104, end: 104, in: window) == nil)
    #expect(WiFiModulationView.requestBand(start: 98, end: 99, in: window) == nil)
    #expect(WiFiModulationView.requestBand(start: 107, end: 111, in: window) == nil)
}

@Test(arguments: [false, true], [false, true]) @MainActor
func emptyModulationHistoryOffersTheAvailableRecordingAction(hasRadioSamples: Bool, readingUnavailable: Bool) {
    let view = WiFiModulationView(snapshots: [], times: 0...5, observedTimes: 0...0,
                                  visible: 0..<0, selectedIndex: nil, inspectedAt: nil, isRecording: false,
                                  hasRadioSamples: hasRadioSamples, readingUnavailable: readingUnavailable) { _, _ in }
    let expected = hasRadioSamples ? "Продолжите запись, чтобы получить снимки."
                                   : "Начните запись, чтобы получить снимки."
    #expect(view.emptyDescription.hasSuffix(expected))
    #expect(view.emptyDescription.hasPrefix("В последней попытке не удалось получить данные модуляции.")
            == readingUnavailable)
}

@Test(arguments: [false, true]) @MainActor
func aModulationResponseCannotArriveAfterPausingOrRestarting(restart: Bool) async throws {
    let recording = WiFiRecording()
    recording.toggle()
    let captureID = try #require(recording.captureID)
    var response: CheckedContinuation<WiFiModulationSnapshot?, Never>?
    let profiling = Task {
        await recording.captureModulation(id: captureID) {
            await withCheckedContinuation { response = $0 }
        }
    }
    defer {
        response?.resume(returning: nil)
        profiling.cancel()
    }

    try #require(await waitForModulationCondition { response != nil })
    if restart {
        recording.restart()
    } else {
        recording.toggle()
    }
    let pending = try #require(response)
    response = nil
    pending.resume(returning: demoSnapshot())
    await profiling.value

    #expect(recording.modulationSnapshots.isEmpty)
    #expect(!recording.modulationReadingUnavailable)
    #expect(recording.isRecording == restart)
}

@Test @MainActor func theMainCaptureContinuesWhileTheModulationRequestIsInFlight() async throws {
    let recording = WiFiRecording()
    recording.toggle()
    let captureID = try #require(recording.captureID)
    var response: CheckedContinuation<WiFiModulationSnapshot?, Never>?
    let profiling = Task {
        await recording.captureModulation(id: captureID) {
            await withCheckedContinuation { response = $0 }
        }
    }
    let capture = Task { await recording.capture(id: captureID) }
    defer {
        response?.resume(returning: nil)
        profiling.cancel()
        capture.cancel()
    }

    try #require(await waitForModulationCondition { response != nil && recording.session.samples.count >= 2 })
    #expect(recording.modulationSnapshots.isEmpty)
    let pending = try #require(response)
    response = nil
    let snapshot = demoSnapshot()
    pending.resume(returning: snapshot)
    try #require(await waitForModulationCondition { recording.modulationSnapshots.count == 1 })
    recording.toggle()
    #expect(recording.modulationSnapshots.first?.id == snapshot.id)
    recording.restart()
    #expect(recording.modulationSnapshots.isEmpty)
}

@Test @MainActor func theNextModulationRequestKeepsItsCadenceAfterASlowHelper() async throws {
    let recording = WiFiRecording()
    recording.toggle()
    let captureID = try #require(recording.captureID)
    var profilerFinishedAt: TimeInterval?
    var nextRequestStartedAt: TimeInterval?
    let profiling = Task {
        await recording.captureModulation(id: captureID) {
            if profilerFinishedAt != nil {
                nextRequestStartedAt = WiFiMonotonicClock.now
                return nil
            }
            // The profiler finished 750 ms before the helper returned this snapshot.
            let finishedAt = WiFiMonotonicClock.now - 0.75
            profilerFinishedAt = finishedAt
            return demoSnapshot(finishedUptime: finishedAt)
        }
    }
    defer { profiling.cancel() }

    try #require(await waitForModulationCondition(timeout: .milliseconds(1750)) { nextRequestStartedAt != nil })
    let finishedAt = try #require(profilerFinishedAt)
    let nextStart = try #require(nextRequestStartedAt)
    #expect(nextStart - finishedAt >= 2)
}

@Test func modulationCSVExportsBothTimesAndOnlyTheObservedSnapshotFields() throws {
    var withSpatialStreams = demoSnapshot()
    withSpatialStreams.spatialStreams = WiFiSpatialStreamsReading(
        count: 2, receivedAt: Date(timeIntervalSince1970: 2.75), receivedUptime: 4.75
    )
    let snapshots = [demoSnapshot(), withSpatialStreams]
    let csv = String(decoding: WiFiCSV.encodeModulation(snapshots, timeZone: .gmt), as: UTF8.self)
    let lines = csv.components(separatedBy: "\r\n")
    try #require(lines.count == 4)
    #expect(lines[0] == "request_started_at,response_received_at,request_started_monotonic_seconds,"
        + "response_received_monotonic_seconds,interface,phy_mode,band,channel,channel_width_mhz,mcs,"
        + "modulation,coding_rate,tx_rate_mbps,reported_spatial_streams,nss_received_at,nss_received_monotonic_seconds")
    #expect(lines[1] == "1970-01-01T00:00:01.250Z,1970-01-01T00:00:02.500Z,3.25,4.5,en0,802.11ax,"
        + "5 ГГц,60,40,11,1024-QAM,5/6,573.0,,,")
    #expect(lines[2] == String(lines[1].dropLast(2)) + "2,1970-01-01T00:00:02.750Z,4.75")
    #expect(lines[3].isEmpty)
}

private func demoSnapshot(finishedUptime: TimeInterval = 4.5) -> WiFiModulationSnapshot {
    WiFiModulationSnapshot(interfaceName: "en0", startedAt: Date(timeIntervalSince1970: 1.25),
                           finishedAt: Date(timeIntervalSince1970: 2.5), startedUptime: finishedUptime - 1.25,
                           finishedUptime: finishedUptime,
                           phyMode: "802.11ax", channel: WiFiChannel(band: "5 ГГц", number: 60, width: 40),
                           mcs: 11, transmitRateMbps: 573)
}

@MainActor private func waitForModulationCondition(timeout: Duration = .seconds(3),
                                                   _ predicate: () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !predicate(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    return predicate()
}
