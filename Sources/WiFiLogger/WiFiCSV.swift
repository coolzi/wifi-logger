import Foundation

enum WiFiCSV {
    static func encode(_ session: WiFiSession, timeZone: TimeZone = .autoupdatingCurrent) -> Data {
        let channelChanges = Set(session.events.filter { $0.kind == .channelChanged }.map(\.sampleIndex))
        let summary: [String] = [
            String(session.outages.count),
            String(session.outages.totalDuration),
            String(session.outages.longestDuration),
            session.rssiVariation.minimum.map { String($0) } ?? "",
            session.rssiVariation.maximum.map { String($0) } ?? "",
            session.rssiVariation.spread.map { String($0) } ?? "",
            session.snrVariation.minimum.map { String($0) } ?? "",
            session.snrVariation.maximum.map { String($0) } ?? "",
            session.snrVariation.spread.map { String($0) } ?? "",
        ]
        // Rebasing Double clock values can move replay across the 2.5 s and 60 s boundaries.
        return encode(session.samples, timeZone: timeZone, additionalColumns: [
            "channel_changed", "previous_band", "previous_channel", "previous_channel_width_mhz",
            "session_outage_count", "session_outage_total_seconds", "session_outage_longest_seconds",
            "rssi_min_60s_dbm", "rssi_max_60s_dbm", "rssi_spread_60s_db",
            "snr_min_60s_db", "snr_max_60s_db", "snr_spread_60s_db",
            "segment_id", "monotonic_seconds", "calculation_version",
        ]) { index in
            let changed = channelChanges.contains(index)
            let previous = changed ? session.samples[index - 1].connectedMeasurements.channel : nil
            return [
                changed ? "1" : "0",
                previous?.band ?? "",
                previous?.number.map { String($0) } ?? "",
                previous?.width.map { String($0) } ?? "",
            ] + summary + [String(session.segmentIDs[index]),
                           String(session.samples[index].monotonicTime), "1"]
        }
    }

    static func encode(_ samples: [WiFiSample], timeZone: TimeZone = .autoupdatingCurrent) -> Data {
        encode(samples, timeZone: timeZone, additionalColumns: []) { _ in [] }
    }

    static func encodeModulation(_ snapshots: [WiFiModulationSnapshot],
                                 timeZone: TimeZone = .autoupdatingCurrent) -> Data {
        let timestampFormat = timestampStyle(in: timeZone)
        let columns = [
            "request_started_at", "response_received_at", "request_started_monotonic_seconds",
            "response_received_monotonic_seconds", "interface", "phy_mode", "band", "channel",
            "channel_width_mhz", "mcs", "modulation", "coding_rate", "tx_rate_mbps", "reported_spatial_streams",
            "nss_received_at", "nss_received_monotonic_seconds",
        ]
        var csv = columns.joined(separator: ",") + "\r\n"
        for snapshot in snapshots {
            let nss = snapshot.spatialStreams
            let row = [
                snapshot.startedAt.formatted(timestampFormat),
                snapshot.finishedAt.formatted(timestampFormat),
                String(snapshot.startedUptime),
                String(snapshot.finishedUptime),
                spreadsheetText(snapshot.interfaceName),
                spreadsheetText(snapshot.phyMode ?? ""),
                spreadsheetText(snapshot.channel?.band ?? ""),
                snapshot.channel?.number.map { String($0) } ?? "",
                snapshot.channel?.width.map { String($0) } ?? "",
                snapshot.mcs.map { String($0) } ?? "",
                snapshot.modulation ?? "",
                snapshot.coding ?? "",
                snapshot.transmitRateMbps.map { String($0) } ?? "",
                nss.map { String($0.count) } ?? "",
                nss.map { $0.receivedAt.formatted(timestampFormat) } ?? "",
                nss.map { String($0.receivedUptime) } ?? "",
            ]
            csv.append(contentsOf: row.map(escape).joined(separator: ","))
            csv.append(contentsOf: "\r\n")
        }
        return Data(csv.utf8)
    }

    private static func encode(_ samples: [WiFiSample], timeZone: TimeZone,
                               additionalColumns: [String], additionalFields: (Int) -> [String]) -> Data {
        let timestampFormat = timestampStyle(in: timeZone)
        let columns = [
            "timestamp", "state", "ssid", "bssid", "rssi_dbm", "noise_dbm", "snr_db",
            "band", "channel", "channel_width_mhz", "phy_mode", "tx_rate_mbps",
        ] + additionalColumns
        var csv = columns.joined(separator: ",") + "\r\n"
        for (index, sample) in samples.enumerated() {
            let fields = sample.connectedMeasurements
            let row = [
                sample.time.formatted(timestampFormat),
                sample.state.rawValue,
                spreadsheetText(fields.ssid ?? ""),
                fields.bssid ?? "",
                fields.signalDBm.map { String($0) } ?? "",
                fields.noiseDBm.map { String($0) } ?? "",
                fields.snrDB.map { String($0) } ?? "",
                fields.channel?.band ?? "",
                fields.channel?.number.map { String($0) } ?? "",
                fields.channel?.width.map { String($0) } ?? "",
                fields.phyMode ?? "",
                fields.transmitRateMbps.map { String($0) } ?? "",
            ] + additionalFields(index)
            csv.append(contentsOf: row.map(escape).joined(separator: ","))
            csv.append(contentsOf: "\r\n")
        }
        return Data(csv.utf8)
    }

    private static func timestampStyle(in timeZone: TimeZone) -> Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: true, timeZone: timeZone)
    }

    private static func escape(_ field: String) -> String {
        guard field.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }) else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"", options: .literal) + "\""
    }

    private static func spreadsheetText(_ value: String) -> String {
        // An SSID comes from the network, and quoting alone does not keep it out of a formula cell.
        let significant = value.unicodeScalars.drop(while: {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }).first
        let startsWithFormula = significant.map { "=+-@＝＋－＠".unicodeScalars.contains($0) } ?? false
        let first = value.unicodeScalars.first
        let startsWithControl = first == "\t" || first.map { CharacterSet.newlines.contains($0) } == true
        return startsWithFormula || startsWithControl ? "'" + value : value
    }
}
