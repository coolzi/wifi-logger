import Charts
import SwiftUI

struct WiFiModulationView: View {
    @MainActor private final class CodingHint: ObservableObject {
        @Published var isVisible = false
    }

    let snapshots: [WiFiModulationSnapshot]
    let times: ClosedRange<TimeInterval>
    let observedTimes: ClosedRange<TimeInterval>
    let visible: Range<Int>
    let selectedIndex: Int?
    let inspectedAt: Date?
    let isRecording: Bool
    let hasRadioSamples: Bool
    let readingUnavailable: Bool
    let onSelect: (Int, Bool) -> Void
    @StateObject private var codingHint = CodingHint()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private static let axisWidth: CGFloat = 54
    private static let axisSpacing: CGFloat = 8
    private static let horizontalPlotPadding: CGFloat = 6
    private static let plotHeight: CGFloat = 66
    private static let requestBandColor = Color.accentColor.opacity(0.13)
    private static let codingHelp = String(localized: """
        Доля равна числу бит до кодирования, делённому на число бит после него. Избыточность помогает приёмнику исправлять ошибки.
        """)
    private static let locale = WiFiInterfaceLocale.current

    var body: some View {
        if let lastIndex = snapshots.indices.last {
            let index = selectedIndex.flatMap { visible.contains($0) ? $0 : nil } ?? visible.last
            VStack(alignment: .leading, spacing: 12) {
                if let index {
                    snapshotCard(snapshots[index])
                        .wifiPanel()
                        .zIndex(1)
                }
                history(index: index, lastIndex: lastIndex)
                    .wifiPanel()
            }
        } else {
            ContentUnavailableView {
                Label("Нет снимков модуляции", systemImage: "waveform.path")
            } description: {
                Text(emptyDescription)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .wifiPanel()
        }
    }

    private func history(index: Int?, lastIndex: Int) -> some View {
        let selection = index.map { snapshots[$0] }
        let requestBand = selection.flatMap { snapshot in
            Self.requestBand(start: snapshot.startedUptime, end: snapshot.finishedUptime, in: observedTimes)
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("История снимков").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if requestBand != nil {
                    Label {
                        Text("Запрос macOS")
                    } icon: {
                        Rectangle()
                            .fill(Self.requestBandColor)
                            .overlay { Rectangle().strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1) }
                            .frame(width: 14, height: 10)
                            .accessibilityHidden(true)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Подсветка от начала запроса до ответа macOS")
                    .accessibilityLabel("Подсвеченный интервал запроса macOS")
                }
            }
            if readingUnavailable {
                Text("В последней попытке не удалось получить MCS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let selection {
                VStack(alignment: .leading, spacing: 9) {
                    plot(.mcs, selection: selection, requestBand: requestBand)
                    plot(.rate, selection: selection, requestBand: requestBand)
                    plot(.spatialStreams, selection: selection, requestBand: requestBand)
                    timeAxis
                }
            } else {
                ContentUnavailableView("Нет снимков за этот период", systemImage: "waveform.path")
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
            }
            if lastIndex > 0 {
                snapshotNavigation(index: index, last: lastIndex)
            } else if index == nil {
                Button("К снимку") { select(lastIndex) }
            }
            if index != nil {
                modulationLegend
            }
        }
    }

    var emptyDescription: String {
        let failure = String(localized: "В последней попытке не удалось получить данные модуляции.")
        if isRecording { return readingUnavailable ? failure : String(localized: "Ожидаем первый снимок.") }
        let guidance = hasRadioSamples ? String(localized: "Продолжите запись, чтобы получить снимки.")
            : String(localized: "Начните запись, чтобы получить снимки.")
        return readingUnavailable ? "\(failure) \(guidance)" : guidance
    }

    private func snapshotCard(_ snapshot: WiFiModulationSnapshot) -> some View {
        let modulation = snapshot.modulationType
        let accentColor = modulation.map(modulationColor)
        let bits = modulation.map { type in
            let count = type.bitsPerSymbol
            if count == 1 { return String(localized: "1 бит на символ") }
            return count == 2 || count == 4 ? String(localized: "\(count) бита на символ")
                : String(localized: "\(count) бит на символ")
        }
        let informationShare = snapshot.informationBitFraction.map {
            let share = $0.formatted(.percent.locale(Self.locale).precision(.fractionLength(0...1)))
            return String(localized: "\(share) исходных бит")
        }
        let generation = WiFiMeasurements(channel: snapshot.channel, phyMode: snapshot.phyMode).wifiGenerationLabel
        let phy = generation == snapshot.phyMode
            ? snapshot.phyMode
            : [generation, snapshot.phyMode].compactMap { $0 }.joined(separator: " · ")
        let responseTime = WiFiInspectionTime.observation(snapshot.finishedAt, comparedTo: inspectedAt)
        let start = WiFiInspectionTime.timestamp(snapshot.startedAt)
        let end = Calendar.current.isDate(snapshot.startedAt, inSameDayAs: snapshot.finishedAt)
            ? snapshot.finishedAt.formatted(WiFiInspectionTime.clock)
            : WiFiInspectionTime.timestamp(snapshot.finishedAt)
        let nssTime = snapshot.spatialStreams.map { reading in
            let clock = reading.receivedAt.formatted(WiFiInspectionTime.clock)
            return Calendar.current.isDate(snapshot.finishedAt, inSameDayAs: reading.receivedAt)
                ? String(localized: "Ответ в \(clock)")
                : "\(reading.receivedAt.formatted(WiFiInspectionTime.calendarDate))\n\(clock)"
        }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Снимок").font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if let responseTime {
                    Text("Ответ по снимку · \(responseTime)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Режим \(phy ?? "—")  ·  Канал \(snapshot.channel?.displayChartLabel ?? "—")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 8) {
                metric("MCS", snapshot.mcs.map { String($0) }, accent: accentColor)
                    .help("Для известных сочетаний MCS и режима Wi-Fi приложение показывает модуляцию и кодовую скорость.")
                metric(String(localized: "Модуляция"), snapshot.modulation, accent: accentColor,
                       detail: bits ?? String(localized: "Бит на символ —"))
                    .help("Число кодированных бит на символ одной поднесущей в одном пространственном потоке.")
                metric(String(localized: "Кодовая скорость"), snapshot.coding,
                       detail: informationShare ?? String(localized: "Доля бит —"), detailLines: 2)
                    .contentShape(Rectangle())
                    .onHover { codingHint.isVisible = $0 }
                    .accessibilityHint(Self.codingHelp)
                    .overlay {
                        GeometryReader { geometry in
                            if codingHint.isVisible {
                                Text(Self.codingHelp)
                                    .font(.caption)
                                    .padding(9)
                                    .frame(width: 254, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .background(.regularMaterial, in: .rect(cornerRadius: 6))
                                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                                    .offset(y: geometry.size.height + 5)
                            }
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                    .zIndex(1)
                metric(Lane.rate.title, snapshot.transmitRateMbps.map { $0.formatted(Self.rateFormat) })
                metric("NSS (macOS)", snapshot.spatialStreams.map { String($0.count) }, detail: nssTime, detailLines: 2)
                    .help("Время отдельного ответа macOS. Если BSSID недоступен, совпадение точки доступа проверить нельзя.")
            }
            Text("Запрос macOS \(start) → \(end)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Запрос macOS. Начало \(start). Ответ \(end).")
        }
    }

    private static let rateFormat = FloatingPointFormatStyle<Double>.number.locale(locale)
        .precision(.fractionLength(0...1))

    private func metric(_ title: String, _ value: String?, accent: Color? = nil, detail: String? = nil,
                        detailLines: Int = 1) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "—")
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(value == nil ? Color.secondary : accent ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(detailLines)
                    .minimumScaleFactor(0.85)
            }
        }
        .wifiReadoutTile(tint: accent)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var modulationLegend: some View {
        let samples = snapshots[profilerWindow]
        let types = Set(samples.compactMap(\.modulationType))
        let hasUnknown = samples.contains { $0.mcs != nil && $0.modulationType == nil }
        if !types.isEmpty || hasUnknown {
            DisclosureGroup("Как читать цвета MCS") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 8, alignment: .leading)],
                          alignment: .leading, spacing: 4) {
                    ForEach(WiFiModulationType.allCases.filter(types.contains), id: \.self) { type in
                        legendItem(type.rawValue, color: modulationColor(type))
                    }
                    if hasUnknown { legendItem(String(localized: "Не определена"), color: .secondary) }
                }
                .padding(.top, 6)
            }
            .font(.subheadline)
        }
    }

    private func legendItem(_ label: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(label).font(.caption)
        }
    }

    private var profilerWindow: Range<Int> {
        let start = snapshots[visible].partitionIndex { $0.finishedUptime >= observedTimes.lowerBound }
        return start..<visible.upperBound
    }

    private func modulationColor(_ type: WiFiModulationType) -> Color {
        type.color(in: colorScheme, contrast: colorSchemeContrast)
    }

    nonisolated static func requestBand(start: TimeInterval, end: TimeInterval,
                                       in observedTimes: ClosedRange<TimeInterval>) -> Range<TimeInterval>? {
        let visibleStart = max(start, observedTimes.lowerBound)
        guard observedTimes.contains(end), visibleStart < end else { return nil }
        return visibleStart..<end
    }

    private func plot(_ lane: Lane, selection: WiFiModulationSnapshot, requestBand: Range<TimeInterval>?) -> some View {
        let indices = visible.filter { index in
            let snapshot = snapshots[index]
            return observedTimes.contains(lane.uptime(in: snapshot)) && lane.value(in: snapshot) != nil
        }
        let values = indices.compactMap { lane.value(in: snapshots[$0]) }
        let ticks = lane.ticks(for: values)
        let lower = ticks[0]
        let upper = ticks[ticks.count - 1]
        let inset = (upper - lower) * 0.10
        let scale = (lower - inset) ... (upper + inset)
        let title = lane.title
        let requestStartTitle = String(localized: "Начало запроса")
        let responseTitle = String(localized: "Ответ macOS")
        let responseTimeTitle = String(localized: "Время ответа")
        return VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.semibold))
            HStack(spacing: Self.axisSpacing) {
                // The same external gutter aligns the plot frames with the shared time axis.
                ZStack {
                    ForEach(ticks, id: \.self) { tick in
                        Text(tick, format: Self.rateFormat)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .position(
                                x: Self.axisWidth / 2,
                                y: Self.plotHeight * (scale.upperBound - tick) / (scale.upperBound - scale.lowerBound)
                            )
                    }
                }
                .frame(width: Self.axisWidth, height: Self.plotHeight)
                .accessibilityHidden(true)
                Chart {
                    if let requestBand {
                        RectangleMark(
                            xStart: .value(requestStartTitle, requestBand.lowerBound),
                            xEnd: .value(responseTitle, requestBand.upperBound),
                            yStart: .value(title, scale.lowerBound), yEnd: .value(title, scale.upperBound)
                        )
                        .foregroundStyle(Self.requestBandColor)
                        .accessibilityHidden(true)
                    }
                    ForEach(ticks, id: \.self) { tick in
                        RuleMark(y: .value(title, tick))
                            .foregroundStyle(.secondary.opacity(0.2))
                            .accessibilityHidden(true)
                    }
                    let responseTime = lane.uptime(in: selection)
                    if observedTimes.contains(responseTime), lane != .spatialStreams || selection.spatialStreams != nil {
                        RuleMark(x: .value(responseTitle, responseTime))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .accessibilityHidden(true)
                    }
                    ForEach(indices, id: \.self) { index in
                        let snapshot = snapshots[index]
                        if let value = lane.value(in: snapshot) {
                            let time = lane.date(in: snapshot).formatted(WiFiInspectionTime.clock)
                            PointMark(x: .value(responseTimeTitle, lane.uptime(in: snapshot)), y: .value(title, value))
                                .foregroundStyle(lane.color(for: snapshot, modulationColor: modulationColor))
                                .symbol(lane.symbol)
                                .symbolSize(snapshot.id == selection.id ? 72 : 27)
                                .accessibilityLabel(lane == .spatialStreams ? String(localized: "Ответ NSS в \(time)") : time)
                                .accessibilityValue(lane.accessibilityValue(value, in: snapshot))
                        }
                    }
                }
                .chartXScale(domain: times, range: .plotDimension(
                    startPadding: Self.horizontalPlotPadding, endPadding: Self.horizontalPlotPadding
                ))
                .chartYScale(domain: scale, range: .plotDimension(startPadding: 0, endPadding: 0))
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(maxWidth: .infinity)
                .frame(height: Self.plotHeight)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { tap in
                                guard let anchor = proxy.plotFrame,
                                      let x = WiFiTimelineChart.plotX(at: tap.location, in: geometry[anchor]),
                                      let time = proxy.value(atX: x, as: Double.self) else { return }
                                if lane == .spatialStreams {
                                    if let index = indices.min(by: {
                                        abs(lane.uptime(in: snapshots[$0]) - time)
                                            < abs(lane.uptime(in: snapshots[$1]) - time)
                                    }) {
                                        select(index, atNSS: true)
                                    }
                                } else if !profilerWindow.isEmpty {
                                    select(nearestSnapshot(to: time, in: profilerWindow))
                                }
                            })
                            .accessibilityHidden(true)
                    }
                }
                .overlay {
                    if values.isEmpty {
                        Text("Нет значений за этот период")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(5)
                            .background(.regularMaterial, in: .rect(cornerRadius: 4))
                            .allowsHitTesting(false)
                    }
                }
                .wifiChartSelection(title, in: lane == .spatialStreams ? indices : Array(profilerWindow),
                                    selectedIndex: selectedIndex, date: { lane.date(in: snapshots[$0]) },
                                    labels: lane == .spatialStreams ? .spatialStreams : .modulationSnapshot) {
                    select($0, atNSS: lane == .spatialStreams)
                }
            }
        }
    }

    private var timeAxis: some View {
        GeometryReader { geometry in
            ForEach(0..<4) { tick in
                let fraction = Double(tick) / 3
                let time = times.lowerBound + fraction * (times.upperBound - times.lowerBound)
                let snapshot = snapshots[nearestSnapshot(to: time, in: visible)]
                let date = snapshot.finishedAt.addingTimeInterval(time - snapshot.finishedUptime)
                if tick == 0 || tick == 3 {
                    Text(date, format: WiFiTimelineChart.clock)
                        .frame(maxWidth: .infinity, alignment: tick == 0 ? .leading : .trailing)
                } else {
                    Text(date, format: WiFiTimelineChart.clock)
                        .position(x: geometry.size.width * fraction, y: geometry.size.height / 2)
                }
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(height: 13)
        .padding(.leading, Self.axisWidth + Self.axisSpacing + Self.horizontalPlotPadding)
        .padding(.trailing, Self.horizontalPlotPadding)
        .accessibilityHidden(true)
    }

    nonisolated static func neighboringSnapshots(selected index: Int?, visible: Range<Int>) -> (previous: Int, next: Int) {
        if let index { return (index - 1, index + 1) }
        return (visible.lowerBound - 1, visible.lowerBound)
    }

    private func snapshotNavigation(index: Int?, last: Int) -> some View {
        let title: LocalizedStringKey = "Выбор снимка"
        let (previous, next) = Self.neighboringSnapshots(selected: index, visible: visible)
        let sliderIndex = index ?? min(visible.lowerBound, last)
        let position = Binding(
            get: { Double(sliderIndex) },
            set: { select(Int($0.rounded())) }
        )
        return HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityHidden(true)
            Button {
                select(previous)
            } label: {
                Label("Предыдущий снимок", systemImage: "chevron.left").labelStyle(.iconOnly)
            }
            .disabled(previous < 0)
            .help("Предыдущий снимок")
            Slider(value: position, in: 0...Double(last)) {
                Text(title)
            }
            .labelsHidden()
            .accessibilityValue(index.map {
                String(localized: "Ответ по снимку в \(snapshots[$0].finishedAt.formatted(WiFiInspectionTime.clock))")
            } ?? String(localized: "Нет снимков за этот период"))
            Button {
                select(next)
            } label: {
                Label("Следующий снимок", systemImage: "chevron.right").labelStyle(.iconOnly)
            }
            .disabled(next > last)
            .help("Следующий снимок")
        }
    }

    private func select(_ index: Int, atNSS: Bool = false) {
        guard snapshots.indices.contains(index) else { return }
        onSelect(index, atNSS)
    }

    private func nearestSnapshot(to time: TimeInterval, in range: Range<Int>) -> Int {
        let right = snapshots[range].partitionIndex { $0.finishedUptime >= time }
        if right == range.lowerBound { return right }
        if right == range.upperBound { return right - 1 }
        return time - snapshots[right - 1].finishedUptime <= snapshots[right].finishedUptime - time ? right - 1 : right
    }

    private enum Lane {
        case mcs
        case rate
        case spatialStreams

        var title: String {
            switch self {
            case .mcs: "MCS"
            case .rate: String(localized: "Скорость передачи, Мбит/с")
            case .spatialStreams: String(localized: "Пространственные потоки (NSS)")
            }
        }

        var symbol: BasicChartSymbolShape {
            switch self {
            case .mcs: .circle
            case .rate: .diamond
            case .spatialStreams: .square
            }
        }

        func color(for snapshot: WiFiModulationSnapshot, modulationColor: (WiFiModulationType) -> Color) -> Color {
            switch self {
            case .mcs: snapshot.modulationType.map(modulationColor) ?? .secondary
            case .rate: WiFiTrend.transmitRate.color
            case .spatialStreams: .blue
            }
        }

        @MainActor func accessibilityValue(_ value: Double, in snapshot: WiFiModulationSnapshot) -> String {
            let number = value.formatted(WiFiModulationView.rateFormat)
            switch self {
            case .mcs: return "MCS \(number), \(snapshot.modulation ?? String(localized: "модуляция не определена"))"
            case .rate: return String(localized: "\(number) Мбит/с")
            case .spatialStreams: return "NSS \(number)"
            }
        }

        func value(in snapshot: WiFiModulationSnapshot) -> Double? {
            switch self {
            case .mcs: snapshot.mcs.map(Double.init)
            case .rate: snapshot.transmitRateMbps
            case .spatialStreams: snapshot.spatialStreams.map { Double($0.count) }
            }
        }

        func uptime(in snapshot: WiFiModulationSnapshot) -> TimeInterval {
            self == .spatialStreams ? snapshot.lastObservationUptime : snapshot.finishedUptime
        }

        func date(in snapshot: WiFiModulationSnapshot) -> Date {
            self == .spatialStreams ? snapshot.spatialStreams?.receivedAt ?? snapshot.finishedAt : snapshot.finishedAt
        }

        func ticks(for values: [Double]) -> [Double] {
            switch self {
            case .mcs:
                guard let low = values.min(), let high = values.max() else { return [0, 5, 10, 15] }
                if low == high { return low == 0 ? [0, 1, 2] : [low - 1, low, low + 1] }
                let step = max(1, ceil((high - low) / 3))
                let count = Int(ceil((high - low) / step))
                return (0...count).map { low + Double($0) * step }
            case .rate:
                let step = max(1, ceil((values.max() ?? 600) / 300)) * 100
                return (0...3).map { Double($0) * step }
            case .spatialStreams:
                let high = max(4, values.max() ?? 4)
                let step = ceil((high - 1) / 3)
                return (0...3).map { 1 + Double($0) * step }
            }
        }
    }
}

