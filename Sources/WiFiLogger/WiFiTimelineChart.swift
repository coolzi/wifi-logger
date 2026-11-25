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

enum WiFiChartMode: CaseIterable {
    case signalAndNoise, snr, channel, phyMode, transmitRate

    var title: String {
        switch self {
        case .signalAndNoise: String(localized: "Сигнал и шум")
        case .snr: "SNR"
        case .channel: String(localized: "Канал")
        case .phyMode: String(localized: "Режим")
        case .transmitRate: String(localized: "Скорость")
        }
    }

    var trends: [WiFiTrend] {
        switch self {
        case .signalAndNoise: [.signal, .noise]
        case .snr: [.snr]
        case .channel: [.channel]
        case .phyMode: [.phyMode]
        case .transmitRate: [.transmitRate]
        }
    }

    var axisTitle: String {
        switch self {
        case .signalAndNoise: WiFiQualityMetric.rssi.unit
        case .snr: WiFiQualityMetric.snr.unit
        case .channel: String(localized: "Канал")
        case .phyMode: "Wi-Fi"
        case .transmitRate: String(localized: "Мбит/с")
        }
    }

    var usesCategories: Bool { self == .channel || self == .phyMode }
}

struct WiFiTimelineChart: View, Equatable {
    struct Content: Equatable {
        let sessionID: UUID
        let window: WiFiChartWindow
        let selectedIndex: Int?
        let mode: WiFiChartMode
        // A later sample can complete an outage that overlaps a fixed window.
        let lastOutage: ClosedRange<Int>?

        init(session: WiFiSession, window: WiFiChartWindow, selectedIndex: Int?, mode: WiFiChartMode) {
            sessionID = session.id
            self.window = window
            self.selectedIndex = selectedIndex
            self.mode = mode
            lastOutage = session.chartOutages(in: window.samples).last
        }
    }

    private struct Outage: Identifiable {
        let id: Int
        let start: TimeInterval
        let end: TimeInterval
    }

    let recording: WiFiRecording
    let content: Content

