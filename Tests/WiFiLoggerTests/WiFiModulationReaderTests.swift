import Darwin
import Foundation
import Testing

@testable import WiFiLogger

@Suite struct WiFiModulationReaderTests {
    private static let report = """
        {
          "SPAirPortDataType": [
            {"_name": "software"},
            {"spairport_airport_interfaces": [
              {"_name": "en1", "spairport_current_network_information": {},
               "spairport_airport_other_local_wireless_networks": [{"spairport_network_mcs": 9}]},
              {"_name": "en0", "spairport_current_network_information": {
                "_name": "example", "spairport_network_bssid": "00:00:00:00:00:00",
                "spairport_network_channel": "60 (5GHz, 40MHz)", "spairport_network_mcs": 11,
                "spairport_network_phymode": "802.11ax", "spairport_network_rate": 573
              }}
            ]}
          ]
        }
        """

    private static func reader(report: String, helper: WiFiDiagnosticCommand? = nil,
                               readBSSID: @escaping @MainActor @Sendable (String) -> String? = { _ in nil }) -> WiFiModulationReader {
        WiFiModulationReader(executablePath: "/usr/bin/printf", arguments: ["%s", report],
                             spatialStreamsCommand: helper, readBSSID: { await readBSSID($0) })
    }

    @Test func readsOnlyTheCurrentNetworkOnTheRequestedInterface() async throws {
        let reader = Self.reader(report: Self.report)
        let before = WiFiMonotonicClock.now
        let snapshot = try #require(await reader.read(interfaceName: "en0"))
        let after = WiFiMonotonicClock.now
        #expect(snapshot.interfaceName == "en0")
        #expect(snapshot.startedUptime >= before)
        #expect(snapshot.finishedUptime >= snapshot.startedUptime)
        #expect(snapshot.finishedUptime <= after)
        #expect(snapshot.phyMode == "802.11ax")
        #expect(snapshot.channel?.band == .ghz5)
        #expect(snapshot.channel?.number == 60)
        #expect(snapshot.channel?.width == 40)
        #expect(snapshot.mcs == 11)
        #expect(snapshot.transmitRateMbps == 573)
        #expect(snapshot.modulation == "1024-QAM")
        #expect(snapshot.coding == "5/6")
        #expect(try await reader.read(interfaceName: "en1") == nil)
        #expect(try await reader.read(interfaceName: "en2") == nil)
    }

    @Test func preservesPartialDataAndDoesNotGuessForUnknownPHY() async throws {
        let report = """
            {"SPAirPortDataType": [{"spairport_airport_interfaces": [
              {"_name": "en0", "spairport_current_network_information": {
                "spairport_network_channel": "11 (2.4 GHz)", "spairport_network_mcs": "0",
                "spairport_network_phymode": "802.11future", "spairport_network_rate": "54.5"
              }},
              {"_name": "en1", "spairport_current_network_information": {
                "spairport_network_mcs": true, "spairport_network_rate": 0,
                "spairport_network_phymode": "802.11ac", "spairport_network_channel": "unknown"
              }}
            ]}]}
            """
        let reader = Self.reader(report: report)
        let snapshot = try #require(await reader.read(interfaceName: "en0"))
        #expect(snapshot.phyMode == "802.11future")
        #expect(snapshot.mcs == 0)
        #expect(snapshot.transmitRateMbps == 54.5)
        #expect(snapshot.channel?.number == 11)
        #expect(snapshot.channel?.band == .ghz2Point4)
        #expect(snapshot.channel?.width == nil)
        #expect(snapshot.modulation == nil)
        #expect(snapshot.coding == nil)

        let partial = try #require(await reader.read(interfaceName: "en1"))
        #expect(partial.phyMode == "802.11ac")
        #expect(partial.mcs == nil)
        #expect(partial.channel == nil)
        #expect(partial.transmitRateMbps == nil)
    }

    @Test func decodesMCSOnlyWithinThePHYsKnownRange() {
        let cases: [(String, Int, String?, String?)] = [
            ("802.11n", 11, "16-QAM", "1/2"),
            ("802.11n", 32, "BPSK", "1/2"),
            ("802.11n", 33, nil, nil),
            ("802.11ac", 9, "256-QAM", "5/6"),
            ("802.11ac", 10, nil, nil),
            ("802.11ax", 0, "BPSK", "1/2"),
            ("802.11ax", 12, nil, nil),
            ("802.11be", 13, "4096-QAM", "5/6"),
            ("802.11be", 16, nil, nil),
        ]
        for (phyMode, mcs, modulation, coding) in cases {
            let snapshot = WiFiModulationSnapshot(
                interfaceName: "en0", startedAt: .now, finishedAt: .now,
                startedUptime: 0, finishedUptime: 1, phyMode: phyMode,
                channel: nil, mcs: mcs, transmitRateMbps: nil
            )
            #expect(snapshot.modulation == modulation, "\(phyMode) MCS \(mcs)")
            #expect(snapshot.coding == coding, "\(phyMode) MCS \(mcs)")
        }
    }

