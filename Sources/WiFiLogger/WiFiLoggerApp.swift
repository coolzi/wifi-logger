import AppKit
import CoreLocation
import SwiftUI
import UniformTypeIdentifiers

struct WiFiLoggerApp: App {
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Wi-Fi Logger", id: "logger") {
            WiFiLoggerWindow()
                .frame(minWidth: 680, minHeight: 470)
        }
        .defaultSize(width: 800, height: 980)
        .commands {
            WiFiLoggerFileCommands()
            CommandGroup(replacing: .help) {
                Button(WiFiLoggerHelp.title) {
                    openWindow(id: WiFiLoggerHelp.windowID)
                }
            }
        }

        Window(WiFiLoggerHelp.title, id: WiFiLoggerHelp.windowID) {
            WiFiLoggerHelp()
                .frame(minWidth: 620, minHeight: 360)
        }
        .defaultSize(width: 760, height: 530)
    }
}

private struct WiFiLoggerFileActions {
    let canRestart: Bool
    let canSaveRecording: Bool
    let canSaveModulation: Bool
    let canImportAccessPoints: Bool
    let restart: @MainActor () -> Void
    let save: @MainActor (WiFiLoggerTab) -> Void
    let importAccessPoints: @MainActor () -> Void
}

private struct WiFiLoggerFileActionsKey: FocusedValueKey {
    typealias Value = WiFiLoggerFileActions
}

private extension FocusedValues {
    var wifiLoggerFileActions: WiFiLoggerFileActions? {
        get { self[WiFiLoggerFileActionsKey.self] }
        set { self[WiFiLoggerFileActionsKey.self] = newValue }
    }
}

private struct WiFiLoggerFileCommands: Commands {
    @FocusedValue(\.wifiLoggerFileActions) private var actions

    var body: some Commands {
        CommandGroup(after: .newItem) {
            WiFiLoggerFileButtons(actions: actions)
            Button("Импорт имён точек доступа…") { actions?.importAccessPoints() }
                .disabled(actions?.canImportAccessPoints != true)
        }
    }
}

private struct WiFiLoggerFileButtons: View {
    let actions: WiFiLoggerFileActions?

    var body: some View {
        Button("Новая запись…") { actions?.restart() }
            .disabled(actions?.canRestart != true)
        Menu("Сохранить CSV") {
            Button("Замеры Wi-Fi…") { actions?.save(.recording) }
                .disabled(actions?.canSaveRecording != true)
            Button("Снимки модуляции…") { actions?.save(.modulation) }
                .disabled(actions?.canSaveModulation != true)
        }
    }
}

struct WiFiLoggerWindow: View {
    @StateObject private var recording: WiFiRecording
    @StateObject private var location = WiFiLocationAccess()
    @StateObject private var windowReference = WiFiViewReference()
    @StateObject private var accessPoints = WiFiAccessPointImportState()

    private var session: WiFiSession { recording.session }
    private var tab: WiFiLoggerTab { recording.tab }
    private var hasSessionData: Bool {
        !session.samples.isEmpty || !recording.modulationSnapshots.isEmpty
    }

    init(recording: WiFiRecording = WiFiRecording()) {
        _recording = StateObject(wrappedValue: recording)
    }

