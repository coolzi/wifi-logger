import CoreLocation
import SwiftUI

struct WiFiRecordingView: View {
    @ObservedObject var recording: WiFiRecording
    let accessPointDirectory: WiFiAccessPointDirectory?
    let locationStatus: CLAuthorizationStatus
    let requestLocation: @MainActor () -> Void

    private var session: WiFiSession { recording.session }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                connectionFields
                permissionHint
                networkQualityControls
            }
            .wifiPanel()
            timeline.wifiPanel()
            stabilitySummary.wifiPanel()
            eventList.wifiPanel()
        }
    }

    private var chartToggles: some View {
        let trends = WiFiChartLane.allCases.flatMap(\.trends)
        return ViewThatFits(in: .horizontal) {
            chartToggleRow(trends[...])
            VStack(alignment: .leading, spacing: 6) {
                chartToggleRow(trends.prefix(4))
                chartToggleRow(trends.dropFirst(4))
            }
        }
    }

    private func chartToggleRow(_ trends: ArraySlice<WiFiTrend>) -> some View {
        HStack(spacing: 8) {
            ForEach(trends, id: \.self) { trend in
                let isOn = recording.chartTrends.contains(trend)
                let title = chartToggleTitle(trend)
                let label = trend.label
                Toggle(isOn: Binding(get: { recording.chartTrends.contains(trend) }, set: {
                    recording.setChartTrend(trend, visible: $0)
                })) {
                    Label {
                        Text(title)
                    } icon: {
                        Image(systemName: "checkmark")
                            .opacity(isOn ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                    .frame(minWidth: 62)
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .disabled(recording.chartTrends == [trend])
                .accessibilityLabel(label)
                .accessibilityInputLabels(title == label ? [label] : [title, label])
                .frame(minWidth: 84)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func chartToggleTitle(_ trend: WiFiTrend) -> String {
        switch trend {
        case .signal: "RSSI"
        case .transmitRate: "PHY"
        case .gatewayRTT: "RTT"
        default: trend.label
        }
    }

    private var networkQualityControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                recording.requestNetworkQuality()
            } label: {
                Label("Проверить скорость Wi-Fi", systemImage: "gauge.with.dots.needle.67percent")
            }
            .disabled(recording.networkQualityState.runID != nil)
            .help("Тест нагружает интернет-канал.")
            networkQualityStatus
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var networkQualityStatus: some View {
        switch recording.networkQualityState {
        case .idle:
            EmptyView()
        case .running:
            Text("Идёт проверка скорости Wi-Fi…")
        case .measured(let result):
            let speedFormat = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2))
            let download = result.downloadMbps.formatted(speedFormat)
            let upload = result.uploadMbps.formatted(speedFormat)
            let rpm = result.rpm.formatted(.number.precision(.fractionLength(0)))
            Text("Скачивание \(download) Мбит/с · Отдача \(upload) Мбит/с · \(rpm) RPM")
                .textSelection(.enabled)
        case .failed(.noInterface):
            Text("Включите Wi-Fi и повторите проверку.")
        case .failed(.timedOut):
            Text("Проверка скорости заняла слишком много времени. Повторите попытку.")
        case .failed(.failed):
            Text("Не удалось измерить скорость Wi-Fi. Проверьте подключение и повторите попытку.")
        }
    }

    private var connectionFields: some View {
        let fields = recording.displayedSample?.connectedMeasurements
        return HStack(alignment: .top, spacing: 16) {
            parameter("Канал", fields?.channel?.displayLabel)
            parameter("Режим", fields?.wifiGenerationLabel)
            parameter("Скорость передачи", fields?.displayTransmitRate)
            parameter("BSSID", fields?.bssid, detail: accessPointDirectory?.name(for: fields?.bssid))
        }
    }

    private func parameter(_ title: LocalizedStringKey, _ value: String?, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "—")
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundStyle(value == nil ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var permissionHint: some View {
        let current = recording.latestSample
        if current?.state == .connected, current?.connectedMeasurements.bssid == nil,
           locationStatus == .notDetermined || locationStatus == .denied || locationStatus == .restricted {
            HStack(spacing: 10) {
                if locationStatus == .notDetermined {
                    Text("Для SSID и BSSID нужен доступ к геолокации.")
                    Button("Разрешить", action: requestLocation)
                } else {
                    Text("Доступ к SSID и BSSID зависит от разрешения в «Системных настройках» → «Конфиденциальность и безопасность» → «Службы геолокации».")
                }
            }
            .font(.subheadline)
        }
    }

    private var timeline: some View {
        let sessionID = session.id
        let sampleCount = session.samples.count
        let displayedSample = recording.displayedSample
        let fields = displayedSample?.connectedMeasurements
        let selected = recording.chartTrends
        let readouts = recording.chartLanes.flatMap(\.trends).filter(selected.contains)
        let additional: [WiFiTrend] = recording.selectedIndex == nil ? [] : [.signal, .noise, .snr].filter { !selected.contains($0) }
        let window = recording.chartWindow
        let range = window.samples
        let networkQualityMarkers = recording.visibleNetworkQualityMarkers
        let probes = selected.contains(.gatewayRTT) ? recording.visibleGatewayProbes : []
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Графики").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                if !range.isEmpty, let sample = displayedSample {
                    let time = recording.isShowingHistory
                        ? WiFiInspectionTime.observation(sample.time, comparedTo: recording.inspectedAt)
                        : sample.time.formatted(WiFiTimelineChart.clock)
                    if let time {
                        Text("Замер Wi-Fi · \(time)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            chartToggles
            VStack(alignment: .leading, spacing: 4) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(readouts, id: \.self) { trend in
                        chartReadout(trend, fields: fields)
                    }
                }
                if let sample = displayedSample, !additional.isEmpty {
                    let summary = additional.map { trend in
                        guard case let .number(value)? = trend.value(in: sample) else { return "\(trend.label) —" }
                        let metric: WiFiQualityMetric = trend == .snr ? .snr : .rssi
                        return "\(trend.label) \(value.formatted()) \(metric.unit)"
                    }.joined(separator: " · ")
                    Text(summary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if range.isEmpty, probes.isEmpty, networkQualityMarkers.isEmpty {
                let title: LocalizedStringKey = sampleCount == 0 && !recording.isShowingHistory
                    ? "Запись ещё не началась" : "Нет замеров за этот период"
                ContentUnavailableView(title, systemImage: "waveform.path")
                    .frame(maxWidth: .infinity)
                    .frame(height: WiFiTimelineChart.height)
            } else {
                WiFiTimelineChart(recording: recording, content: .init(
                    session: session, window: window, selectedIndex: recording.radioCursorIndex, trends: selected,
                    networkQualityMarkers: networkQualityMarkers, gatewayProbes: probes, chartOrigin: recording.chartOrigin,
                    inspectedUptime: recording.inspectedUptime, inspectedAt: recording.inspectedAt))
                .equatable()
                .frame(height: WiFiTimelineChart.height)
                // Swift Charts centers the last time label when its tick is near the right edge.
                .padding(.trailing, 16)
                .environment(\.layoutDirection, .leftToRight)
            }
            if sampleCount > max(1, range.count) {
                chartNavigation(in: range)
                    .environment(\.layoutDirection, .leftToRight)
            } else if range.isEmpty, sampleCount > 0 {
                Button("К замеру") { moveChart(to: 0, in: sessionID) }
            }
            if !selected.isDisjoint(with: [.signal, .noise, .snr]) {
                DisclosureGroup("Как читать цвета") {
                    VStack(alignment: .leading, spacing: 8) {
                        if !selected.isDisjoint(with: [.signal, .noise]) { qualityLegend }
                        if selected.contains(.snr) { snrLegend }
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }
                .font(.subheadline)
            }
        }
    }

    @ViewBuilder private func chartReadout(_ trend: WiFiTrend, fields: WiFiMeasurements?) -> some View {
        switch trend {
        case .signal:
            qualityReadout(trend.label, value: fields?.signalDBm, metric: .rssi, trend: trend)
        case .noise:
            qualityReadout(trend.label, value: fields?.noiseDBm, metric: .noise, trend: trend)
        case .snr:
            qualityReadout(trend.label, value: fields?.snrDB, metric: .snr, trend: trend)
        case .channel:
            readout(trend.label, value: fields?.channel?.displayChartLabel, trend: trend)
        case .phyMode:
            readout(trend.label, value: fields?.wifiGenerationLabel, trend: trend)
        case .transmitRate:
            readout(trend.label, value: fields?.displayTransmitRate, trend: trend)
        case .gatewayRTT:
            let probe = recording.displayedGatewayProbe
            let time = probe.flatMap {
                recording.isShowingHistory
                    ? WiFiInspectionTime.observation($0.time, comparedTo: recording.inspectedAt)
                    : $0.time.formatted(WiFiTimelineChart.clock)
            }
            readout(trend.label, value: probe?.result.displayLabel, trend: trend, detail: time)
        }
    }

    private func chartNavigation(in range: Range<Int>) -> some View {
        let title: LocalizedStringKey = "Окно графика"
        let sessionID = session.id
        let last = session.samples.count - 1
        let endIndex = range.last ?? min(range.lowerBound, last)
        let next = range.isEmpty
            ? (range.lowerBound <= last ? range.lowerBound : nil)
            : session.nextChartEnd(after: endIndex, span: recording.chartSpan)
        let position = Binding(
            get: { Double(endIndex) },
            set: { moveChart(to: Int($0.rounded()), in: sessionID) }
        )
        return HStack(spacing: 12) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityHidden(true)
            Button {
                moveChart(to: range.lowerBound - 1, in: sessionID)
            } label: {
                Label("Предыдущие замеры", systemImage: "chevron.left").labelStyle(.iconOnly)
            }
            .disabled(range.lowerBound == 0)
            // A stepped SwiftUI slider lays out a mark for every step.
            Slider(value: position, in: 0...Double(last)) {
                Text(title)
            }
            .labelsHidden()
            .accessibilityValue(range.isEmpty ? String(localized: "Нет замеров за этот период")
                : WiFiInspectionTime.timestamp(session.samples[endIndex].time))
            Button {
                if let next { moveChart(to: next, in: sessionID) }
            } label: {
                Label("Следующие замеры", systemImage: "chevron.right").labelStyle(.iconOnly)
            }
            .disabled(next == nil)
        }
    }

    private func moveChart(to endIndex: Int, in sessionID: UUID) {
        guard session.id == sessionID else { return }
        recording.moveRadioWindow(to: endIndex)
    }

    private func qualityReadout(_ title: String, value: Int?, metric: WiFiQualityMetric,
                                trend: WiFiTrend? = nil) -> some View {
        let quality = metric.quality(for: value.map(Double.init))
        return readout(title, value: value.map { "\($0.formatted()) \(metric.unit)" },
                       trend: trend, quality: quality, qualityLabel: quality.map { metric.label(for: $0) })
    }

    private func readout(_ title: String, value: String?, trend: WiFiTrend? = nil,
                         quality: WiFiQuality? = nil, qualityLabel: String? = nil, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if let trend {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 1))
                        path.addLine(to: CGPoint(x: 12, y: 1))
                    }
                    .stroke(trend.color, style: trend.stroke)
                    .frame(width: 12, height: 2)
                    .accessibilityHidden(true)
                }
                Text(title).foregroundStyle(.secondary).font(.caption)
            }
            Text(value ?? "—")
                .font((trend == .gatewayRTT ? Font.subheadline : .title2).weight(.semibold).monospacedDigit())
                .foregroundStyle(value == nil ? .secondary : quality?.color ?? .primary)
            if let qualityLabel {
                Text(qualityLabel)
                    .font(.caption)
                    .foregroundStyle(quality?.color ?? .secondary)
            }
            if let detail {
                Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .wifiReadoutTile(tint: quality?.color)
        .accessibilityElement(children: .combine)
    }

    private var qualityLegend: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                Text("RSSI, дБм").frame(width: 65, alignment: .leading)
                legendItem("≥ −67", quality: .good)
                legendItem("−70…<−67", quality: .fair)
                legendItem("−80…<−70", quality: .weak)
                legendItem("< −80", quality: .poor)
            }
            HStack(spacing: 12) {
                Text("Шум, дБм").frame(width: 65, alignment: .leading)
                legendItem("≤ −92", quality: .good, metric: .noise)
                legendItem(">−92…≤−87", quality: .fair, metric: .noise)
                legendItem("> −87", quality: .poor, metric: .noise)
            }
            Text("Шум показан пунктиром. Пороги качества шума рассчитаны для сигнала −67 дБм. Фактическое соотношение — SNR.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var snrLegend: some View {
        HStack(spacing: 12) {
            Text("SNR, дБ").frame(width: 65, alignment: .leading)
            legendItem("≥ 25", quality: .good, metric: .snr)
            legendItem("20…<25", quality: .fair, metric: .snr)
            legendItem("< 20", quality: .poor, metric: .snr)
        }
    }

    private func legendItem(_ title: String, quality: WiFiQuality, metric: WiFiQualityMetric = .rssi) -> some View {
        HStack(spacing: 4) {
            Circle().fill(quality.color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(title)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.label(for: quality)): \(title)")
    }

    private var stabilitySummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Обрывы за всю запись").font(.headline).accessibilityAddTraits(.isHeader)
            HStack(alignment: .top, spacing: 16) {
                parameter("Обрывов замечено", session.outages.count.formatted())
                    .help("Переходы из подключённого состояния в отсутствие связи или выключенный Wi-Fi.")
                parameter("Без связи", approximateDuration(session.outages.totalDuration))
                    .help("Наблюдаемое время без связи, включая периоды, начавшиеся до записи. Сон, паузы и неизвестное состояние исключены.")
                parameter("Самый долгий период", approximateDuration(session.outages.longestDuration))
                    .help("Самый длинный непрерывно наблюдавшийся период без связи, включая текущий. Длительность ограничена записанными замерами.")
            }
            Divider()
            Text("Колебания за 60 с на момент последнего замера").font(.headline).accessibilityAddTraits(.isHeader)
            HStack(alignment: .top, spacing: 16) {
                variationReadout("RSSI", variation: session.rssiVariation, unit: WiFiQualityMetric.rssi.unit)
                variationReadout("SNR", variation: session.snrVariation, unit: WiFiQualityMetric.snr.unit)
            }
        }
    }

    private func approximateDuration(_ duration: TimeInterval) -> String {
        String(localized: "≈ \(duration.formatted(.number.precision(.fractionLength(0 ... 1)))) с")
    }

    private func variationReadout(_ title: LocalizedStringKey, variation: WiFiSignalVariation, unit: String) -> some View {
        let range = variation.minimum.flatMap { minimum in
            variation.maximum.map { maximum in
                minimum == maximum ? "\(minimum) \(unit)" : "\(minimum)…\(maximum) \(unit)"
            }
        }
        let decibels = WiFiQualityMetric.snr.unit
        let spread = variation.spread.map { "\($0) \(decibels)" } ?? "—"
        let change = variation.change.map { "\($0 > 0 ? "+" : "")\($0) \(decibels)" } ?? "—"
        return VStack(alignment: .leading, spacing: 3) {
            parameter(title, range)
            Text("Размах \(spread) · изменение с предыдущего замера \(change)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Окно в 60 секунд заканчивается последним замером и включает его. Размах — максимум минус минимум. Изменение считается относительно соседнего замера без паузы.")
        .accessibilityElement(children: .combine)
    }

    private var eventList: some View {
        let sessionID = session.id
        let eventIndices = session.events.indices
        let selectedIndex = recording.selectedIndex
        return VStack(alignment: .leading, spacing: 8) {
            Text("События").font(.headline).accessibilityAddTraits(.isHeader)
            if eventIndices.isEmpty {
                Text("Событий пока нет").foregroundStyle(.secondary).font(.subheadline)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(eventIndices.reversed(), id: \.self) { eventIndex in
                        if session.id == sessionID, session.events.indices.contains(eventIndex) {
                            let event = session.events[eventIndex]
                            let index = event.sampleIndex
                            eventRow(event, sessionID: sessionID, sample: session.samples[index],
                                     previous: session.samples[index - 1].measurements, isSelected: selectedIndex == index)
                        }
                    }
                }
            }
        }
    }

    private func eventRow(_ event: WiFiEvent, sessionID: UUID, sample: WiFiSample, previous: WiFiMeasurements,
                          isSelected: Bool) -> some View {
        Button {
            guard session.id == sessionID else { return }
            recording.selectRadioEvent(event.sampleIndex)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(sample.time, format: WiFiTimelineChart.clock)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Image(systemName: event.kind.icon)
                    .foregroundStyle(event.kind.color)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(event.kind.title)
                        Spacer()
                        if let detail = eventDetail(event, previous: previous, current: sample.measurements) {
                            Text(detail).foregroundStyle(.secondary)
                        }
                    }
                    if let transition = accessPointTransition(event, previous: previous, current: sample.measurements) {
                        Text(transition)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.subheadline)
            .padding(8)
            .background(isSelected ? Color.accentColor.opacity(0.14) : .clear, in: .rect(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func accessPointTransition(_ event: WiFiEvent, previous: WiFiMeasurements, current: WiFiMeasurements) -> String? {
        guard event.kind == .accessPointChanged,
              let before = previous.bssid, let after = current.bssid else { return nil }
        return "\(accessPointLabel(before)) → \(accessPointLabel(after))"
    }

    private func accessPointLabel(_ bssid: String) -> String {
        guard let name = accessPointDirectory?.name(for: bssid) else { return bssid }
        return "\(name) (\(bssid))"
    }

    private func eventDetail(_ event: WiFiEvent, previous: WiFiMeasurements, current: WiFiMeasurements) -> String? {
        if let duration = event.duration {
            return String(localized: "Через \(duration.formatted(.number.precision(.fractionLength(0 ... 2)))) с")
        }
        if event.kind == .channelChanged,
           let before = previous.channel?.displayChartLabel,
           let after = current.channel?.displayChartLabel {
            return "\(before) → \(after)"
        }
        if event.kind == .accessPointChanged,
           let before = previous.channel?.number,
           let after = current.channel?.number,
           before != after {
            return String(localized: "Канал \(before) → \(after)")
        }
        return nil
    }
}
