import Combine
import Foundation

enum WiFiLoggerTab: Hashable {
    case recording
    case modulation
}

@MainActor
final class WiFiRecording: ObservableObject {
    typealias MeasureNetworkQuality = @MainActor @Sendable (String, @escaping @Sendable (WiFiNetworkQualityMarker) -> Void)
        async throws -> WiFiNetworkQuality

    private struct Inspection {
        let uptime: TimeInterval
        let date: Date
        let modulationIndex: Int?
        var isGateway = false
    }

    private struct TimelineFocus {
        let endUptime: TimeInterval
        let inspection: Inspection?
    }

    private let modulationReader = WiFiModulationReader(spatialStreamsCommand: WiFiSpatialStreams.helperCommand)
    private var activeCapture: WiFiCaptureBuffer?
    // Recording can change while a process marker is waiting for the main actor.
    private var networkQualityCaptureTransitions: [(uptime: TimeInterval, sessionID: UUID, isRecording: Bool)]?
    // Publishing the value itself retains its arrays during every mutation.
    private(set) var session: WiFiSession
    @Published private(set) var modulationSnapshots: [WiFiModulationSnapshot] = []
    @Published private(set) var modulationReadingUnavailable = false
    @Published private(set) var networkQualityState: WiFiNetworkQualityState = .idle
    @Published var tab: WiFiLoggerTab = .recording
    @Published private(set) var captureID: UUID?
    @Published private var preview: WiFiSample?
    @Published private var timelineFocus: TimelineFocus?
    @Published private(set) var chartTrends: Set<WiFiTrend> = [.signal, .noise, .gatewayRTT]
    @Published private(set) var chartSpan: WiFiChartSpan = .fiveMinutes

    init(session: WiFiSession = WiFiSession(), modulationSnapshots: [WiFiModulationSnapshot] = []) {
        self.session = session
        self.modulationSnapshots = modulationSnapshots
    }

    var latestSample: WiFiSample? { session.samples.last ?? preview }

    var isRecording: Bool { captureID != nil }

    var isShowingHistory: Bool { timelineFocus != nil }

    var inspectedAt: Date? { timelineFocus?.inspection?.date }
    var inspectedUptime: TimeInterval? { timelineFocus?.inspection?.uptime }

    var chartLanes: [WiFiChartLane] {
        WiFiChartLane.allCases.filter { !$0.trends.allSatisfy { !chartTrends.contains($0) } }
    }

    func setChartTrend(_ trend: WiFiTrend, visible: Bool) {
        var selection = chartTrends
        if visible {
            if WiFiTrend.rightAxisTrends.contains(trend) { selection.subtract(WiFiTrend.rightAxisTrends) }
            selection.insert(trend)
        } else if selection.count > 1 {
            selection.remove(trend)
        }
        if selection != chartTrends { chartTrends = selection }
    }

    // Radio samples use the session's normalized axis. Other readings carry monotonic timestamps.
    var chartOrigin: TimeInterval {
        session.samples.first?.monotonicTime ?? modulationSnapshots.first?.startedUptime
            ?? session.networkQualityMarkers.first?.uptime ?? session.gatewayProbes.first?.uptime ?? 0
    }

    private var liveUptime: TimeInterval {
        let radioEnd = chartOrigin + (session.chartTimes.last ?? 0)
        return max(radioEnd, modulationSnapshots.last?.lastObservationUptime ?? radioEnd,
                   session.networkQualityMarkers.last?.uptime ?? radioEnd, session.gatewayProbes.last?.uptime ?? radioEnd)
    }

    var timelineUptimes: ClosedRange<TimeInterval> {
        let origin = chartOrigin
        let first = min(origin, modulationSnapshots.first?.startedUptime ?? origin,
                        session.networkQualityMarkers.first?.uptime ?? origin, session.gatewayProbes.first?.uptime ?? origin)
        let end = min(liveUptime, max(first, timelineFocus?.endUptime ?? liveUptime))
        return max(first, end - chartSpan.seconds)...end
    }

    var timelinePlotUptimes: ClosedRange<TimeInterval> {
        plotTimes(for: timelineUptimes)
    }

    var visibleNetworkQualityMarkers: [WiFiNetworkQualityMarker] {
        let window = timelineUptimes
        let markers = session.networkQualityMarkers
        let first = markers.partitionIndex { $0.uptime >= window.lowerBound }
        let end = markers.partitionIndex { $0.uptime > window.upperBound }
        return Array(markers[first..<end])
    }

    var visibleGatewayProbes: [WiFiGatewayProbe] {
        Array(session.gatewayProbes[gatewayWindow])
    }

    private var gatewayWindow: Range<Int> {
        let window = timelineUptimes
        let probes = session.gatewayProbes
        let first = probes.partitionIndex { $0.uptime >= window.lowerBound }
        let end = probes.partitionIndex { $0.uptime > window.upperBound }
        return first..<end
    }