    @Test func resolvesBitsPerSymbolFromTheModulationAndNotTheCodingRate() {
        let examples: [(String, Int, Int?)] = [
            ("802.11ax", 0, 1), ("802.11ax", 2, 2), ("802.11ax", 4, 4),
            ("802.11ax", 7, 6), ("802.11ax", 9, 8), ("802.11ax", 10, 10),
            ("802.11ax", 11, 10), ("802.11be", 13, 12), ("802.11be", 15, nil),
        ]
        for (phyMode, mcs, bits) in examples {
            let snapshot = WiFiModulationSnapshot(
                interfaceName: "en0", startedAt: .now, finishedAt: .now,
                startedUptime: 0, finishedUptime: 1, phyMode: phyMode,
                channel: nil, mcs: mcs, transmitRateMbps: nil
            )
            #expect(snapshot.modulationType?.bitsPerSymbol == bits, "\(phyMode) MCS \(mcs)")
        }
    }

    @Test func resolvesTheInformationBitFractionForEachKnownCodingRate() {
        let examples: [(String, Int, Double?)] = [
            ("802.11ax", 0, 1.0 / 2), ("802.11ax", 5, 2.0 / 3),
            ("802.11ax", 10, 3.0 / 4), ("802.11ax", 11, 5.0 / 6),
            ("802.11be", 15, nil),
        ]
        for (phyMode, mcs, fraction) in examples {
            let snapshot = WiFiModulationSnapshot(
                interfaceName: "en0", startedAt: .now, finishedAt: .now,
                startedUptime: 0, finishedUptime: 1, phyMode: phyMode,
                channel: nil, mcs: mcs, transmitRateMbps: nil
            )
            #expect(snapshot.informationBitFraction == fraction, "\(phyMode) MCS \(mcs)")
        }
    }

    @Test func implausibleRadioValuesLeaveTheRestOfTheSnapshotUsable() async throws {
        let report = Self.report
            .replacingOccurrences(of: "\"spairport_network_mcs\": 11",
                                  with: "\"spairport_network_mcs\": 18014398509481984")
            .replacingOccurrences(of: "\"spairport_network_rate\": 573",
                                  with: "\"spairport_network_rate\": 1.7e308")
        let snapshot = try #require(await Self.reader(report: report).read(interfaceName: "en0"))
        #expect(snapshot.phyMode == "802.11ax")
        #expect(snapshot.channel?.number == 60)
        #expect(snapshot.mcs == nil)
        #expect(snapshot.transmitRateMbps == nil)
    }

