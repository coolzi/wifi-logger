import Darwin
import Foundation
import os

struct WiFiGatewayProbe: Equatable, Identifiable, Sendable {
    enum Result: Equatable, Sendable {
        case reply(Double)
        case timeout
        case unavailable

        var displayLabel: String {
            switch self {
            case .reply(let rtt):
                String(localized: "RTT \(rtt.formatted(.number.precision(.fractionLength(0...2)))) мс")
            case .timeout:
                String(localized: "Шлюз не ответил")
            case .unavailable:
                String(localized: "Замер недоступен")
            }
        }
    }

    private static let worker = DispatchQueue(label: "wifi-logger.gateway", qos: .utility)
    private static let localAccessRequested = OSAllocatedUnfairLock(initialState: false)

    let result: Result
    var time: Date = .now
    var uptime: TimeInterval = WiFiMonotonicClock.now
    var captureID: UUID? = nil

    var id: TimeInterval { uptime }

    static func measure(interfaceName: String?) async -> Self {
        guard let interfaceName else { return Self(result: .unavailable) }
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                worker.async {
                    let probe = measure(interfaceName: interfaceName, isCancelled: { cancelled.withLock { $0 } })
                    continuation.resume(returning: probe)
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    static func measure(interfaceName: String, isCancelled: () -> Bool) -> Self {
        let route = WiFiDiagnosticCommand(executablePath: "/sbin/route",
            arguments: ["-n", "get", "-inet", "-ifscope", interfaceName, "default"],
            timeout: .milliseconds(500), outputLimit: 8192)
        guard let routeData = try? route.capture(isCancelled: isCancelled),
              let address = gateway(in: String(decoding: routeData, as: UTF8.self), interfaceName: interfaceName) else {
            return Self(result: .unavailable)
        }
        if #available(macOS 15, *), !isCancelled() {
            let shouldRequest = localAccessRequested.withLock { requested in
                guard !requested else { return false }
                requested = true
                return true
            }
            if shouldRequest { requestLocalAccess(to: address, interfaceName: interfaceName) }
        }

        let ping = WiFiDiagnosticCommand(executablePath: "/sbin/ping",
            arguments: ["-n", "-b", interfaceName, "-c", "1", "-t", "1", address],
            timeout: .milliseconds(1500), outputLimit: 8192)
        let time = Date.now
        let uptime = WiFiMonotonicClock.now
        let output = try? ping.capture(acceptedExitCodes: [0, 2], includeStandardError: true, isCancelled: isCancelled)
        let result = output.map { Self.result(in: String(decoding: $0, as: UTF8.self), from: address) } ?? .unavailable
        return Self(result: result, time: time, uptime: uptime)
    }

    private static func requestLocalAccess(to address: String, interfaceName: String) {
        var index = if_nametoindex(interfaceName)
        guard index != 0 else { return }
        // A gateway that is also a DNS server can be exempt from the privacy check.
        requestLinkLocalAccess(interfaceIndex: index)

        let addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        var target = sockaddr_in()
        target.sin_len = UInt8(addressLength)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = UInt16(9).bigEndian
        guard inet_pton(AF_INET, address, &target.sin_addr) == 1 else { return }

        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        guard setsockopt(descriptor, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size)) == 0 else {
            return
        }
        // Connecting a UDP socket prompts from the app's own process without sending a datagram (TN3179).
        withUnsafePointer(to: &target) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = Darwin.connect(descriptor, $0, addressLength)
            }
        }
    }

    private static func requestLinkLocalAccess(interfaceIndex: UInt32) {
        let addressLength = socklen_t(MemoryLayout<sockaddr_in6>.size)
        var target = sockaddr_in6()
        target.sin6_len = UInt8(addressLength)
        target.sin6_family = sa_family_t(AF_INET6)
        target.sin6_port = UInt16(9).bigEndian
        target.sin6_scope_id = interfaceIndex
        guard inet_pton(AF_INET6, "fe80::", &target.sin6_addr) == 1 else { return }
        withUnsafeMutableBytes(of: &target.sin6_addr) { bytes in
            for offset in 8..<bytes.count { bytes[offset] = UInt8.random(in: .min ... .max) }
        }

        let descriptor = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        withUnsafePointer(to: &target) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = Darwin.connect(descriptor, $0, addressLength)
            }
        }
    }

    static func gateway(in output: String, interfaceName: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        func field(_ prefix: String) -> String? {
            lines.first(where: { $0.hasPrefix(prefix) })?.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        }
        guard field("interface:") == interfaceName, let address = field("gateway:") else { return nil }
        var parsed = in_addr()
        guard inet_pton(AF_INET, address, &parsed) == 1, parsed.s_addr != INADDR_ANY else { return nil }
        return address
    }

    static func result(in output: String, from address: String) -> Result {
        let lines = output.split(whereSeparator: \.isNewline)
        // A send error can still be followed by a 100% loss summary.
        if lines.contains(where: { $0.hasPrefix("ping:") }) { return .unavailable }
        // The socket is bound for sending. Validate the numeric sender in the reply as well.
        if let reply = lines.first(where: { $0.contains(" bytes from \(address): icmp_seq=0 ") }),
           let match = reply.firstMatch(of: /\btime=([0-9]+(?:\.[0-9]+)?) ms/),
           let milliseconds = Double(match.1), milliseconds.isFinite {
            return .reply(milliseconds)
        }
        if output.contains("1 packets transmitted, 0 packets received, 100.0% packet loss") { return .timeout }
        return .unavailable
    }
}
