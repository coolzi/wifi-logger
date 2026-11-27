import Darwin
import Foundation
import Testing

@testable import WiFiLogger

@Test func networkQualityDecodesCapacityAndRPMFromJSON() throws {
    let data = Data(#"{"dl_throughput":182500000,"ul_throughput":47100000,"responsiveness":689.5,"interface_name":"en0"}"#.utf8)

    let measurement = try WiFiNetworkQuality.parse(data)

    #expect(measurement.downloadMbps == 182.5)
    #expect(measurement.uploadMbps == 47.1)
    #expect(measurement.rpm == 689.5)
    #expect(throws: (any Error).self) {
        try WiFiNetworkQuality.parse(Data(#"{"dl_throughput":182500000}"#.utf8))
    }
}

@Test @MainActor func networkQualityMarksAnActiveSessionWithoutAddingRadioSamples() async throws {
    let recording = WiFiRecording()
    recording.toggle()
    let id = try #require(recording.requestNetworkQuality())
    #expect(recording.requestNetworkQuality() == nil)

    await recording.runNetworkQuality(id: id, interfaceName: { "en9" }) { interface, mark in
        #expect(interface == "en9")
        mark(WiFiNetworkQualityMarker(kind: .started))
        mark(WiFiNetworkQualityMarker(kind: .finished))
        return qualityMeasurement
    }

    let markers = recording.session.networkQualityMarkers
    #expect(markers.map(\.kind) == [.started, .finished])
    #expect(recording.visibleNetworkQualityMarkers == markers)
    #expect(recording.session.samples.isEmpty)
    let start = try #require(markers.first?.uptime)
    let end = try #require(markers.last?.uptime)
    #expect(recording.timelineUptimes == start...end)
    #expect(recording.networkQualityState == .measured(qualityMeasurement))
}

@Test(arguments: [false, true])
@MainActor func networkQualityDoesNotMarkAPausedOrResetSession(resets: Bool) async throws {
    let recording = WiFiRecording()
    recording.toggle()
    let id = try #require(recording.requestNetworkQuality())

    await recording.runNetworkQuality(id: id, interfaceName: { "en0" }) { _, mark in
        mark(WiFiNetworkQualityMarker(kind: .started))
        if resets { recording.restart() } else { recording.toggle() }
        mark(WiFiNetworkQualityMarker(kind: .finished))
        throw WiFiDiagnosticCommand.ReadError.commandFailed
    }

    #expect(recording.session.networkQualityMarkers.map(\.kind) == (resets ? [] : [.started]))
    #expect(recording.networkQualityState == .failed(.failed))
}

@Test @MainActor func networkQualityCanRunWithoutRecording() async throws {
    let recording = WiFiRecording()
    let id = try #require(recording.requestNetworkQuality())

    await recording.runNetworkQuality(id: id, interfaceName: { "en0" }) { _, mark in
        mark(WiFiNetworkQualityMarker(kind: .started))
        mark(WiFiNetworkQualityMarker(kind: .finished))
        return qualityMeasurement
    }

    #expect(recording.session.networkQualityMarkers.isEmpty)
    #expect(recording.networkQualityState == .measured(qualityMeasurement))
}

@Test @MainActor func networkQualityCannotRunWithoutAnInterface() async throws {
    let recording = WiFiRecording()
    recording.toggle()
    let id = try #require(recording.requestNetworkQuality())

    await recording.runNetworkQuality(id: id, interfaceName: { nil }) { _, _ in
        Issue.record("A network test started without a Wi-Fi interface")
        return qualityMeasurement
    }

    #expect(recording.session.networkQualityMarkers.isEmpty)
    #expect(recording.networkQualityState == .failed(.noInterface))
}

@Test @MainActor func networkQualityUsesProcessTimeWhenRecordingPausesBeforeTheUIConsumesAMarker() async throws {
    let recording = WiFiRecording()
    recording.toggle()
    let id = try #require(recording.requestNetworkQuality())

    await recording.runNetworkQuality(id: id, interfaceName: { "en0" }) { _, mark in
        mark(WiFiNetworkQualityMarker(kind: .started))
        mark(WiFiNetworkQualityMarker(kind: .finished))
        recording.toggle()
        return qualityMeasurement
    }

    #expect(!recording.isRecording)
    #expect(recording.session.networkQualityMarkers.map(\.kind) == [.started, .finished])
}

@Test @MainActor func networkQualityMarksTheSessionActiveWhenTheProcessStarts() async throws {
    let recording = WiFiRecording()
    recording.toggle()
    let id = try #require(recording.requestNetworkQuality())
    let originalSession = recording.session.id

    await recording.runNetworkQuality(id: id, interfaceName: { "en0" }) { _, mark in
        recording.restart()
        mark(WiFiNetworkQualityMarker(kind: .started))
        mark(WiFiNetworkQualityMarker(kind: .finished))
        return qualityMeasurement
    }

    #expect(recording.session.id != originalSession)
    #expect(recording.session.networkQualityMarkers.map(\.kind) == [.started, .finished])
}

@Test func cancellingADiagnosticCommandStopsAndReapsItsChild() throws {
    let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: pidFile) }
    let command = WiFiDiagnosticCommand(executablePath: "/bin/sh",
        arguments: ["-c", "printf '%s' \"$$\" > \"$1\"; exec /bin/sleep 30", "fixture", pidFile.path],
        timeout: .seconds(3), outputLimit: 1024)

    #expect(throws: CancellationError.self) {
        try command.capture(isCancelled: {
            guard let text = try? String(contentsOf: pidFile, encoding: .utf8) else { return false }
            return pid_t(text) != nil
        })
    }

    let pid = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8)))
    let result = waitpid(pid, nil, WNOHANG)
    let error = errno
    #expect(result == -1 && error == ECHILD)
}

private let qualityMeasurement = WiFiNetworkQuality(downloadMbps: 90, uploadMbps: 40, rpm: 500)
