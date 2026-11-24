import os

final class WiFiCaptureBuffer: Sendable {
    struct Batch: Sendable {
        let samples: [WiFiSample]
        let startsSegment: Bool
    }

    private struct State: Sendable {
        var isOpen = true
        var samples: [WiFiSample] = []
        var startsSegment = true
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    let updates: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        // Only wakeups coalesce. Every accepted sample stays in the buffer until drained.
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    var isOpen: Bool { state.withLock { $0.isOpen } }

    func submit(_ sample: WiFiSample) -> Bool {
        let accepted = state.withLock { state in
            guard state.isOpen else { return false }
            state.samples.append(sample)
            return true
        }
        if accepted { continuation.yield(()) }
        return accepted
    }

    func drain() -> Batch? {
        state.withLock { state in
            guard !state.samples.isEmpty else { return nil }
            let batch = Batch(samples: state.samples, startsSegment: state.startsSegment)
            state.samples = []
            state.startsSegment = false
            return batch
        }
    }

    func finish() {
        state.withLock { $0.isOpen = false }
        continuation.finish()
    }
}
