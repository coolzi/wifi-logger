import Foundation

@main
struct WiFiCaptureStall {
    @MainActor
    static func main() async {
        let recording = WiFiRecording()
        recording.toggle()
        guard let id = recording.captureID else { fail("Recording did not start.") }
        let capture = Task { await recording.capture(id: id) }
        defer { capture.cancel() }
        guard await waitForSamples(in: recording, after: 0) else { fail("No initial sample.") }

        let blockedAt = WiFiMonotonicClock.now
        blockMainActor()
        let releasedAt = WiFiMonotonicClock.now
        let snapshot = recording.snapshotForExport()
        let sampledWhileBlocked = snapshot.samples.filter {
            $0.monotonicTime > blockedAt && $0.monotonicTime < releasedAt
        }.count
        print("Samples in the active export from the 1.2 s MainActor stall: \(sampledWhileBlocked)")
        guard sampledWhileBlocked >= 3, recording.isRecording else { fail("Capture stalled with MainActor.") }

        guard await waitForSamples(in: recording, after: snapshot.samples.count) else {
            fail("Recording did not continue after taking the export snapshot.")
        }
        recording.toggle()
        let paused = recording.snapshotForExport()
        let acceptedTimes = paused.samples.map(\.monotonicTime)
        guard Array(acceptedTimes.prefix(snapshot.samples.count)) == snapshot.samples.map(\.monotonicTime),
              Set(paused.segmentIDs) == [0] else { fail("The paused recording lost rows or changed the first segment.") }
        try? await Task.sleep(for: .milliseconds(350))
        guard recording.session.samples.map(\.monotonicTime) == acceptedTimes else { fail("Samples arrived after pause.") }

        recording.toggle()
        guard let resumedID = recording.captureID else { fail("Recording did not resume.") }
        let resumed = Task { await recording.capture(id: resumedID) }
        defer { resumed.cancel() }
        guard await waitForSamples(in: recording, after: acceptedTimes.count),
              recording.session.segmentIDs.last == 1 else { fail("Resume did not start a new segment.") }
        blockMainActor()
        recording.restart()
        await resumed.value
        guard recording.snapshotForExport().samples.isEmpty else { fail("Queued samples survived a reset.") }
        print("Export prefix, pause, resume and reset passed.")
    }

    @MainActor
    private static func waitForSamples(in recording: WiFiRecording, after count: Int) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while recording.session.samples.count <= count, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return recording.session.samples.count > count
    }

    @MainActor
    private static func blockMainActor() {
        _ = DispatchSemaphore(value: 0).wait(timeout: .now() + .milliseconds(1200))
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
