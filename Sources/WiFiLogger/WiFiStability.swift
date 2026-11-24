import Foundation

struct WiFiOutageSummary {
    private(set) var count = 0
    private(set) var totalDuration: TimeInterval = 0
    private(set) var longestDuration: TimeInterval = 0
    private var currentDuration: TimeInterval = 0

    mutating func observe(_ sample: WiFiSample, after previous: WiFiSample?) {
        guard let previous, previous.state != .unknown, sample.state != .unknown else {
            currentDuration = 0
            return
        }
        if previous.state == .connected {
            currentDuration = 0
            if sample.state != .connected { count += 1 }
            return
        }

        let elapsed = sample.monotonicTime - previous.monotonicTime
        totalDuration += elapsed
        currentDuration += elapsed
        longestDuration = max(longestDuration, currentDuration)
        if sample.state == .connected { currentDuration = 0 }
    }
}

struct WiFiSignalVariation {
    let minimum: Int?
    let maximum: Int?
    let spread: Int?
    let change: Int?

    init(values: [Int] = [], change: Int? = nil) {
        minimum = values.min()
        maximum = values.max()
        if values.count > 1, let minimum, let maximum {
            spread = maximum - minimum
        } else {
            spread = nil
        }
        self.change = change
    }
}

struct WiFiSignalWindow {
    private var recentSamples: [WiFiSample] = []
    private(set) var rssiVariation = WiFiSignalVariation()
    private(set) var snrVariation = WiFiSignalVariation()

    mutating func observe(_ sample: WiFiSample, after previous: WiFiSample?) {
        if let last = recentSamples.last, sample.monotonicTime <= last.monotonicTime {
            // An invalid injected clock cannot bring already expired values back into the window.
            recentSamples.removeAll(keepingCapacity: true)
        }
        let cutoff = sample.monotonicTime - 60
        recentSamples.removeAll { $0.monotonicTime < cutoff }
        recentSamples.append(sample)
        rssiVariation = variation(for: \.signalDBm, at: sample, after: previous)
        snrVariation = variation(for: \.snrDB, at: sample, after: previous)
    }

    private func variation(for metric: KeyPath<WiFiMeasurements, Int?>,
                           at sample: WiFiSample, after previous: WiFiSample?) -> WiFiSignalVariation {
        let values = recentSamples.lazy.compactMap { $0.connectedMeasurements[keyPath: metric] }
        let change = sample.connectedMeasurements[keyPath: metric].flatMap { current in
            previous?.connectedMeasurements[keyPath: metric].map { current - $0 }
        }
        return WiFiSignalVariation(values: Array(values), change: change)
    }
}
