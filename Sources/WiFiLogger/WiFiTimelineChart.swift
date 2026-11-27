import Charts
import SwiftUI

enum WiFiInspectionTime {
    static let locale: Locale = {
        var components = Locale.Components(locale: WiFiInterfaceLocale.current)
        components.hourCycle = .zeroToTwentyThree
        return Locale(components: components)
    }()
    static let calendarDate = Date.FormatStyle(date: .numeric, time: .omitted, locale: locale)
    static let clock = Date.FormatStyle(locale: locale)
        .hour(.twoDigits(amPM: .omitted))
        .minute(.twoDigits)
        .second(.twoDigits)
        .secondFraction(.fractional(3))

    static func timestamp(_ time: Date) -> String {
        "\(time.formatted(calendarDate)) \(time.formatted(clock))"
    }

    static func observation(_ time: Date, comparedTo selected: Date?) -> String? {
        guard let selected else { return timestamp(time) }
        guard time != selected else { return nil }
        return Calendar.current.isDate(time, inSameDayAs: selected) ? time.formatted(clock) : timestamp(time)
    }
}

enum WiFiChartLane: CaseIterable {
    case signalAndNoise, snr, channel, phyMode, transmitRate, gatewayRTT

    var trends: [WiFiTrend] {
        switch self {
        case .signalAndNoise: [.signal, .noise]
        case .snr: [.snr]
        case .channel: [.channel]
        case .phyMode: [.phyMode]
        case .transmitRate: [.transmitRate]
        case .gatewayRTT: [.gatewayRTT]
        }
    }

    var axisTitle: String {
        switch self {
        case .signalAndNoise: WiFiQualityMetric.rssi.unit
        case .snr: WiFiQualityMetric.snr.unit
        case .channel: String(localized: "Канал")
        case .phyMode: "Wi-Fi"
        case .transmitRate: String(localized: "Мбит/с")
        case .gatewayRTT: String(localized: "RTT, мс")
        }
    }

    var usesCategories: Bool { self == .channel || self == .phyMode }
}

struct WiFiChartScale {
    static let gridPositions = [0.0, 0.25, 0.5, 0.75, 1.0]

    let bounds: ClosedRange<Double>

    func position(of value: Double) -> Double {
        (value - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound)
    }

    func value(at position: Double) -> Double {
        bounds.lowerBound + (bounds.upperBound - bounds.lowerBound) * position
    }
}

struct WiFiGatewayChartPoint: Identifiable {
    let probe: WiFiGatewayProbe
    let milliseconds: Double
    let segment: Int
    let startsSegment: Bool

    var id: TimeInterval { probe.id }

    static func replies(in probes: [WiFiGatewayProbe]) -> [Self] {
        var points: [Self] = []
        var previous: WiFiGatewayProbe?
        var segment = 0
        for probe in probes {
            guard case .reply(let milliseconds) = probe.result else {
                previous = nil
                continue
            }
            let startsSegment = previous.map {
                let elapsed = probe.uptime - $0.uptime
                return probe.captureID != $0.captureID || elapsed <= 0 || elapsed > 1.5
            } ?? true
            if startsSegment { segment += 1 }
            points.append(Self(probe: probe, milliseconds: milliseconds, segment: segment,
                               startsSegment: startsSegment))
            previous = probe
        }
        return points
    }
}

struct WiFiTimelineObservation {
    enum Source {
        case radio(Int)
        case gateway(WiFiGatewayProbe)
    }

    let time: TimeInterval
    let date: Date
    let source: Source

    static func merged(_ radio: [Self], _ gateway: [Self]) -> [Self] {
        var result: [Self] = []
        result.reserveCapacity(radio.count + gateway.count)
        var radioIndex = 0
        var gatewayIndex = 0
        while radioIndex < radio.count, gatewayIndex < gateway.count {
            let sample = radio[radioIndex]
            let probe = gateway[gatewayIndex]
            if sample.time <= probe.time {
                result.append(sample)
                radioIndex += 1
                // Both readouts remain available at a shared position.
                if sample.time == probe.time { gatewayIndex += 1 }
            } else {
                result.append(probe)
                gatewayIndex += 1
            }
        }
        result.append(contentsOf: radio[radioIndex...])
        result.append(contentsOf: gateway[gatewayIndex...])
        return result
    }
}

