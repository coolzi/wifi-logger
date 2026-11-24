import Combine
import Foundation

enum WiFiLoggerTab: Hashable {
    case recording
    case modulation
}

@MainActor
final class WiFiRecording: ObservableObject {
    private struct Inspection {
        let uptime: TimeInterval
        let date: Date
        let modulationIndex: Int?
    }

    private struct TimelineFocus {
        let endUptime: TimeInterval
        let inspection: Inspection?
    }

    private let modulationReader = WiFiModulationReader(spatialStreamsCommand: WiFiSpatialStreams.helperCommand)
    private var activeCapture: WiFiCaptureBuffer?
    @Published private(set) var session = WiFiSession()
    @Published private(set) var modulationSnapshots: [WiFiModulationSnapshot] = []
    @Published private(set) var modulationReadingUnavailable = false
    @Published var tab: WiFiLoggerTab = .recording
    @Published private(set) var captureID: UUID?
    @Published private var preview: WiFiSample?
    @Published private var timelineFocus: TimelineFocus?
    @Published var chartMode: WiFiChartMode = .signalAndNoise
    @Published private(set) var chartSpan: WiFiChartSpan = .fiveMinutes

    init(session: WiFiSession = WiFiSession(), modulationSnapshots: [WiFiModulationSnapshot] = []) {
        self.session = session
        self.modulationSnapshots = modulationSnapshots
    }

    var latestSample: WiFiSample? { session.samples.last ?? preview }

    var isRecording: Bool { captureID != nil }

    var isShowingHistory: Bool { timelineFocus != nil }

    var inspectedAt: Date? { timelineFocus?.inspection?.date }

    var chartReadouts: (primary: [WiFiTrend], secondary: [WiFiTrend]) {
        let radioMetrics: [WiFiTrend] = [.signal, .noise, .snr]
        let primary = chartMode == .signalAndNoise ? radioMetrics : chartMode.trends
        let secondary = selectedIndex == nil ? [] : radioMetrics.filter { !primary.contains($0) }
        return (primary, secondary)
    }

    // CoreWLAN uses the session's normalized axis, whereas profiler requests
    // carry absolute monotonic stamps. Both are aligned to the first radio sample.
    private var chartOrigin: TimeInterval {
        session.samples.first?.monotonicTime ?? modulationSnapshots.first?.startedUptime ?? 0
    }

    private var liveUptime: TimeInterval {
        let radioEnd = chartOrigin + (session.chartTimes.last ?? 0)
        return max(radioEnd, modulationSnapshots.last?.lastObservationUptime ?? radioEnd)
    }

    var timelineUptimes: ClosedRange<TimeInterval> {
        let origin = chartOrigin
        let first = min(origin, modulationSnapshots.first?.startedUptime ?? origin)
        let end = min(liveUptime, max(first, timelineFocus?.endUptime ?? liveUptime))
        return max(first, end - chartSpan.seconds)...end
    }

    var timelinePlotUptimes: ClosedRange<TimeInterval> {
        plotTimes(for: timelineUptimes)
    }

    var chartWindow: WiFiChartWindow {
        let observed = timelineUptimes
        let origin = chartOrigin
        // Allow one floating-point step when translating normalized radio times.
        let first = session.chartTimes.partitionIndex { origin + $0 >= observed.lowerBound.nextDown }
        let end = session.chartTimes.partitionIndex { origin + $0 > observed.upperBound.nextUp }
        let domain = plotTimes(for: observed)
        var startTime = domain.lowerBound - origin
        var endTime = domain.upperBound - origin
        if first < end {
            // Preserve boundary points if translating the domain rounds by a ULP.
            startTime = min(startTime, session.chartTimes[first])
            endTime = max(endTime, session.chartTimes[end - 1])
        }
        return WiFiChartWindow(samples: first..<end, times: startTime...endTime)
    }

    var modulationWindow: Range<Int> {
        let observed = timelineUptimes
        let first = modulationSnapshots.partitionIndex { $0.lastObservationUptime >= observed.lowerBound }
        let end = modulationSnapshots.partitionIndex { $0.finishedUptime > observed.upperBound }
        return first..<end
    }

    var selectedIndex: Int? {
        guard let inspection = timelineFocus?.inspection else { return nil }
        return session.sampleIndex(nearest: inspection.uptime - chartOrigin, in: chartWindow.samples)
    }

    var selectedModulationIndex: Int? {
        guard let inspection = timelineFocus?.inspection else { return nil }
        let window = modulationWindow
        guard !window.isEmpty else { return nil }
        if let index = inspection.modulationIndex, window.contains(index) { return index }
        let right = modulationSnapshots[window].partitionIndex { $0.finishedUptime >= inspection.uptime }
        if right == window.lowerBound { return right }
        if right == window.upperBound { return right - 1 }
        let leftDistance = inspection.uptime - modulationSnapshots[right - 1].finishedUptime
        let rightDistance = modulationSnapshots[right].finishedUptime - inspection.uptime
        return leftDistance <= rightDistance ? right - 1 : right
    }

    var displayedSample: WiFiSample? {
        if let selectedIndex, session.samples.indices.contains(selectedIndex) {
            return session.samples[selectedIndex]
        }
        if timelineFocus == nil, session.samples.isEmpty, modulationSnapshots.isEmpty { return preview }
        return chartWindow.samples.last.map { session.samples[$0] }
    }

    func refreshPreview() async {
        guard session.samples.isEmpty, !Task.isCancelled else { return }
        let sessionID = session.id
        let sample = await WiFiRadioReader.shared.sample()
        guard !Task.isCancelled, session.id == sessionID, session.samples.isEmpty else { return }
        if let preview, sample.monotonicTime < preview.monotonicTime { return }
        preview = sample
    }

