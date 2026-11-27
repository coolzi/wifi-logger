import Foundation
import Testing

@testable import WiFiLogger

@Test func gatewayRouteMustBeIPv4OnTheMeasuredInterface() {
    let route = """
        route to: default
        destination: default
        mask: default
        gateway: 192.0.2.1
        interface: en9
        flags: <UP,GATEWAY,DONE,STATIC,IFSCOPE>
        """
    #expect(WiFiGatewayProbe.gateway(in: route, interfaceName: "en9") == "192.0.2.1")
    #expect(WiFiGatewayProbe.gateway(in: route, interfaceName: "en8") == nil)
    #expect(WiFiGatewayProbe.gateway(in: route.replacingOccurrences(of: "192.0.2.1", with: "link#4"),
                                     interfaceName: "en9") == nil)
}

@Test func gatewayPingSeparatesReplyTimeoutAndLocalFailure() {
    let reply = "64 bytes from 192.0.2.1: icmp_seq=0 ttl=64 time=4.438 ms"
    let timeout = "1 packets transmitted, 0 packets received, 100.0% packet loss"
    #expect(WiFiGatewayProbe.result(in: reply, from: "192.0.2.1") == .reply(4.438))
    #expect(WiFiGatewayProbe.result(in: timeout, from: "192.0.2.1") == .timeout)
    #expect(WiFiGatewayProbe.result(in: "ping: sendto: No route to host\n" + timeout, from: "192.0.2.1") == .unavailable)
    #expect(WiFiGatewayProbe.result(in: "", from: "192.0.2.1") == .unavailable)
    #expect(WiFiGatewayProbe.result(in: reply, from: "192.0.2.2") == .unavailable)
    #expect(WiFiGatewayProbe.result(in: "internal diagnostic: elapsed time=4.438 ms", from: "192.0.2.1") == .unavailable)
}

@Test func gatewayPingRetainsDiagnosticsWhenNoEchoReplyArrives() throws {
    let diagnostic = "ping: sendto: No route to host"
    let command = WiFiDiagnosticCommand(executablePath: "/bin/sh",
        arguments: ["-c", "printf '%s\\n' \"$1\" >&2; exit 2", "fixture", diagnostic],
        timeout: .seconds(2), outputLimit: 1024)

    let output = try command.capture(acceptedExitCodes: [0, 2], includeStandardError: true)
    #expect(String(decoding: output, as: UTF8.self) == diagnostic + "\n")
    #expect(WiFiGatewayProbe.result(in: String(decoding: output, as: UTF8.self), from: "192.0.2.1") == .unavailable)
    #expect(throws: WiFiDiagnosticCommand.ReadError.commandFailed) { try command.capture() }
}

@Test(arguments: [false, true])
@MainActor func gatewayProbeDiscardsAResultFromAnOldCapture(reset: Bool) async throws {
    let recording = WiFiRecording()
    recording.toggle()
    let id = try #require(recording.captureID)

    await recording.captureGateway(id: id) {
        if reset { recording.restart() } else { recording.toggle() }
        return WiFiGatewayProbe(result: .timeout)
    }

    #expect(recording.session.gatewayProbes.isEmpty)
    #expect(recording.session.outages.count == 0)
}

@Test @MainActor func gatewayProbesUseTheSameWindowAsRadioSamples() {
    var session = WiFiSession()
    for seconds in [100.0, 120.0, 150.0, 160.0] {
        let time = Date(timeIntervalSince1970: seconds)
        session.append(WiFiSample(time: time, monotonicTime: seconds, state: .connected,
                                  measurements: WiFiMeasurements()))
        session.append(WiFiGatewayProbe(result: .timeout, time: time, uptime: seconds))
    }
    let recording = WiFiRecording(session: session)
    recording.changeChartSpan(.thirtySeconds)
    #expect(recording.timelineUptimes == 130...160)
    #expect(recording.visibleGatewayProbes.map(\.uptime) == [150, 160])
    #expect(recording.session.outages.count == 0)

    recording.moveRadioWindow(to: 1)
    #expect(recording.visibleGatewayProbes.map(\.uptime) == [100, 120])
}
