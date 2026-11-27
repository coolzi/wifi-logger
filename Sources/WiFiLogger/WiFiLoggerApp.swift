import AppKit
import CoreLocation
import SwiftUI
import UniformTypeIdentifiers

struct WiFiLoggerApp: App {
    @NSApplicationDelegateAdaptor(WiFiLoggerAppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow
    private let interfaceDirection: LayoutDirection = WiFiInterfaceLocale.isRightToLeft ? .rightToLeft : .leftToRight

    var body: some Scene {
        Window("Wi-Fi Logger", id: "logger") {
            WiFiLoggerWindow()
                .frame(minWidth: 680, minHeight: 470)
                .environment(\.layoutDirection, interfaceDirection)
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
                .environment(\.layoutDirection, interfaceDirection)
        }
        .defaultSize(width: 760, height: 530)
    }
}

private final class WiFiLoggerAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        WiFiNetworkQuality.finishBeforeTermination()
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
        !session.samples.isEmpty || !session.networkQualityMarkers.isEmpty || !session.gatewayProbes.isEmpty
            || !recording.modulationSnapshots.isEmpty
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
        .task(id: captureID) {
            await recording.captureGateway(id: captureID)
        }
        .task(id: recording.networkQualityState.runID) { [id = recording.networkQualityState.runID] in
            await recording.runNetworkQuality(id: id)
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
            WiFiRecordingView(recording: recording, accessPointDirectory: accessPoints.directory,
                              locationStatus: location.status, requestLocation: location.request)
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
            ? String(localized: "Чтобы сохранить замеры Wi-Fi и снимки модуляции, нажмите «Отмена», приостановите запись и выберите нужные пункты в меню «Сохранить CSV».")
            : String(localized: "Чтобы сохранить замеры Wi-Fi и снимки модуляции, нажмите «Отмена», выберите нужные пункты в меню «Сохранить CSV».")
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
                writeCSV(in: window) { try WiFiCSV.write(session, to: destination) }
            case .modulation:
                panel.orderOut(nil)
                let snapshots = recording.modulationSnapshots
                writeCSV(in: window) {
                    try WiFiCSV.encodeModulation(snapshots).write(to: destination, options: .atomic)
                }
            }
        }
    }

    private func writeCSV(in window: NSWindow, write: @escaping @Sendable () throws -> Void) {
        let progress = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 90),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        progress.contentView = NSHostingView(rootView: ProgressView("Сохранение CSV…").padding(20))
        window.beginSheet(progress)

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                try write()
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
            alert.addButton(withTitle: String(localized: "OK"))
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