    func snapshotForExport() -> WiFiSession {
        if let capture = activeCapture { appendPending(from: capture) }
        return session
    }

    func toggle() {
        if isRecording {
            if let capture = closeCapture() { appendPending(from: capture) }
            captureID = nil
        } else {
            startCapture()
        }
    }

    func changeChartSpan(_ span: WiFiChartSpan) {
        chartSpan = span
        if let focus = timelineFocus, let inspection = focus.inspection, !timelineUptimes.contains(inspection.uptime) {
            timelineFocus = TimelineFocus(endUptime: focus.endUptime, inspection: nil)
        }
    }

    func returnToLatest() {
        timelineFocus = nil
    }

    func selectRadioSample(_ index: Int) {
        guard chartWindow.samples.contains(index) else { return }
        inspectRadio(at: index, endUptime: timelineUptimes.upperBound)
    }

    func selectRadioEvent(_ index: Int) {
        guard session.samples.indices.contains(index) else { return }
        let uptime = chartOrigin + session.chartTimes[index]
        let window = timelineUptimes
        let end = window.contains(uptime) ? window.upperBound : min(liveUptime, uptime + chartSpan.seconds / 2)
        inspectRadio(at: index, endUptime: end)
    }

    func moveRadioWindow(to index: Int) {
        guard session.samples.indices.contains(index) else { return }
        let uptime = chartOrigin + session.chartTimes[index]
        if index == session.samples.indices.last, uptime >= liveUptime - chartSpan.seconds {
            returnToLatest()
        } else {
            timelineFocus = TimelineFocus(endUptime: uptime, inspection: nil)
        }
    }

    func selectModulationSnapshot(_ index: Int, atNSS: Bool = false) {
        guard modulationSnapshots.indices.contains(index) else { return }
        let snapshot = modulationSnapshots[index]
        let nss = atNSS ? snapshot.spatialStreams : nil
        let uptime = nss?.receivedUptime ?? snapshot.finishedUptime
        let date = nss?.receivedAt ?? snapshot.finishedAt
        let window = timelineUptimes
        let end = window.contains(uptime) ? window.upperBound : uptime
        timelineFocus = TimelineFocus(endUptime: end,
            inspection: Inspection(uptime: uptime, date: date, modulationIndex: index))
    }

    private func inspectRadio(at index: Int, endUptime: TimeInterval) {
        let inspection = Inspection(uptime: chartOrigin + session.chartTimes[index],
                                    date: session.samples[index].time, modulationIndex: nil)
        timelineFocus = TimelineFocus(endUptime: endUptime, inspection: inspection)
    }

    private func plotTimes(for observed: ClosedRange<TimeInterval>) -> ClosedRange<TimeInterval> {
        observed.lowerBound...max(observed.upperBound, observed.lowerBound + 5)
    }

    func restart() {
        _ = closeCapture()
        session = WiFiSession()
        modulationSnapshots = []
        preview = nil
        startCapture()
    }

    private func startCapture() {
        returnToLatest()
        modulationReadingUnavailable = false
        captureID = UUID()
    }

    func captureModulation(id: UUID?) async {
        await captureModulation(id: id) {
            guard let interfaceName = await WiFiRadioReader.shared.interfaceName else { return nil }
            return try await modulationReader.read(interfaceName: interfaceName)
        }
    }

    func captureModulation(id: UUID?, read: @MainActor () async throws -> WiFiModulationSnapshot?) async {
        guard let id else { return }
        while captureID == id, !Task.isCancelled {
            let result: Result<WiFiModulationSnapshot?, Error>
            do { result = .success(try await read()) } catch { result = .failure(error) }
            guard captureID == id, !Task.isCancelled else { return }
            let interval = 2.0
            var delay = interval
            switch result {
            case .success(let snapshot):
                if let snapshot {
                    modulationSnapshots.append(snapshot)
                    // The NSS helper runs in the gap after the profiler finishes.
                    let elapsed = max(0, WiFiMonotonicClock.now - snapshot.finishedUptime)
                    delay = max(0, interval - elapsed)
                }
                let unavailable = snapshot?.mcs == nil
                if unavailable != modulationReadingUnavailable { modulationReadingUnavailable = unavailable }
            case .failure(let error as WiFiModulationReader.ReadError) where error == .requestInProgress:
                break
            case .failure:
                if !modulationReadingUnavailable { modulationReadingUnavailable = true }
            }
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        }
    }

    func capture(id: UUID?) async {
        guard let id, captureID == id, !Task.isCancelled else { return }
        if let previous = activeCapture {
            guard !previous.isOpen else { return }
            appendPending(from: previous)
        }

        let capture = WiFiCaptureBuffer()
        activeCapture = capture
        await withTaskCancellationHandler {
            let producer = Task { await WiFiRadioReader.shared.capture(into: capture) }
            defer {
                producer.cancel()
                capture.finish()
                if activeCapture === capture {
                    appendPending(from: capture)
                    activeCapture = nil
                }
            }
            for await _ in capture.updates {
                guard activeCapture === capture, !Task.isCancelled else { return }
                appendPending(from: capture)
            }
        } onCancel: {
            capture.finish()
        }
    }

    private func appendPending(from capture: WiFiCaptureBuffer) {
        if let batch = capture.drain() {
            session.append(contentsOf: batch.samples, startsSegment: batch.startsSegment)
        }
    }

    private func closeCapture() -> WiFiCaptureBuffer? {
        let capture = activeCapture
        capture?.finish()
        activeCapture = nil
        return capture
    }
}