extension WiFiModulationType {
    func color(in scheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        guard let colors = Self.palette[self] else { return .secondary }
        let rgb = switch (scheme, contrast) {
        case (.dark, .increased): colors.highContrastDark
        case (.dark, _): colors.dark
        case (_, .increased): colors.highContrastLight
        default: colors.light
        }
        return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                     green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }

    // A categorical palette. Its order conveys neither signal quality nor a recommendation.
    private static let palette: [Self: (light: UInt32, dark: UInt32, highContrastLight: UInt32, highContrastDark: UInt32)] = [
        .bpsk: (0x4D596A, 0xA9B7CB, 0x263240, 0xDCE5F0),
        .qpsk: (0x1751A6, 0x92BCFF, 0x003985, 0xBED9FF),
        .qam16: (0x984F0A, 0xFCAD6A, 0x703209, 0xFFD4AD),
        .qam64: (0x006D65, 0x58CDC3, 0x004B44, 0xB0F3E7),
        .qam256: (0x56338F, 0xC4AAFF, 0x3E1672, 0xE6CAFF),
        .qam1024: (0x982C68, 0xFFA2D3, 0x72083E, 0xFFD1E8),
        .qam4096: (0x615108, 0xE7CB58, 0x423600, 0xFFF2A3),
    ]
}
