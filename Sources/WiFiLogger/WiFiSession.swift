import Foundation

enum WiFiEventKind: Int, CaseIterable {
    case disconnected
    case reconnected
    case accessPointChanged
    case channelChanged
}

struct WiFiEvent: Identifiable {
    var id: Int { sampleIndex * WiFiEventKind.allCases.count + kind.rawValue }
    let sampleIndex: Int
    let kind: WiFiEventKind
    var duration: TimeInterval? = nil
}

enum WiFiTrend: Int, CaseIterable {
    case signal
    case noise
    case channel
    case phyMode
    case transmitRate
    case snr

    func value(in sample: WiFiSample) -> WiFiChartValue? {
        let fields = sample.connectedMeasurements
        switch self {
        case .signal: return fields.signalDBm.map { .number(Double($0)) }
        case .noise: return fields.noiseDBm.map { .number(Double($0)) }
        case .channel: return fields.channel?.chartLabel.map(WiFiChartValue.category)
        case .phyMode: return fields.wifiGenerationLabel.map(WiFiChartValue.category)
        case .transmitRate: return fields.transmitRateMbps.map(WiFiChartValue.number)
        case .snr: return fields.snrDB.map { .number(Double($0)) }
        }
    }
}

enum WiFiChartValue: Equatable {
    case number(Double)
    case category(String)
}

struct WiFiChartPoint: Identifiable {
    var id: Int { sampleIndex * WiFiTrend.allCases.count + trend.rawValue }
    var seriesID: Int { segment * WiFiTrend.allCases.count + trend.rawValue }
    let sampleIndex: Int
    let time: Date
    let trend: WiFiTrend
    let value: WiFiChartValue
    let segment: Int
}

enum WiFiChartSpan: Int, CaseIterable {
    case thirtySeconds = 30
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900

    var seconds: TimeInterval { Double(rawValue) }

    var label: String {
        switch self {
        case .thirtySeconds: String(localized: "30 с")
        case .oneMinute: String(localized: "1 мин")
        case .fiveMinutes: String(localized: "5 мин")
        case .fifteenMinutes: String(localized: "15 мин")
        }
    }
}

struct WiFiChartWindow: Equatable {
    let samples: Range<Int>
    let times: ClosedRange<TimeInterval>
}

struct WiFiSession {
    let id = UUID()
    private(set) var samples: [WiFiSample] = []
    private(set) var segmentIDs: [Int] = []
    private(set) var events: [WiFiEvent] = []
    private(set) var outages = WiFiOutageSummary()
    private(set) var chartTimes: [TimeInterval] = []
    private var shadedOutages: [ClosedRange<Int>] = []
    private var signalWindow = WiFiSignalWindow()
    private var outageStart: Int?
    private var outageCalendarIsContinuous = true

    var rssiVariation: WiFiSignalVariation { signalWindow.rssiVariation }
    var snrVariation: WiFiSignalVariation { signalWindow.snrVariation }

    func chartEndIndex(atOrBefore time: TimeInterval) -> Int? {
        let next = chartTimes.partitionIndex { $0 > time }
        return next == 0 ? nil : next - 1
    }

    func nextChartEnd(after endIndex: Int, span: WiFiChartSpan) -> Int? {
        guard chartTimes.indices.contains(endIndex + 1) else { return nil }
        let target = chartTimes[endIndex] + span.seconds
        return max(endIndex + 1, chartEndIndex(atOrBefore: target) ?? endIndex)
    }

    func points(for trend: WiFiTrend, in range: Range<Int>? = nil) -> [WiFiChartPoint] {
        let range = range ?? samples.indices
        var points: [WiFiChartPoint] = []
        var segment = range.lowerBound
        var followsValue = false
        for index in range {
            let sample = samples[index]
            let value = trend.value(in: sample)
            if let value {
                if !followsValue || segmentIDs[index] != segmentIDs[index - 1]
                    || !calendarIsContinuous(from: samples[index - 1], to: sample) {
                    segment = index
                }
                points.append(WiFiChartPoint(sampleIndex: index, time: sample.time, trend: trend,
                                             value: value, segment: segment))
            }
            followsValue = value != nil
        }
        return points
    }

    func chartEvents(in range: Range<Int>) -> ArraySlice<WiFiEvent> {
        let first = events.partitionIndex { $0.sampleIndex >= range.lowerBound }
        return events[first...].prefix { $0.sampleIndex < range.upperBound }
    }