    var body: some View {
        let captureID = recording.captureID
        let fileActions = WiFiLoggerFileActions(
            canRestart: hasSessionData, canSaveRecording: hasData(for: .recording),
            canSaveModulation: hasData(for: .modulation), canImportAccessPoints: accessPoints.canImport,
            restart: confirmRestart, save: saveCSV, importAccessPoints: chooseAccessPointCSV
        )
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                connectionHeader
                timelineNavigation
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .frame(maxWidth: 1160)
            .frame(maxWidth: .infinity)
            .background(.background)
            Divider()
            TabView(selection: $recording.tab) {
                tabPage(.recording)
                    .tabItem { Text("Замеры Wi-Fi") }
                    .tag(WiFiLoggerTab.recording)
                tabPage(.modulation)
                    .tabItem { Text("Снимки модуляции") }
                    .tag(WiFiLoggerTab.modulation)
            }
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WiFiViewAnchor(reference: windowReference).allowsHitTesting(false))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                WiFiLoggerFileButtons(actions: fileActions)
            }
        }
        .focusedSceneValue(\.wifiLoggerFileActions, fileActions)
        .task(id: location.status) { await recording.refreshPreview() }
        .task { await loadAccessPoints() }
        .task(id: captureID) {
            await recording.capture(id: captureID)
        }
        .task(id: captureID) {
            await recording.captureModulation(id: captureID)
        }
        .alert("Не удалось прочитать справочник точек доступа", isPresented: $accessPoints.loadFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Загрузите CSV заново через меню «Файл».")
        }
    }

    private func tabPage(_ page: WiFiLoggerTab) -> some View {
        ScrollView {
            if tab == page {
                tabContent
                    .padding(12)
                    .frame(maxWidth: 1160, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .recording:
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    connectionFields
                    permissionHint
                }
                .wifiPanel()
                timeline.wifiPanel()
                stabilitySummary.wifiPanel()
                eventList.wifiPanel()
            }
        case .modulation:
            let sessionID = session.id
            WiFiModulationView(snapshots: recording.modulationSnapshots,
                               times: recording.timelinePlotUptimes,
                               observedTimes: recording.timelineUptimes,
                               visible: recording.modulationWindow,
                               selectedIndex: recording.selectedModulationIndex,
                               inspectedAt: recording.inspectedAt,
                               isRecording: recording.isRecording,
                               hasRadioSamples: !session.samples.isEmpty,
                               readingUnavailable: recording.modulationReadingUnavailable) { index, atNSS in
                guard session.id == sessionID else { return }
                recording.selectModulationSnapshot(index, atNSS: atNSS)
            }
        }
    }

    private var timelineNavigation: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Picker("Диапазон", selection: Binding(
                    get: { recording.chartSpan }, set: { recording.changeChartSpan($0) }
                )) {
                    ForEach(WiFiChartSpan.allCases, id: \.self) { span in
                        Text(span.label).tag(span)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Spacer(minLength: 0)
                Button("К последним данным", action: recording.returnToLatest)
                    .disabled(!recording.isShowingHistory)
                    .fixedSize()
            }
            if let time = recording.inspectedAt {
                Text("Выбранный момент · \(WiFiInspectionTime.timestamp(time))")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            } else if recording.isShowingHistory {
                Text("История")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sheetOwner: NSWindow? {
        guard let window = windowReference.view?.window,
              window.sheetParent == nil, window.attachedSheet == nil else { return nil }
        return window
    }

    private func confirmRestart() {
        guard hasSessionData, let window = sheetOwner else { return }
        let sessionID = session.id

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Начать новую запись?")
        let consequence = String(localized: "После сброса исчезнут замеры, события и снимки модуляции.")
        let guidance = recording.isRecording
            ? String(localized: "Чтобы сохранить всю историю, нажмите «Отмена», приостановите запись и выберите нужные пункты в меню «Сохранить CSV».")
            : String(localized: "Чтобы сохранить всю историю, нажмите «Отмена», выберите нужные пункты в меню «Сохранить CSV».")
        alert.informativeText = "\(consequence) \(guidance)"
        let cancel = alert.addButton(withTitle: String(localized: "Отмена"))
        let reset = alert.addButton(withTitle: String(localized: "Сбросить и начать"))
        reset.hasDestructiveAction = true
        reset.keyEquivalent = ""
        // AppKit assigns Return to the default cell, overriding its Escape shortcut.
        alert.window.defaultButtonCell = nil
        cancel.keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn, recording.session.id == sessionID {
                recording.restart()
            }
        }
    }

    private func hasData(for tab: WiFiLoggerTab) -> Bool {
        switch tab {
        case .recording: !session.samples.isEmpty
        case .modulation: !recording.modulationSnapshots.isEmpty
        }
    }

    private func saveCSV(for tab: WiFiLoggerTab) {
        guard hasData(for: tab), let window = sheetOwner else { return }
        let sessionID = session.id

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = tab == .recording ? "WiFi-Logger.csv" : "WiFi-Logger-modulation.csv"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let destination = panel.url, recording.session.id == sessionID else { return }
            switch tab {
            case .recording:
                let session = recording.snapshotForExport()
                panel.orderOut(nil)
                writeCSV(to: destination, in: window) { WiFiCSV.encode(session) }
            case .modulation:
                panel.orderOut(nil)
                let snapshots = recording.modulationSnapshots
                writeCSV(to: destination, in: window) { WiFiCSV.encodeModulation(snapshots) }
            }
        }
    }

    private func writeCSV(to destination: URL, in window: NSWindow, encode: @escaping @Sendable () -> Data) {
        let progress = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 90),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        progress.contentView = NSHostingView(rootView: ProgressView("Сохранение CSV…").padding(20))
        window.beginSheet(progress)

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                try encode().write(to: destination, options: .atomic)
            }.result
            window.endSheet(progress)
            progress.orderOut(nil)
            if case .failure(let error) = result {
                _ = await NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    private func loadAccessPoints() async {
        let file = WiFiAccessPointDirectory.applicationFile
        let result = await Task.detached {
            try WiFiAccessPointDirectory.load(from: file)
        }.result
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let directory): accessPoints.directory = directory
        case .failure: accessPoints.loadFailed = true
        }
        accessPoints.canImport = true
    }

    private func chooseAccessPointCSV() {
        guard accessPoints.canImport, let window = sheetOwner else { return }
        accessPoints.canImport = false
        Task {
            defer { accessPoints.canImport = true }
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.canChooseDirectories = false
            panel.prompt = String(localized: "Открыть")
            guard await panel.beginSheetModal(for: window) == .OK, let file = panel.url else { return }
            panel.orderOut(nil)
            await importAccessPoints(from: file, in: window)
        }
    }

    private func importAccessPoints(from file: URL, in window: NSWindow) async {
        do {
            let previous = accessPoints.directory
            let (directory, changes) = try await Task.detached(priority: .userInitiated) {
                let directory = try WiFiAccessPointDirectory(csv: Data(contentsOf: file))
                return (directory, previous.map { directory.changes(from: $0) })
            }.value
            guard window.isVisible else { return }

            let confirmation = NSAlert()
            let isReplacing = changes != nil
            confirmation.messageText = isReplacing ? String(localized: "Заменить справочник точек доступа?")
                : String(localized: "Загрузить имена точек доступа?")
            confirmation.informativeText = String(localized: """
                Имён точек — \(directory.nameCount.formatted())
                Адресов BSSID — \(directory.bssidCount.formatted())
                """)
            if let changes {
                confirmation.informativeText += "\n\n" + String(localized: """
                    Изменения по BSSID
                    Добавятся — \(changes.added.formatted())
                    Потеряют имя — \(changes.removed.formatted())
                    Сменят имя — \(changes.renamed.formatted())
                    """)
            }
            confirmation.addButton(withTitle: isReplacing ? String(localized: "Заменить") : String(localized: "Загрузить"))
            confirmation.addButton(withTitle: String(localized: "Отмена")).keyEquivalent = "\u{1b}"
            guard await confirmation.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }

            let destination = WiFiAccessPointDirectory.applicationFile
            try await Task.detached(priority: .userInitiated) {
                try directory.save(to: destination)
            }.value
            accessPoints.directory = directory
        } catch {
            guard window.isVisible else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Не удалось импортировать имена точек")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            _ = await alert.beginSheetModal(for: window)
        }
    }

    private var connectionHeader: some View {
        let current = tab == .recording ? recording.displayedSample : recording.latestSample
        let state = current?.state
        return HStack(spacing: 10) {
            Image(systemName: state == .disconnected || state == .poweredOff ? "wifi.slash" : "wifi")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(current?.connectedMeasurements.ssid ?? "Wi-Fi")
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let state {
                    Text(tab == .modulation && recording.isShowingHistory
                         ? String(localized: "Последний замер Wi-Fi · \(state.displayName)") : state.displayName)
                        .font(.caption)
                        .foregroundStyle(state == .connected ? WiFiQuality.good.color
                                         : state == .disconnected ? WiFiQuality.poor.color : Color.secondary)
                        .fixedSize()
                }
            }
            Spacer(minLength: 10)
            if !session.samples.isEmpty {
                HStack(spacing: 6) {
                    Circle()
                        .fill(recording.isRecording ? WiFiQuality.poor.color : Color.secondary)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(recording.isRecording ? String(localized: "Идёт запись") : String(localized: "Запись на паузе"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.55), in: .capsule)
            }
            Button(action: recording.toggle) {
                Label(recordButtonTitle, systemImage: recording.isRecording ? "pause.fill" : "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("r", modifiers: .command)
        }
    }

    private var recordButtonTitle: LocalizedStringKey {
        if recording.isRecording { return "Приостановить запись" }
        return session.samples.isEmpty ? "Начать запись" : "Продолжить запись"
    }

    private var connectionFields: some View {
        let fields = recording.displayedSample?.connectedMeasurements
        return HStack(alignment: .top, spacing: 16) {
            parameter("Канал", fields?.channel?.displayLabel)
            parameter("Режим", fields?.wifiGenerationLabel)
            parameter("Скорость передачи", fields?.displayTransmitRate)
            parameter("BSSID", fields?.bssid, detail: accessPoints.directory?.name(for: fields?.bssid))
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
           location.status == .notDetermined || location.status == .denied || location.status == .restricted {
            HStack(spacing: 10) {
                if location.status == .notDetermined {
                    Text("Для SSID и BSSID нужен доступ к геолокации.")
                    Button("Разрешить", action: location.request)
                } else {
                    Text("Доступ к SSID и BSSID зависит от разрешения в «Системных настройках» → «Конфиденциальность и безопасность» → «Службы геолокации».")
                }
            }
            .font(.subheadline)
        }
    }

    private var timeline: some View {
        let snapshot = session
        let displayedSample = recording.displayedSample
        let fields = displayedSample?.connectedMeasurements
        let mode = recording.chartMode
        let readouts = recording.chartReadouts
        let window = recording.chartWindow
        let range = window.samples
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("График", selection: $recording.chartMode) {
                    ForEach(WiFiChartMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
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
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(readouts.primary, id: \.self) { trend in
                        chartReadout(trend, fields: fields, plotted: mode.trends.contains(trend))
                    }
                }
                if let sample = displayedSample, !readouts.secondary.isEmpty {
                    let summary = readouts.secondary.map { trend in
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
            if range.isEmpty {
                let title: LocalizedStringKey = snapshot.samples.isEmpty && !recording.isShowingHistory
                    ? "Запись ещё не началась" : "Нет замеров за этот период"
                ContentUnavailableView(title, systemImage: "waveform.path")
                    .frame(maxWidth: .infinity)
                    .frame(height: 218)
            } else {
                WiFiTimelineChart(session: snapshot, window: window, selectedIndex: recording.selectedIndex,
                                  mode: mode) { index in
                    guard session.id == snapshot.id else { return }
                    recording.selectRadioSample(index)
                }
                .frame(height: 218)
                // Swift Charts centers the last time label when its tick is near the right edge.
                .padding(.trailing, 16)
            }
            if session.samples.count > max(1, range.count) {
                chartNavigation(in: range)
            } else if range.isEmpty, !session.samples.isEmpty {
                Button("К замеру") { moveChart(to: 0, in: snapshot.id) }
            }
            if mode == .snr || mode == .signalAndNoise {
                DisclosureGroup("Как читать цвета") {
                    Group {
                        if mode == .snr {
                            snrLegend
                        } else {
                            qualityLegend
                        }
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }
                .font(.subheadline)
            }
        }
    }

    @ViewBuilder private func chartReadout(_ trend: WiFiTrend, fields: WiFiMeasurements?, plotted: Bool) -> some View {
        let series = plotted ? trend : nil
        switch trend {
        case .signal:
            qualityReadout(trend.label, value: fields?.signalDBm, metric: .rssi, trend: series)
        case .noise:
            qualityReadout(trend.label, value: fields?.noiseDBm, metric: .noise, trend: series)
        case .snr:
            qualityReadout(trend.label, value: fields?.snrDB, metric: .snr, trend: series)
        case .channel:
            readout(trend.label, value: fields?.channel?.displayChartLabel, trend: series)
        case .phyMode:
            readout(trend.label, value: fields?.wifiGenerationLabel, trend: series)
        case .transmitRate:
            readout(trend.label, value: fields?.displayTransmitRate, trend: series)
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
                         quality: WiFiQuality? = nil, qualityLabel: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if let trend {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 1))
                        path.addLine(to: CGPoint(x: 12, y: 1))
                    }
                    .stroke(quality?.color ?? trend.color, style: trend.stroke)
                    .frame(width: 12, height: 2)
                    .accessibilityHidden(true)
                }
                Text(title).foregroundStyle(.secondary).font(.caption)
            }
            Text(value ?? "—")
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(value == nil ? .secondary : quality?.color ?? .primary)
            if let qualityLabel {
                Text(qualityLabel)
                    .font(.caption)
                    .foregroundStyle(quality?.color ?? .secondary)
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
            snrLegend
            HStack(spacing: 12) {
                Text("Шум, дБм").frame(width: 65, alignment: .leading)
                legendItem("≤ −92", quality: .good, metric: .noise)
                legendItem(">−92…≤−87", quality: .fair, metric: .noise)
                legendItem("> −87", quality: .poor, metric: .noise)
            }
            Text("Шум — пунктир; его шкала рассчитана для сигнала −67 дБм. Фактическое соотношение — SNR.")
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
        let snapshot = session
        return VStack(alignment: .leading, spacing: 8) {
            Text("События").font(.headline).accessibilityAddTraits(.isHeader)
            if snapshot.events.isEmpty {
                Text("Событий пока нет").foregroundStyle(.secondary).font(.subheadline)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(snapshot.events.reversed()) { event in
                        eventRow(event, in: snapshot)
                    }
                }
            }
        }
    }

    private func eventRow(_ event: WiFiEvent, in snapshot: WiFiSession) -> some View {
        let isSelected = recording.selectedIndex == event.sampleIndex
        return Button {
            guard session.id == snapshot.id else { return }
            recording.selectRadioEvent(event.sampleIndex)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(snapshot.samples[event.sampleIndex].time, format: WiFiTimelineChart.clock)
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
                        if let detail = eventDetail(event, in: snapshot) {
                            Text(detail).foregroundStyle(.secondary)
                        }
                    }
                    if let transition = accessPointTransition(event, in: snapshot) {
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

    private func accessPointTransition(_ event: WiFiEvent, in session: WiFiSession) -> String? {
        guard event.kind == .accessPointChanged,
              let before = session.samples[event.sampleIndex - 1].measurements.bssid,
              let after = session.samples[event.sampleIndex].measurements.bssid else { return nil }
        return "\(accessPointLabel(before)) → \(accessPointLabel(after))"
    }

    private func accessPointLabel(_ bssid: String) -> String {
        guard let name = accessPoints.directory?.name(for: bssid) else { return bssid }
        return "\(name) (\(bssid))"
    }

    private func eventDetail(_ event: WiFiEvent, in session: WiFiSession) -> String? {
        if let duration = event.duration {
            return String(localized: "Через \(duration.formatted(.number.precision(.fractionLength(0 ... 2)))) с")
        }
        if event.kind == .channelChanged,
           let before = session.samples[event.sampleIndex - 1].measurements.channel?.displayChartLabel,
           let after = session.samples[event.sampleIndex].measurements.channel?.displayChartLabel {
            return "\(before) → \(after)"
        }
        if event.kind == .accessPointChanged,
           let before = session.samples[event.sampleIndex - 1].measurements.channel?.number,
           let after = session.samples[event.sampleIndex].measurements.channel?.number,
           before != after {
            return String(localized: "Канал \(before) → \(after)")
        }
        return nil
    }

}

extension View {
    func wifiPanel() -> some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        return padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: shape)
            .overlay {
                shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }

    func wifiReadoutTile(tint: Color?) -> some View {
        frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint?.opacity(0.05) ?? Color.primary.opacity(0.04), in: .rect(cornerRadius: 7))
    }
}

@MainActor
private final class WiFiAccessPointImportState: ObservableObject {
    @Published var directory: WiFiAccessPointDirectory?
    @Published var canImport = false
    @Published var loadFailed = false
}

@MainActor
final class WiFiViewReference: ObservableObject {
    weak var view: NSView?
}

struct WiFiViewAnchor: NSViewRepresentable {
    let reference: WiFiViewReference

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        reference.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
private final class WiFiLocationAccess: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published private(set) var status: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        status = manager.authorizationStatus
        manager.delegate = self
    }

    func request() { manager.requestWhenInUseAuthorization() }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            status = self.manager.authorizationStatus
        }
    }
}