struct WiFiTimelineChart: View, Equatable {
    struct Content: Equatable {
        let sessionID: UUID
        let window: WiFiChartWindow
        let selectedTime: TimeInterval?
        let inspectedAt: Date?
        let trends: Set<WiFiTrend>
        // A later sample can complete an outage that overlaps a fixed window.
        let lastOutage: ClosedRange<Int>?
        let networkQualityMarkers: [WiFiNetworkQualityMarker]
        let gatewayProbes: [WiFiGatewayProbe]
        let chartOrigin: TimeInterval

        init(session: WiFiSession, window: WiFiChartWindow, selectedIndex: Int?, trends: Set<WiFiTrend>,
             networkQualityMarkers: [WiFiNetworkQualityMarker] = [], gatewayProbes: [WiFiGatewayProbe] = [],
             chartOrigin: TimeInterval = 0, inspectedUptime: TimeInterval? = nil, inspectedAt: Date? = nil) {
            sessionID = session.id
            self.window = window
            self.trends = trends
            selectedTime = selectedIndex.map { session.chartTimes[$0] } ?? inspectedUptime.map { $0 - chartOrigin }
            self.inspectedAt = inspectedAt
            lastOutage = session.chartOutages(in: window.samples).last
            self.networkQualityMarkers = networkQualityMarkers
            self.gatewayProbes = trends.contains(.gatewayRTT) ? gatewayProbes : []
            self.chartOrigin = chartOrigin
        }
    }

    private struct Outage: Identifiable {
        let id: Int
        let start: TimeInterval
        let end: TimeInterval
    }

    private struct CategoryChange: Identifiable {
        let point: WiFiChartPoint
        let label: String
        let row: Double

        var id: Int { point.id }
    }

    let recording: WiFiRecording
    let content: Content