    func chartOutages(in range: Range<Int>) -> ArraySlice<ClosedRange<Int>> {
        guard !range.isEmpty else { return [] }
        let first = shadedOutages.partitionIndex { $0.upperBound >= range.lowerBound }
        return shadedOutages[first...].prefix { $0.lowerBound < range.upperBound }
    }

    func sampleIndex(nearest time: TimeInterval, in range: Range<Int>) -> Int? {
        chartTimes[range].nearestIndex(to: time) { $0 }
    }

    mutating func append(contentsOf samples: [WiFiSample], startsSegment: Bool) {
        for (index, sample) in samples.enumerated() {
            append(sample, startsSegment: index == 0 && startsSegment)
        }
    }

    mutating func append(_ sample: WiFiSample, startsSegment: Bool = false) {
        let index = samples.count
        let last = samples.last
        let elapsed = last.map { sample.monotonicTime - $0.monotonicTime } ?? 0
        // A resumed or delayed timer cannot tell us what happened during the gap.
        let previous = !startsSegment && elapsed > 0 && elapsed <= 2.5 ? last : nil
        let segment = segmentIDs.last.map { previous == nil ? $0 + 1 : $0 } ?? 0
        segmentIDs.append(segment)
        // Keep projected positions ordered even when a synthetic sample resets the clock.
        let chartStep = elapsed.isFinite && elapsed > 0 ? elapsed : 1
        chartTimes.append(chartTimes.last.map { $0 + chartStep } ?? 0)
        samples.append(sample)
        outages.observe(sample, after: previous)
        signalWindow.observe(sample, after: previous)
        recordEvents(for: sample, after: previous, at: index)
    }

    private mutating func recordEvents(for sample: WiFiSample, after previous: WiFiSample?, at index: Int) {
        guard let previous, previous.state != .unknown, sample.state != .unknown else {
            outageStart = nil
            return
        }
        if !calendarIsContinuous(from: previous, to: sample) { outageCalendarIsContinuous = false }
        switch (previous.state, sample.state) {
        case (.connected, .disconnected), (.connected, .poweredOff):
            outageStart = index
            outageCalendarIsContinuous = true
            events.append(WiFiEvent(sampleIndex: index, kind: .disconnected))
        case (.disconnected, .connected), (.poweredOff, .connected):
            let duration = outageStart.map { sample.monotonicTime - samples[$0].monotonicTime }
            if let outageStart, outageCalendarIsContinuous {
                shadedOutages.append(outageStart ... index)
            }
            outageStart = nil
            events.append(WiFiEvent(sampleIndex: index, kind: .reconnected, duration: duration))
        case (.connected, .connected):
            let before = previous.measurements
            let after = sample.measurements
            if let ssidData = before.ssidData, ssidData == after.ssidData,
               let oldBSSID = before.bssid, let newBSSID = after.bssid, oldBSSID != newBSSID {
                events.append(WiFiEvent(sampleIndex: index, kind: .accessPointChanged))
            }
            if let oldChannel = before.channel, let newChannel = after.channel,
               newChannel.hasChanged(from: oldChannel) {
                events.append(WiFiEvent(sampleIndex: index, kind: .channelChanged))
            }
        default: break
        }
    }

    private func calendarIsContinuous(from previous: WiFiSample, to sample: WiFiSample) -> Bool {
        let elapsed = sample.time.timeIntervalSince(previous.time)
        return elapsed > 0 && elapsed <= 2.5
    }
}

extension RandomAccessCollection where Index == Int {
    // The collection must be ordered by time. At equal distance, prefer the earlier point.
    func nearestIndex(to target: TimeInterval, time: (Element) -> TimeInterval) -> Int? {
        guard !isEmpty else { return nil }
        let right = partitionIndex { time($0) >= target }
        if right == startIndex { return right }
        if right == endIndex { return right - 1 }
        let leftDistance = target - time(self[right - 1])
        let rightDistance = time(self[right]) - target
        return leftDistance <= rightDistance ? right - 1 : right
    }

    // The predicate must be false before the boundary and true at and after it.
    func partitionIndex(where isAtOrAfterBoundary: (Element) -> Bool) -> Int {
        var lower = startIndex
        var upper = endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if isAtOrAfterBoundary(self[middle]) {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        return lower
    }
}