    static let clock = Date.FormatStyle(date: .omitted, time: .standard, locale: WiFiInspectionTime.locale)

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.recording === rhs.recording && lhs.content == rhs.content
    }

    var body: some View {
        if recording.session.id == content.sessionID {
            chart(in: recording.session)
        }
    }

    private var mode: WiFiChartMode { content.mode }

    private func chart(in session: WiFiSession) -> some View {
        let window = content.window
        let range = window.samples
        let times = window.times
        let coordinates = range.map { (time: session.chartTimes[$0], date: session.samples[$0].time) }
        func observation(at index: Int) -> (time: TimeInterval, date: Date) {
            coordinates[index - range.lowerBound]
        }
        let events = Array(session.chartEvents(in: range))
        let outages = session.chartOutages(in: range).map { outage in
            let start = max(times.lowerBound, session.chartTimes[outage.lowerBound])
            let end = min(outage.upperBound, range.upperBound - 1)
            return Outage(id: outage.lowerBound, start: start, end: session.chartTimes[end])
        }
        let points = mode.trends.flatMap { session.points(for: $0, in: range) }
        let categoryLabels = points.reduce(into: [String: String]()) { labels, point in
            guard case .category(let category) = point.value, labels[category] == nil else { return }
            let channel = point.trend == .channel ? session.samples[point.sampleIndex].measurements.channel : nil
            labels[category] = channel?.displayChartLabel ?? category
        }
        let categories = categoryLabels.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let positions = Dictionary(uniqueKeysWithValues: categories.enumerated().map { (index, label) in
            (label, Double(index))
        })
        let bounds = valueBounds(points: points, categoryCount: categories.count)
        let selectedIndex = content.selectedIndex
        let timeTitle = String(localized: "Время")
        let seriesTitle = String(localized: "Отрезок")
        let eventTitle = String(localized: "Событие")
        let outageStartTitle = String(localized: "Начало разрыва")
        let outageEndTitle = String(localized: "Конец разрыва")
        let axisTitle = mode.axisTitle
        let trendTitles = Dictionary(uniqueKeysWithValues: mode.trends.map { ($0, $0.label) })
        let qualityStyles: [WiFiTrend: AnyShapeStyle] = [
            .signal: AnyShapeStyle(WiFiQualityMetric.rssi.gradient(in: bounds)),
            .noise: AnyShapeStyle(WiFiQualityMetric.noise.gradient(in: bounds)),
            .snr: AnyShapeStyle(WiFiQualityMetric.snr.gradient(in: bounds)),
        ]
        return Chart {
            if points.isEmpty {
                // An empty series still needs a temporal scale for selecting recorded samples.
                RuleMark(x: .value(timeTitle, times.lowerBound))
                    .foregroundStyle(.clear)
                    .accessibilityHidden(true)
            }
            ForEach(outages) { outage in
                RectangleMark(xStart: .value(outageStartTitle, outage.start),
                              xEnd: .value(outageEndTitle, outage.end),
                              yStart: .value(axisTitle, bounds.lowerBound),
                              yEnd: .value(axisTitle, bounds.upperBound))
                    .foregroundStyle(.red.opacity(0.09))
                    .accessibilityHidden(true)
            }
            ForEach(events) { event in
                RuleMark(x: .value(eventTitle, observation(at: event.sampleIndex).time))
                    .foregroundStyle(event.kind.color.opacity(0.72))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .accessibilityHidden(true)
            }
            ForEach(points) { point in
                if let value = coordinate(of: point.value, categoryPositions: positions) {
                    let time = observation(at: point.sampleIndex).time
                    LineMark(x: .value(timeTitle, time), y: .value(axisTitle, value),
                             series: .value(seriesTitle, point.seriesID))
                        .foregroundStyle(qualityStyles[point.trend] ?? AnyShapeStyle(point.trend.color))
                        .alignsMarkStylesWithPlotArea()
                        .lineStyle(point.trend.stroke)
                        .interpolationMethod(mode.usesCategories ? .stepEnd : .linear)
                        .accessibilityLabel((trendTitles[point.trend] ?? "") + ", " + point.time.formatted(Self.clock))
                        .accessibilityValue(accessibleValue(point.value, axisTitle: axisTitle, categoryLabels: categoryLabels))
                    if point.sampleIndex == point.segment {
                        PointMark(x: .value(timeTitle, time), y: .value(axisTitle, value))
                            .foregroundStyle(point.trend.qualityMetric?.quality(for: value)?.color ?? point.trend.color)
                            .symbolSize(13)
                            .accessibilityHidden(true)
                    }
                }
            }
            if let selectedIndex, range.contains(selectedIndex) {
                RuleMark(x: .value(String(localized: "Выбранный замер"), observation(at: selectedIndex).time))
                    .foregroundStyle(.primary.opacity(0.65))
                    .accessibilityHidden(true)
            }
        }
        .chartXScale(domain: times)
        .chartYScale(domain: bounds)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { mark in
                AxisGridLine()
                if let time = mark.as(Double.self),
                   let index = coordinates.nearestIndex(to: time, time: { $0.time }) {
                    let sample = coordinates[index]
                    let date = sample.date.addingTimeInterval(time - sample.time)
                    AxisValueLabel { Text(date, format: Self.clock) }
                }
            }
        }
        .chartYAxis {
            if mode.usesCategories {
                AxisMarks(position: .leading, values: categories.indices.map { Double($0) }) { mark in
                    AxisGridLine()
                    if let coordinate = mark.as(Double.self), categories.indices.contains(Int(coordinate)) {
                        let category = categories[Int(coordinate)]
                        AxisValueLabel { Text(categoryLabels[category] ?? category) }
                    }
                }
            } else {
                AxisMarks(position: .leading) {
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
        }
        .chartYAxisLabel(axisTitle, position: .leading)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { tap in
                        guard let anchor = proxy.plotFrame,
                              let x = Self.plotX(at: tap.location, in: geometry[anchor]),
                              let time = proxy.value(atX: x, as: Double.self),
                              let index = coordinates.nearestIndex(to: time, time: { $0.time }) else { return }
                        select(index + range.lowerBound)
                    })
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            if points.isEmpty {
                Text("Нет значений для этого графика за выбранный период")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(.regularMaterial, in: .rect(cornerRadius: 5))
                    .allowsHitTesting(false)
            }
        }
        .wifiChartSelection(String(localized: "График «\(mode.title)»"), in: range, selectedIndex: selectedIndex,
                            date: { observation(at: $0).date }, onSelect: select)
    }

    private func select(_ index: Int) {
        guard recording.session.id == content.sessionID else { return }
        recording.selectRadioSample(index)
    }

    nonisolated static func plotX(at location: CGPoint, in frame: CGRect) -> CGFloat? {
        guard frame.width > 0, frame.height > 0,
              (frame.minX ... frame.maxX).contains(location.x),
              (frame.minY ... frame.maxY).contains(location.y) else { return nil }
        // Keep the rightmost click inside ChartProxy's x scale.
        return min(location.x - frame.minX, frame.width.nextDown)
    }

    private func valueBounds(points: [WiFiChartPoint], categoryCount: Int) -> ClosedRange<Double> {
        if mode.usesCategories {
            return -0.5 ... (Double(max(0, categoryCount - 1)) + 0.5)
        }
        let initial: ClosedRange<Double> = switch mode {
        case .snr: 0 ... 40
        case .transmitRate: 0 ... 10
        default: -100 ... -40
        }
        return points.reduce(initial) { bounds, point in
            guard case .number(let value) = point.value else { return bounds }
            return min(bounds.lowerBound, value) ... max(bounds.upperBound, value)
        }
    }

    private func coordinate(of value: WiFiChartValue, categoryPositions: [String: Double]) -> Double? {
        switch value {
        case .number(let value): value
        case .category(let label): categoryPositions[label]
        }
    }

    private func accessibleValue(_ value: WiFiChartValue, axisTitle: String, categoryLabels: [String: String]) -> String {
        switch value {
        case .number(let value): "\(value.formatted(.number.precision(.fractionLength(0 ... 1)))) \(axisTitle)"
        case .category(let label): categoryLabels[label] ?? label
        }
    }
}

