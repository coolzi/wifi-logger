import Foundation
import Testing
@testable import WiFiLogger

@Test func captureBufferCoalescesWakeupsWithoutDiscardingSamples() async throws {
    let buffer = WiFiCaptureBuffer()
    for time in [1.0, 1.25, 1.5] {
        #expect(buffer.submit(sample(at: time)))
    }
    buffer.finish()

    var pendingWakeups = 0
    for await _ in buffer.updates { pendingWakeups += 1 }
    #expect(pendingWakeups == 1)
    let batch = try #require(buffer.drain())
    #expect(batch.samples.map(\.monotonicTime) == [1, 1.25, 1.5])
    #expect(batch.startsSegment)
    #expect(buffer.drain() == nil)
}

@Test func captureBufferClosesWithoutLosingAcceptedSamplesOrRestartingItsSegment() throws {
    let buffer = WiFiCaptureBuffer()
    #expect(buffer.submit(sample(at: 1)))
    let first = try #require(buffer.drain())
    #expect(first.startsSegment)

    #expect(buffer.submit(sample(at: 1.25)))
    buffer.finish()
    #expect(!buffer.isOpen)
    #expect(!buffer.submit(sample(at: 1.5)))

    let tail = try #require(buffer.drain())
    #expect(tail.samples.map(\.monotonicTime) == [1.25])
    #expect(!tail.startsSegment)
    #expect(buffer.drain() == nil)
}

private func sample(at time: TimeInterval) -> WiFiSample {
    WiFiSample(time: Date(timeIntervalSince1970: time), monotonicTime: time,
               state: .connected, measurements: WiFiMeasurements())
}