    static let height: CGFloat = 248
    static let clock = Date.FormatStyle(date: .omitted, time: .standard, locale: WiFiInspectionTime.locale)

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.recording === rhs.recording && lhs.content == rhs.content
    }

    var body: some View {
        if recording.session.id == content.sessionID {
            chart(in: recording.session)
        }
    }

    private func chart(in session: WiFiSession) -> some View {
        let window = content.window
        let range = window.samples
        let times = window.times
        let coordinates = range.map { index in
            WiFiTimelineObservation(time: session.chartTimes[index], date: session.samples[index].time, source: .radio(index))
        }
        let gatewayObservations = content.gatewayProbes.map { probe in
            WiFiTimelineObservation(time: probe.uptime - content.chartOrigin, date: probe.time, source: .gateway(probe))
        }
        let observations = WiFiTimelineObservation.merged(content.trends == [.gatewayRTT] ? [] : coordinates, gatewayObservations)
        let selectedIndex = content.selectedTime.flatMap { time -> Int? in
            guard let index = observations.nearestIndex(to: time, time: \.time), observations[index].time == time else { return nil }
            return index
        }
        let events = Array(session.chartEvents(in: range))
        let outages = session.chartOutages(in: range).map { outage in
            let start = max(times.lowerBound, session.chartTimes[outage.lowerBound])
            let end = min(outage.upperBound, range.upperBound - 1)
            return Outage(id: outage.lowerBound, start: start, end: session.chartTimes[end])
        }
        let leftTrends = WiFiChartLane.signalAndNoise.trends.filter(content.trends.contains)
        let rightLane = WiFiChartLane.allCases.first { lane in
            lane.trends.contains { WiFiTrend.rightAxisTrends.contains($0) && content.trends.contains($0) }
        }
        let rightTrend = rightLane?.trends.first
        let leftPoints = leftTrends.flatMap { session.points(for: $0, in: range) }
        let rightPoints: [WiFiChartPoint] = if let rightTrend, rightTrend != .gatewayRTT {
            session.points(for: rightTrend, in: range)
        } else { [] }
        let probes = content.gatewayProbes
        let replies = WiFiGatewayChartPoint.replies(in: probes)
        let timeouts = probes.filter { $0.result == .timeout }
        let leftScale = WiFiChartScale(bounds: numericBounds(leftPoints, default: -100 ... -40))
        let rightScale: WiFiChartScale? = rightLane.map { lane in
            switch lane {
            case .gatewayRTT:
                let maximum = replies.reduce(20.0) { max($0, $1.milliseconds) }
                return WiFiChartScale(bounds: 0 ... ((maximum / 20).rounded(.up) * 20))
            case .snr:
                return WiFiChartScale(bounds: numericBounds(rightPoints, default: 0 ... 40))
            default:
                return WiFiChartScale(bounds: numericBounds(rightPoints, default: 0 ... 100))
            }
        }
        let categoryTrends: [WiFiTrend] = [.channel, .phyMode].filter(content.trends.contains)
        let categoryRows = categoryTrends.indices.map { -0.07 - Double($0) * 0.12 }
        let categories = zip(categoryTrends, categoryRows).flatMap { trend, row in
            categoryChanges(in: session, trend: trend, range: range, row: row)
        }
        let yMin = categoryRows.last.map { $0 - 0.07 } ?? 0
        let timeTitle = String(localized: "Время")
        let eventTitle = String(localized: "Событие")
        let seriesTitle = String(localized: "Отрезок")
        let positionTitle = String(localized: "График")
        let clockAnchors = coordinates.isEmpty ? gatewayObservations : coordinates
        let firstMarker = content.networkQualityMarkers.first
        let showTimeout = !timeouts.isEmpty

        let plot = Chart {
            // Preserve a temporal axis in windows without a numeric reading.
            RuleMark(x: .value(timeTitle, times.lowerBound))
                .foregroundStyle(.clear)
                .accessibilityHidden(true)
            ForEach(outages) { outage in
                RectangleMark(xStart: .value(timeTitle, outage.start), xEnd: .value(timeTitle, outage.end),
                              yStart: .value(positionTitle, yMin), yEnd: .value(positionTitle, 1.0))
                    .foregroundStyle(.red.opacity(0.09))
                    .accessibilityHidden(true)
            }
            ForEach(events) { event in
                RuleMark(x: .value(eventTitle, coordinates[event.sampleIndex - range.lowerBound].time))
                    .foregroundStyle(event.kind.color.opacity(0.72))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .accessibilityHidden(true)
            }
            ForEach(content.networkQualityMarkers) { marker in
                let isStart = marker.kind == .started
                RuleMark(x: .value(eventTitle, marker.uptime - content.chartOrigin))
                    .foregroundStyle(Color.purple)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: isStart ? [5, 3] : []))
                    .annotation(position: .overlay, alignment: .top) {
                        Image(systemName: isStart ? "play.fill" : "stop.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.purple)
                            .offset(x: isStart ? -8 : 8)
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel(isStart ? Text("Начало проверки скорости Wi-Fi") : Text("Конец проверки скорости Wi-Fi"))
                    .accessibilityValue(marker.date.formatted(Self.clock))
            }
            radioMarks(leftPoints, scale: leftScale,
                       windowStart: range.lowerBound, coordinates: coordinates)
            if let rightScale {
                radioMarks(rightPoints, scale: rightScale,
                           windowStart: range.lowerBound, coordinates: coordinates)
                ForEach(replies) { point in
                    let time = point.probe.uptime - content.chartOrigin
                    let y = rightScale.position(of: point.milliseconds)
                    LineMark(x: .value(timeTitle, time), y: .value(positionTitle, y),
                             series: .value(seriesTitle, -point.segment))
                        .foregroundStyle(WiFiTrend.gatewayRTT.color)
                        .lineStyle(WiFiTrend.gatewayRTT.stroke)
                    if point.startsSegment || time == content.selectedTime {
                        PointMark(x: .value(timeTitle, time), y: .value(positionTitle, y))
                            .foregroundStyle(WiFiTrend.gatewayRTT.color)
                            .symbolSize(time == content.selectedTime ? 36 : 13)
                            .accessibilityHidden(true)
                    }
                }
            }
            ForEach(timeouts) { probe in
                let time = probe.uptime - content.chartOrigin
                RuleMark(x: .value(timeTitle, time),
                         yStart: .value(positionTitle, 0.0), yEnd: .value(positionTitle, 0.08))
                    .foregroundStyle(Color.red)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                    .accessibilityLabel(probe.time.formatted(Self.clock))
                    .accessibilityValue(probe.result.displayLabel)
            }
            ForEach(categories) { change in
                let time = coordinates[change.point.sampleIndex - range.lowerBound].time
                PointMark(x: .value(timeTitle, time), y: .value(positionTitle, change.row))
                    .foregroundStyle(change.point.trend.color)
                    .symbol(.square)
                    .symbolSize(time == content.selectedTime ? 34 : 19)
                    .accessibilityLabel(change.point.trend.label + ", " + change.point.time.formatted(Self.clock))
                    .accessibilityValue(change.label)
            }
            if let time = content.selectedTime, times.contains(time) {
                RuleMark(x: .value(String(localized: "Выбранный замер"), time))
                    .foregroundStyle(.primary.opacity(0.72))
                    .accessibilityHidden(true)
            }
        }
        .chartXScale(domain: times, range: .plotDimension(padding: 0))
        .chartYScale(domain: yMin ... 1)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { mark in
                AxisGridLine()
                if let time = mark.as(Double.self) {
                    if let index = clockAnchors.nearestIndex(to: time, time: \.time) {
                        let sample = clockAnchors[index]
                        AxisValueLabel { Text(sample.date.addingTimeInterval(time - sample.time), format: Self.clock) }
                    } else if let marker = firstMarker {
                        let offset = time - (marker.uptime - content.chartOrigin)
                        AxisValueLabel { Text(marker.date.addingTimeInterval(offset), format: Self.clock) }
                    }
                }
            }
        }
        .chartYAxis {
            if !leftTrends.isEmpty || rightScale != nil {
                AxisMarks(position: .leading, values: WiFiChartScale.gridPositions) { mark in
                    AxisGridLine()
                    if !leftTrends.isEmpty, let position = mark.as(Double.self) {
                        AxisValueLabel { axisNumber(leftScale.value(at: position), color: .secondary) }
                    }
                }
            }
            if let rightScale, let rightTrend {
                AxisMarks(position: .trailing, values: WiFiChartScale.gridPositions) { mark in
                    if let position = mark.as(Double.self) {
                        AxisValueLabel { axisNumber(rightScale.value(at: position), color: rightTrend.color) }
                    }
                }
            }
            if !categoryRows.isEmpty {
                AxisMarks(position: .leading, values: categoryRows) { mark in
                    AxisGridLine()
                    if let value = mark.as(Double.self), let index = categoryRows.firstIndex(of: value) {
                        AxisValueLabel { Text(categoryTrends[index].label).font(.caption2) }
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { tap in
                        guard let anchor = proxy.plotFrame else { return }
                        let frame = geometry[anchor]
                        guard let x = Self.plotX(at: tap.location, in: frame),
                              let time = proxy.value(atX: x, as: Double.self) else { return }
                        // The denser radio samples can occupy the same screen column as an RTT mark.
                        if let rightScale, !probes.isEmpty {
                            let point = CGPoint(x: x, y: tap.location.y - frame.minY)
                            let radioDistance = coordinates.nearestIndex(to: time, time: \.time).map { index in
                                let sample = coordinates[index]
                                let sampleIndex = index + range.lowerBound
                                guard let sampleX = proxy.position(forX: sample.time) else { return CGFloat(7) }
                                let left = Self.radioDistance(in: leftPoints, at: sampleIndex, scale: leftScale,
                                    dx: sampleX - x, y: { proxy.position(forY: $0).map { $0 - point.y } })
                                let right = Self.radioDistance(in: rightPoints, at: sampleIndex, scale: rightScale,
                                    dx: sampleX - x, y: { proxy.position(forY: $0).map { $0 - point.y } })
                                return min(left, right)
                            } ?? 7
                            if let probe = Self.gatewayHit(in: probes, at: point, scale: rightScale,
                                                          closerThan: radioDistance,
                                                          x: { proxy.position(forX: $0 - content.chartOrigin) },
                                                          y: { proxy.position(forY: $0) }) {
                                select(WiFiTimelineObservation(time: probe.uptime - content.chartOrigin,
                                                               date: probe.time, source: .gateway(probe)))
                                return
                            }
                        }
                        guard let index = observations.nearestIndex(to: time, time: \.time) else { return }
                        select(observations[index])
                    })
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            if leftPoints.isEmpty, rightPoints.isEmpty, replies.isEmpty, categories.isEmpty, !showTimeout {
                Text("Нет значений для этого графика за выбранный период")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(.regularMaterial, in: .rect(cornerRadius: 5))
                    .allowsHitTesting(false)
            }
        }

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if !leftTrends.isEmpty {
                    let names = leftTrends.map { $0 == .signal ? "RSSI" : $0.label }.joined(separator: " · ")
                    Text("\(names), \(WiFiChartLane.signalAndNoise.axisTitle)")
                }
                Spacer()
                if showTimeout {
                    Label("Шлюз не ответил", systemImage: "line.vertical")
                }
                if let rightLane, let rightTrend {
                    Text(rightLane == .snr ? String(localized: "SNR, дБ") : rightLane.axisTitle)
                        .foregroundStyle(rightTrend.color)
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(minHeight: 16)
            // Replace the generated chart labels, which use coordinates from a 0...1 scale.
            VStack {
                plot.accessibilityRepresentation {
                    VStack {
                        ForEach(content.networkQualityMarkers) { marker in
                            let isStart = marker.kind == .started
                            Text(isStart ? "Начало проверки скорости Wi-Fi" : "Конец проверки скорости Wi-Fi")
                                .accessibilityValue(WiFiInspectionTime.timestamp(marker.date))
                        }
                        ForEach(timeouts) { probe in
                            Text("Шлюз не ответил").accessibilityValue(WiFiInspectionTime.timestamp(probe.time))
                        }
                        ForEach(categories) { change in
                            Text(change.point.trend.label + " · " + change.label)
                                .accessibilityValue(WiFiInspectionTime.timestamp(change.point.time))
                        }
                    }
                }
            }
                .wifiChartSelection(String(localized: "График"), in: observations.indices,
                                    selectedIndex: selectedIndex, cursorTime: content.selectedTime,
                                    cursorDate: content.inspectedAt, timeOf: { observations[$0].time },
                                    date: { observations[$0].date }, onSelect: { select(observations[$0]) })
        }
    }

    @ChartContentBuilder
    private func radioMarks(_ points: [WiFiChartPoint], scale: WiFiChartScale,
                            windowStart: Int, coordinates: [WiFiTimelineObservation]) -> some ChartContent {
        let timeTitle = String(localized: "Время")
        let seriesTitle = String(localized: "Отрезок")
        let positionTitle = String(localized: "График")
        ForEach(points) { point in
            if case .number(let value) = point.value {
                let time = coordinates[point.sampleIndex - windowStart].time
                let y = scale.position(of: value)
                LineMark(x: .value(timeTitle, time), y: .value(positionTitle, y), series: .value(seriesTitle, point.seriesID))
                    .foregroundStyle(point.trend.color)
                    .lineStyle(point.trend.stroke)
                if point.sampleIndex == point.segment || time == content.selectedTime {
                    PointMark(x: .value(timeTitle, time), y: .value(positionTitle, y))
                        .foregroundStyle(point.trend.color)
                        .symbolSize(time == content.selectedTime ? 36 : 13)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func categoryChanges(in session: WiFiSession, trend: WiFiTrend, range: Range<Int>, row: Double) -> [CategoryChange] {
        var previous: WiFiChartPoint?
        return session.points(for: trend, in: range).compactMap { point in
            defer { previous = point }
            guard previous?.value != point.value || previous?.segment != point.segment,
                  case .category(let rawLabel) = point.value else { return nil }
            let channel = trend == .channel ? session.samples[point.sampleIndex].measurements.channel : nil
            return CategoryChange(point: point, label: channel?.displayChartLabel ?? rawLabel, row: row)
        }
    }

    private func numericBounds(_ points: [WiFiChartPoint], default initial: ClosedRange<Double>) -> ClosedRange<Double> {
        points.reduce(initial) { bounds, point in
            guard case .number(let value) = point.value else { return bounds }
            return min(bounds.lowerBound, value) ... max(bounds.upperBound, value)
        }
    }

    private func axisNumber(_ value: Double, color: Color) -> some View {
        Text(value.formatted(.number.precision(.fractionLength(0...2))))
            .font(.caption.monospacedDigit())
            .foregroundStyle(color)
    }

    private func select(_ observation: WiFiTimelineObservation) {
        guard recording.session.id == content.sessionID else { return }
        switch observation.source {
        case .radio(let index): recording.selectRadioSample(index)
        case .gateway(let probe): recording.selectGatewayProbe(probe)
        }
    }

    nonisolated static func radioDistance(in points: [WiFiChartPoint], at sampleIndex: Int, scale: WiFiChartScale,
                                         dx: CGFloat, y: (Double) -> CGFloat?) -> CGFloat {
        points.reduce(7) { distance, point in
            guard point.sampleIndex == sampleIndex, case .number(let value) = point.value,
                  let dy = y(scale.position(of: value)) else { return distance }
            return min(distance, hypot(dx, dy))
        }
    }

    nonisolated static func gatewayHit(in probes: [WiFiGatewayProbe], at point: CGPoint, scale: WiFiChartScale,
                                       closerThan radioDistance: CGFloat = 7,
                                       x: (TimeInterval) -> CGFloat?, y: (Double) -> CGFloat?) -> WiFiGatewayProbe? {
        var best: (probe: WiFiGatewayProbe, distance: CGFloat)?
        for probe in probes {
            guard let probeX = x(probe.uptime) else { continue }
            let dx = abs(probeX - point.x)
            guard dx <= 1.5 else { continue }
            let targetY: CGFloat
            switch probe.result {
            case .reply(let rtt):
                guard let position = y(scale.position(of: rtt)) else { continue }
                targetY = position
            case .timeout:
                guard let start = y(0), let end = y(0.08) else { continue }
                targetY = min(max(point.y, min(start, end)), max(start, end))
            case .unavailable:
                continue
            }
            let distance = hypot(dx, targetY - point.y)
            if distance < min(radioDistance, best?.distance ?? 7) { best = (probe, distance) }
        }
        return best?.probe
    }

    nonisolated static func plotX(at location: CGPoint, in frame: CGRect) -> CGFloat? {
        guard frame.width > 0, frame.height > 0,
              (frame.minX ... frame.maxX).contains(location.x),
              (frame.minY ... frame.maxY).contains(location.y) else { return nil }
        // Keep the rightmost click inside ChartProxy's x scale.
        return min(location.x - frame.minX, frame.width.nextDown)
    }
}

enum WiFiChartSelectionStep {
    case previous, next

    func target<Indices: RandomAccessCollection>(in indices: Indices, from time: TimeInterval,
                                                  timeOf: (Int) -> TimeInterval) -> Int?
        where Indices.Index == Int, Indices.Element == Int {
        switch self {
        case .previous:
            let position = indices.partitionIndex { timeOf($0) >= time }
            return position > indices.startIndex ? indices[position - 1] : nil
        case .next:
            let position = indices.partitionIndex { timeOf($0) > time }
            return position < indices.endIndex ? indices[position] : nil
        }
    }

    func target<Indices: RandomAccessCollection>(in indices: Indices, from selectedIndex: Int?) -> Int?
        where Indices.Index == Int, Indices.Element == Int {
        guard let selectedIndex else { return indices.last }
        switch self {
        case .previous:
            let position = indices.partitionIndex { $0 >= selectedIndex }
            return position > indices.startIndex ? indices[position - 1] : nil
        case .next:
            let position = indices.partitionIndex { $0 > selectedIndex }
            return position < indices.endIndex ? indices[position] : nil
        }
    }
}

struct WiFiChartSelectionLabels {
    let show: String
    let showLast: String
    let displayedItem: String
    let lastItem: String
    let previous: String
    let next: String

    static let radioSample = Self(
        show: String(localized: "Показать замер"), showLast: String(localized: "Показать последний замер"),
        displayedItem: String(localized: "Показанный замер"), lastItem: String(localized: "Последний замер"),
        previous: String(localized: "Предыдущий замер"), next: String(localized: "Следующий замер")
    )
    static let modulationSnapshot = Self(
        show: String(localized: "Показать снимок"), showLast: String(localized: "Показать последний снимок"),
        displayedItem: String(localized: "Ответ по снимку"), lastItem: String(localized: "Последний снимок"),
        previous: String(localized: "Предыдущий снимок"), next: String(localized: "Следующий снимок")
    )
    static let spatialStreams = Self(
        show: String(localized: "Показать значение NSS"), showLast: String(localized: "Показать последнее значение NSS"),
        displayedItem: String(localized: "Ответ NSS"), lastItem: String(localized: "Последнее показание NSS"),
        previous: String(localized: "Предыдущее показание NSS"), next: String(localized: "Следующее показание NSS")
    )
}

extension View {
    @ViewBuilder func wifiChartSelection<Indices: RandomAccessCollection>(
        _ title: String, in indices: Indices, selectedIndex: Int?, cursorTime: TimeInterval? = nil,
        cursorDate: Date? = nil, timeOf: ((Int) -> TimeInterval)? = nil, date: (Int) -> Date,
        labels: WiFiChartSelectionLabels = .radioSample,
        onSelect: @escaping (Int) -> Void
    ) -> some View where Indices.Index == Int, Indices.Element == Int {
        if let last = indices.last {
            let selected = selectedIndex.flatMap { indices.contains($0) ? $0 : nil }
            let current = if let cursorTime, let timeOf, selected == nil {
                WiFiChartSelectionStep.previous.target(in: indices, from: cursorTime, timeOf: timeOf)
                    ?? WiFiChartSelectionStep.next.target(in: indices, from: cursorTime, timeOf: timeOf) ?? last
            } else {
                selected ?? last
            }
            let time = date(current).formatted(.dateTime.year().month().day()
                .hour().minute().second().secondFraction(.fractional(3)).locale(WiFiInspectionTime.locale))
            let selectionDescription = if let cursorDate {
                String(localized: "Выбранный момент · \(WiFiInspectionTime.timestamp(cursorDate))")
            } else if selected != nil {
                String(localized: "\(labels.displayedItem) в \(time)")
            } else if selectedIndex != nil || cursorTime != nil {
                String(localized: "В выбранный момент нет точки на этом графике")
            } else {
                String(localized: "\(labels.lastItem) в \(time)")
            }
            let step: (WiFiChartSelectionStep) -> Void = { direction in
                let target = if let cursorTime, let timeOf, selected == nil {
                    direction.target(in: indices, from: cursorTime, timeOf: timeOf)
                } else {
                    direction.target(in: indices, from: selectedIndex)
                }
                if let target { onSelect(target) }
            }
            self
                .focusable(interactions: .edit)
                .onKeyPress(.leftArrow, phases: [.down, .repeat]) { _ in
                    step(.previous)
                    return .handled
                }
                .onKeyPress(.rightArrow, phases: [.down, .repeat]) { _ in
                    step(.next)
                    return .handled
                }
                .onKeyPress(.return) {
                    onSelect(current)
                    return .handled
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(title)
                .accessibilityValue(selectionDescription)
                .accessibilityAction(named: Text(selected == nil && cursorTime == nil ? labels.showLast : labels.show)) {
                    onSelect(current)
                }
                .accessibilityAction(named: Text(labels.previous)) { step(.previous) }
                .accessibilityAction(named: Text(labels.next)) { step(.next) }
        } else {
            self.accessibilityLabel(title)
        }
    }
}

extension WiFiTrend {
    var label: String {
        switch self {
        case .signal: String(localized: "Сигнал")
        case .noise: String(localized: "Шум")
        case .channel: String(localized: "Канал")
        case .phyMode: String(localized: "Режим")
        case .transmitRate: String(localized: "Скорость передачи")
        case .snr: "SNR"
        case .gatewayRTT: String(localized: "RTT до шлюза")
        }
    }

    var color: Color {
        switch self {
        case .signal: .teal
        case .noise: .secondary
        case .channel: .blue
        case .phyMode: .purple
        case .transmitRate: .blue
        case .snr: .orange
        case .gatewayRTT: .purple
        }
    }
    var qualityMetric: WiFiQualityMetric? {
        switch self {
        case .signal: .rssi
        case .noise: .noise
        case .snr: .snr
        default: nil
        }
    }
    var stroke: StrokeStyle {
        self == .noise ? StrokeStyle(lineWidth: 1.5, dash: [4, 4]) : StrokeStyle(lineWidth: 2)
    }
}

extension WiFiEventKind {
    var title: String {
        switch self {
        case .disconnected: String(localized: "Связь прервалась")
        case .reconnected: String(localized: "Связь восстановилась")
        case .accessPointChanged: String(localized: "Смена точки доступа")
        case .channelChanged: String(localized: "Изменились параметры канала")
        }
    }

    var color: Color {
        switch self {
        case .disconnected: .red
        case .reconnected: .green
        case .accessPointChanged: .orange
        case .channelChanged: .blue
        }
    }

    var icon: String {
        switch self {
        case .disconnected: "wifi.slash"
        case .reconnected: "wifi"
        case .accessPointChanged: "arrow.left.arrow.right"
        case .channelChanged: "antenna.radiowaves.left.and.right"
        }
    }
}