enum WiFiChartSelectionStep {
    case previous, next

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
        _ title: String, in indices: Indices, selectedIndex: Int?, date: (Int) -> Date,
        labels: WiFiChartSelectionLabels = .radioSample,
        onSelect: @escaping (Int) -> Void
    ) -> some View where Indices.Index == Int, Indices.Element == Int {
        if let last = indices.last {
            let selected = selectedIndex.flatMap { indices.contains($0) ? $0 : nil }
            let current = selected ?? last
            let time = date(current).formatted(.dateTime.year().month().day()
                .hour().minute().second().secondFraction(.fractional(3)).locale(WiFiInspectionTime.locale))
            let selectionDescription = if selected != nil {
                String(localized: "\(labels.displayedItem) в \(time)")
            } else if selectedIndex != nil {
                String(localized: "В выбранный момент нет точки на этом графике")
            } else {
                String(localized: "\(labels.lastItem) в \(time)")
            }
            let step: (WiFiChartSelectionStep) -> Void = { direction in
                if let target = direction.target(in: indices, from: selectedIndex) { onSelect(target) }
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
                .accessibilityAction(named: Text(selected == nil ? labels.showLast : labels.show)) {
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
        }
    }

    var color: Color {
        switch self {
        case .signal: WiFiQuality.good.color
        case .noise: WiFiQuality.good.color
        case .channel: .blue
        case .phyMode: .purple
        case .transmitRate: .teal
        case .snr: WiFiQuality.good.color
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