    var displayedGatewayProbe: WiFiGatewayProbe? {
        let probes = session.gatewayProbes[gatewayWindow]
        let inspection = timelineFocus?.inspection
        let radioIndex = inspection == nil ? chartWindow.samples.last : selectedIndex
        let latestRadio = radioIndex.map { chartOrigin + session.chartTimes[$0] }
        let cursor = inspection?.uptime ?? (chartTrends == [.gatewayRTT] ? nil : latestRadio)
        guard let cursor else { return probes.last }
        let end = probes.partitionIndex { $0.uptime > cursor }
        guard end > probes.startIndex else { return nil }
        let probe = probes[end - 1]
        guard cursor - probe.uptime <= 1.5 else { return nil }
        if inspection?.isGateway != true, let index = radioIndex {
            let segment = session.segmentIDs[index]
            let start = session.segmentIDs.partitionIndex { $0 >= segment }
            guard probe.uptime >= session.samples[start].monotonicTime else { return nil }
        }
        return probe
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
        let time = inspection.uptime - chartOrigin
        guard let index = session.sampleIndex(nearest: time, in: chartWindow.samples) else { return nil }
        if inspection.isGateway, abs(session.chartTimes[index] - time) > 0.5 { return nil }
        return index
    }

    var radioCursorIndex: Int? {
        guard let index = selectedIndex, let inspectedUptime,
              chartOrigin + session.chartTimes[index] == inspectedUptime else { return nil }
        return index
    }

    var selectedModulationIndex: Int? {
        guard let inspection = timelineFocus?.inspection else { return nil }
        let window = modulationWindow
        if let index = inspection.modulationIndex, window.contains(index) { return index }
        return modulationSnapshots[window].nearestIndex(to: inspection.uptime, time: \.finishedUptime)
    }

    var displayedSample: WiFiSample? {
        if let selectedIndex, session.samples.indices.contains(selectedIndex) {
            return session.samples[selectedIndex]
        }
        if timelineFocus?.inspection?.isGateway == true { return nil }
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
            networkQualityCaptureTransitions?.append((WiFiMonotonicClock.now, session.id, false))
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

    func selectGatewayProbe(_ probe: WiFiGatewayProbe) {
        let window = timelineUptimes
        guard window.contains(probe.uptime) else { return }
        timelineFocus = TimelineFocus(endUptime: window.upperBound,
            inspection: Inspection(uptime: probe.uptime, date: probe.time, modulationIndex: nil, isGateway: true))
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
        objectWillChange.send()
        session = WiFiSession()
        modulationSnapshots = []
        preview = nil
        startCapture()
    }

    private func startCapture() {
        returnToLatest()
        modulationReadingUnavailable = false
        networkQualityCaptureTransitions?.append((WiFiMonotonicClock.now, session.id, true))
        captureID = UUID()
    }

    @discardableResult
    func requestNetworkQuality() -> UUID? {
        guard networkQualityState.runID == nil else { return nil }
        let id = UUID()
        networkQualityState = .running(id)
        return id
    }

    func runNetworkQuality(id: UUID?) async {
        await runNetworkQuality(id: id, interfaceName: { await WiFiRadioReader.shared.interfaceName },
                                measure: WiFiNetworkQuality.measure)
    }

    func runNetworkQuality(id: UUID?, interfaceName: @MainActor () async -> String?,
                           measure: MeasureNetworkQuality) async {
        guard let id, networkQualityState.runID == id, networkQualityCaptureTransitions == nil else { return }
        networkQualityCaptureTransitions = [(WiFiMonotonicClock.now, session.id, isRecording)]
        defer {
            networkQualityCaptureTransitions = nil
            if networkQualityState.runID == id { networkQualityState = .idle }
        }
        guard !Task.isCancelled else { return }
        guard let interface = await interfaceName() else {
            if !Task.isCancelled { networkQualityState = .failed(.noInterface) }
            return
        }
        guard !Task.isCancelled else { return }
        let (markers, continuation) = AsyncStream.makeStream(of: WiFiNetworkQualityMarker.self)
        async let outcome = Self.measureNetworkQuality(on: interface, measure: measure, markers: continuation)
        var startedSessionID: UUID?
        for await marker in markers {
            guard let capture = networkQualityCaptureTransitions?.last(where: { $0.uptime <= marker.uptime }) else { continue }
            if marker.kind == .started { startedSessionID = capture.sessionID }
            guard capture.isRecording, capture.sessionID == session.id, capture.sessionID == startedSessionID else { continue }
            objectWillChange.send()
            session.append(marker)
        }
        let state = await outcome
        if !Task.isCancelled { networkQualityState = state }
    }

    private static func measureNetworkQuality(on interface: String, measure: MeasureNetworkQuality,
                                              markers: AsyncStream<WiFiNetworkQualityMarker>.Continuation) async -> WiFiNetworkQualityState {
        defer { markers.finish() }
        do {
            return .measured(try await measure(interface) { markers.yield($0) })
        } catch {
            let timedOut = (error as? WiFiDiagnosticCommand.ReadError) == .timedOut
            return .failed(timedOut ? .timedOut : .failed)
        }
    }

    func captureModulation(id: UUID?) async {
        await captureModulation(id: id) {
            guard let interfaceName = await WiFiRadioReader.shared.interfaceName else { return nil }
            return try await modulationReader.read(interfaceName: interfaceName)
        }
    }

    func captureGateway(id: UUID?) async {
        await captureGateway(id: id) {
            let interfaceName = await WiFiRadioReader.shared.interfaceName
            return await WiFiGatewayProbe.measure(interfaceName: interfaceName)
        }
    }

    func captureGateway(id: UUID?, read: @MainActor () async -> WiFiGatewayProbe) async {
        guard let id else { return }
        while captureID == id, !Task.isCancelled {
            let nextProbe = ContinuousClock.now + .seconds(1)
            var probe = await read()
            guard captureID == id, !Task.isCancelled else { return }
            probe.captureID = id
            objectWillChange.send()
            session.append(probe)
            do { try await Task.sleep(until: nextProbe, clock: .continuous) } catch { return }
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
            objectWillChange.send()
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