    @Test func capsOutputAndRejectsNonzeroExit() async {
        let large = WiFiModulationReader(
            executablePath: "/usr/bin/head", arguments: ["-c", "131072", "/dev/zero"], outputLimit: 65536
        )
        await #expect(throws: WiFiModulationReader.ReadError.outputTooLarge) {
            _ = try await large.read(interfaceName: "en0")
        }
        let failing = WiFiModulationReader(executablePath: "/usr/bin/false", arguments: [])
        await #expect(throws: WiFiModulationReader.ReadError.commandFailed) {
            _ = try await failing.read(interfaceName: "en0")
        }
    }

    @Test func readsReportedSpatialStreamsForTheSameInterface() async throws {
        let command = WiFiDiagnosticCommand(
            executablePath: "/bin/sh", arguments: ["-c", "[ \"$1\" = en0 ] && printf '2\\n'", "helper"],
            timeout: .seconds(1), outputLimit: 16
        )
        let reader = Self.reader(report: Self.report, helper: command)
        let snapshot = try #require(await reader.read(interfaceName: "en0"))
        let nss = try #require(snapshot.spatialStreams)
        #expect(nss.count == 2)
        #expect(nss.receivedUptime > snapshot.finishedUptime)
        #expect(nss.receivedUptime <= WiFiMonotonicClock.now)
        #expect(snapshot.mcs == 11)
        #expect(snapshot.transmitRateMbps == 573)
    }

    @Test(arguments: ["", "0", "17", "2\njunk"])
    func unavailableOrInvalidSpatialStreamsLeaveASnapshot(output: String) async throws {
        let command = WiFiDiagnosticCommand(
            executablePath: "/bin/sh", arguments: ["-c", "printf '%s' \"$1\"", "helper", output],
            timeout: .seconds(1), outputLimit: 16
        )
        let reader = Self.reader(report: Self.report, helper: command)
        let snapshot = try #require(await reader.read(interfaceName: "en0"))
        #expect(snapshot.spatialStreams == nil)
        #expect(snapshot.mcs == 11)
        #expect(snapshot.transmitRateMbps == 573)
    }

    @Test(arguments: ["/bin/sleep 4", "kill -KILL $$", "printf '%020d' 2"])
    func helperProcessFailuresKeepSnapshotsAndDisableTheHelper(failure: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let attempted = directory.appendingPathComponent("attempted")
        let script = """
            if [ -f "$1" ]; then
                printf '2\\n'
                exit
            fi
            : > "$1"
            \(failure)
            """
        let command = WiFiDiagnosticCommand(
            executablePath: "/bin/sh", arguments: ["-c", script, "helper", attempted.path],
            timeout: .milliseconds(250), outputLimit: 16
        )
        let reader = Self.reader(report: Self.report, helper: command)
        let started = ContinuousClock.now
        let first = try #require(await reader.read(interfaceName: "en0"))
        #expect(started.duration(to: .now) < .seconds(2))
        try #require(FileManager.default.fileExists(atPath: attempted.path))
        let second = try #require(await reader.read(interfaceName: "en0"))
        #expect(first.spatialStreams == nil)
        #expect(second.spatialStreams == nil)
        #expect(first.mcs == 11)
        #expect(second.transmitRateMbps == 573)
    }

    @Test(arguments: ["02:00:00:00:00:02", ""])
    func dropsNSSIfAssociationChangesOrDisappears(nextBSSID: String) async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let helper = WiFiDiagnosticCommand(
            executablePath: "/bin/sh", arguments: ["-c", ": > \"$1\" && printf '2\\n'", "helper", marker.path],
            timeout: .seconds(1), outputLimit: 16
        )
        let reader = Self.reader(report: Self.report, helper: helper) { interfaceName in
            guard interfaceName == "en0" else { return nil }
            if !FileManager.default.fileExists(atPath: marker.path) { return "02:00:00:00:00:01" }
            return nextBSSID.isEmpty ? nil : nextBSSID
        }
        let first = try #require(await reader.read(interfaceName: "en0"))
        try #require(FileManager.default.fileExists(atPath: marker.path))
        #expect(first.spatialStreams == nil)
        #expect(first.mcs == 11)

        let next = try #require(await reader.read(interfaceName: "en0"))
        #expect(next.spatialStreams?.count == 2)
    }

    @Test func killsTheChildAfterTheDeadline() async {
        let reader = WiFiModulationReader(
            executablePath: "/bin/sh", arguments: ["-c", "/bin/sleep 3 & exit 0"], timeout: .milliseconds(150)
        )
        let started = ContinuousClock.now
        await #expect(throws: WiFiModulationReader.ReadError.timedOut) {
            _ = try await reader.read(interfaceName: "en0")
        }
        #expect(started.duration(to: .now) < .seconds(2))
    }

    @Test func cancellationReapsTheChildBeforeAllowingAnotherRead() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let ready = directory.appendingPathComponent("ready")
        let release = directory.appendingPathComponent("release")
        let script = """
            if [ -f "$1" ]; then
                printf '%s' "$4"
                exit
            fi
            printf '%s\\n' "$$" > "$1"
            : > "$2"
            while [ ! -f "$3" ]; do :; done
            """
        let reader = WiFiModulationReader(
            executablePath: "/bin/sh",
            arguments: ["-c", script, "sh", pidFile.path, ready.path, release.path, Self.report],
            timeout: .seconds(3)
        )
        let read = Task { try await reader.read(interfaceName: "en0") }
        defer { read.cancel() }
        let deadline = ContinuousClock.now + .seconds(2)
        while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let rawPID = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try #require(Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)))
        await #expect(throws: WiFiModulationReader.ReadError.requestInProgress) {
            _ = try await reader.read(interfaceName: "en0")
        }
        read.cancel()
        await #expect(throws: WiFiModulationReader.ReadError.requestInProgress) {
            _ = try await reader.read(interfaceName: "en0")
        }
        try Data().write(to: release)
        await #expect(throws: CancellationError.self) { _ = try await read.value }
        #expect(kill(pid, 0) == -1)
        #expect(try await reader.read(interfaceName: "en0")?.mcs == 11)
    }
}
