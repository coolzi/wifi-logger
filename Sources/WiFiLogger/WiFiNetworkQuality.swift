import Foundation
import os

struct WiFiNetworkQuality: Equatable, Sendable {
    enum Failure: Error, Equatable {
        case noInterface
        case timedOut
        case failed
    }

    private struct Output: Decodable {
        let download: Double
        let upload: Double
        let responsiveness: Double

        enum CodingKeys: String, CodingKey {
            case download = "dl_throughput"
            case upload = "ul_throughput"
            case responsiveness
        }
    }

    private static let worker = DispatchQueue(label: "wifi-logger.network-quality", qos: .utility)
    private static let terminating = OSAllocatedUnfairLock(initialState: false)

    let downloadMbps: Double
    let uploadMbps: Double
    let rpm: Double

    static func parse(_ data: Data) throws -> Self {
        let output = try JSONDecoder().decode(Output.self, from: data)
        guard [output.download, output.upload, output.responsiveness].allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw Failure.failed
        }
        return Self(downloadMbps: output.download / 1_000_000, uploadMbps: output.upload / 1_000_000,
                    rpm: output.responsiveness)
    }

    static func measure(interfaceName: String, onMarker: @Sendable @escaping (WiFiNetworkQualityMarker) -> Void) async throws -> Self {
        let command = WiFiDiagnosticCommand(executablePath: "/usr/bin/networkQuality",
            arguments: ["-I", interfaceName, "-c"], timeout: .seconds(60), outputLimit: 256 * 1024)
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let result: Result<Self, Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                worker.async {
                    continuation.resume(returning: Result {
                        let data: Data
                        do {
                            var started = false
                            defer { if started { onMarker(WiFiNetworkQualityMarker(kind: .finished)) } }
                            data = try command.capture(isCancelled: { cancelled.withLock { $0 } || terminating.withLock { $0 } }) {
                                started = true
                                onMarker(WiFiNetworkQualityMarker(kind: .started))
                            }
                        }
                        return try parse(data)
                    })
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
        try Task.checkCancellation()
        return try result.get()
    }

    @MainActor static func finishBeforeTermination() {
        terminating.withLock { $0 = true }
        // Keep the app alive until the utility worker has reaped its process group leader.
        worker.sync {}
    }
}

enum WiFiNetworkQualityState: Equatable {
    case idle
    case running(UUID)
    case measured(WiFiNetworkQuality)
    case failed(WiFiNetworkQuality.Failure)

    var runID: UUID? {
        guard case .running(let id) = self else { return nil }
        return id
    }
}

struct WiFiNetworkQualityMarker: Identifiable, Equatable, Sendable {
    enum Kind: Sendable {
        case started
        case finished
    }

    let id = UUID()
    let kind: Kind
    let date = Date.now
    let uptime = WiFiMonotonicClock.now
}
