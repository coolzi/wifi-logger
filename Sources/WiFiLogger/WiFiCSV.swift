import Darwin
import Foundation

enum WiFiCSV {
    static func encode(_ session: WiFiSession, timeZone: TimeZone = .autoupdatingCurrent) -> Data {
        var csv = Data()
        forEachRow(in: session, timeZone: timeZone) { csv.append(contentsOf: $0.utf8) }
        return csv
    }

    static func write(_ session: WiFiSession, to destination: URL,
                      timeZone: TimeZone = .autoupdatingCurrent) throws {
        try writeAtomically(to: destination) { file in
            let blockSize = 64 * 1024
            var buffer = Data()
            buffer.reserveCapacity(blockSize)
            try forEachRow(in: session, timeZone: timeZone) { row in
                var remaining = row.utf8[...]
                while !remaining.isEmpty {
                    let chunk = remaining.prefix(blockSize - buffer.count)
                    buffer.append(contentsOf: chunk)
                    remaining = remaining[chunk.endIndex...]
                    if buffer.count == blockSize {
                        try file.write(contentsOf: buffer)
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
            }
            if !buffer.isEmpty { try file.write(contentsOf: buffer) }
        }
    }

    private static func forEachRow(in session: WiFiSession, timeZone: TimeZone,
                                   emit: (String) throws -> Void) rethrows {
        var changes = session.events.lazy.filter { $0.kind == .channelChanged }.makeIterator()
        var nextChange = changes.next()
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
        try forEachRow(in: session.samples, timeZone: timeZone, additionalColumns: [
            "channel_changed", "previous_band", "previous_channel", "previous_channel_width_mhz",
            "session_outage_count", "session_outage_total_seconds", "session_outage_longest_seconds",
            "rssi_min_60s_dbm", "rssi_max_60s_dbm", "rssi_spread_60s_db",
            "snr_min_60s_db", "snr_max_60s_db", "snr_spread_60s_db",
            "segment_id", "monotonic_seconds", "calculation_version",
        ], additionalFields: { index in
            let changed = nextChange?.sampleIndex == index
            if changed { nextChange = changes.next() }
            let previous = changed ? session.samples[index - 1].connectedMeasurements.channel : nil
            return [
                changed ? "1" : "0",
                previous?.band?.legacyLabel ?? "",
                previous?.number.map { String($0) } ?? "",
                previous?.width.map { String($0) } ?? "",
            ] + summary + [String(session.segmentIDs[index]),
                           String(session.samples[index].monotonicTime), "1"]
        }, emit: emit)
    }

    static func encode(_ samples: [WiFiSample], timeZone: TimeZone = .autoupdatingCurrent) -> Data {
        var csv = Data()
        forEachRow(in: samples, timeZone: timeZone, additionalColumns: [], additionalFields: { _ in [] }) {
            csv.append(contentsOf: $0.utf8)
        }
        return csv
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
                spreadsheetText(snapshot.channel?.band?.legacyLabel ?? ""),
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

    private static func forEachRow(in samples: [WiFiSample], timeZone: TimeZone, additionalColumns: [String],
                                   additionalFields: (Int) -> [String], emit: (String) throws -> Void) rethrows {
        let timestampFormat = timestampStyle(in: timeZone)
        let columns = [
            "timestamp", "state", "ssid", "bssid", "rssi_dbm", "noise_dbm", "snr_db",
            "band", "channel", "channel_width_mhz", "phy_mode", "tx_rate_mbps",
        ] + additionalColumns
        try emit(columns.joined(separator: ",") + "\r\n")
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
                fields.channel?.band?.legacyLabel ?? "",
                fields.channel?.number.map { String($0) } ?? "",
                fields.channel?.width.map { String($0) } ?? "",
                fields.phyMode ?? "",
                fields.transmitRateMbps.map { String($0) } ?? "",
            ] + additionalFields(index)
            try emit(row.map(escape).joined(separator: ",") + "\r\n")
        }
    }

    private static func timestampStyle(in timeZone: TimeZone) -> Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: true, timeZone: timeZone)
    }

    static func writeAtomically(to destination: URL, write: (FileHandle) throws -> Void) throws {
        guard destination.isFileURL, !destination.path.utf8.contains(0) else {
            throw fileError(EINVAL, at: destination)
        }
        let parent = destination.deletingLastPathComponent()
        let directory = open(parent.path, O_SEARCH | O_CLOEXEC)
        guard directory >= 0 else { throw fileError(errno, at: parent) }
        defer { close(directory) }
        let replacing = try destinationStatus(at: destination, in: directory) != nil
        let temporary = parent.appending(path: ".wifi-logger-\(UUID()).tmp")
        let name = temporary.lastPathComponent
        let descriptor = try openTemporaryFile(temporary, in: directory, replacing: replacing)
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        // Keep a separate metadata handle before the destination's ACL or mode can deny reopening it.
        let observer = openat(directory, name, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        defer { if observer >= 0 { close(observer) } }
        var staging = stat()
        var writerOpen = true
        do {
            guard fstat(descriptor, &staging) == 0 else { throw fileError(errno, at: temporary) }
            try write(file)
            if replacing {
                guard let status = try destinationStatus(at: destination, in: directory) else {
                    throw fileError(ENOENT, at: destination)
                }
                if status.st_mode & S_IFMT == S_IFREG, fpathconf(directory, _PC_EXTENDED_SECURITY_NP) != 0 {
                    try copyACL(from: destination, matching: status, to: descriptor)
                }
                guard fchmod(descriptor, status.st_mode & 0o7777) == 0 else {
                    throw fileError(errno, at: destination)
                }
            }
            try file.synchronize()
            writerOpen = false
            try file.close()
            let result = replacing
                ? renameat(directory, name, directory, destination.lastPathComponent)
                : renameatx_np(directory, name, directory, destination.lastPathComponent, UInt32(RENAME_EXCL))
            guard result == 0 else { throw fileError(errno, at: destination) }
        } catch {
            removeStaging(name, in: directory, matching: staging, descriptor: writerOpen ? descriptor : observer)
            throw error
        }
    }

    private static func removeStaging(_ name: String, in directory: Int32, matching staging: stat, descriptor: Int32) {
        guard unlinkat(directory, name, 0) != 0, errno == EACCES || errno == EPERM,
              let empty = acl_init(0) else { return }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        var info = stat()
        if descriptor >= 0, fstat(descriptor, &info) == 0, sameFile(info, staging) {
            guard acl_set_fd(descriptor, empty) == 0 else { return }
        } else {
            // An inherited deny-read ACE can prevent opening the metadata handle on a new file.
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(directory, F_GETPATH, &path) == 0 else { return }
            let parent = URL(fileURLWithFileSystemRepresentation: path, isDirectory: true, relativeTo: nil)
            let temporary = parent.appending(path: name)
            guard lstat(temporary.path, &info) == 0, sameFile(info, staging),
                  acl_set_link_np(temporary.path, ACL_TYPE_EXTENDED, empty) == 0 else { return }
        }
        unlinkat(directory, name, 0)
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private static func copyACL(from url: URL, matching status: stat, to descriptor: Int32) throws {
        let acl = acl_get_link_np(url.path, ACL_TYPE_EXTENDED)
        let error = errno
        defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
        // Darwin's no-follow ACL lookup takes a path. It must still name the selected inode.
        var named = stat()
        guard lstat(url.path, &named) == 0 else { throw fileError(errno, at: url) }
        guard sameFile(named, status) else { throw fileError(ESTALE, at: url) }
        if let acl {
            guard acl_set_fd(descriptor, acl) == 0 else { throw fileError(errno, at: url) }
        } else if error != ENOENT && error != ENOTSUP && error != EOPNOTSUPP {
            throw fileError(error, at: url)
        }
    }

    private static func destinationStatus(at url: URL, in directory: Int32) throws -> stat? {
        var info = stat()
        guard fstatat(directory, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw fileError(errno, at: url)
        }
        switch info.st_mode & S_IFMT {
        case S_IFREG, S_IFLNK: return info
        case S_IFDIR: throw fileError(EISDIR, at: url)
        default: throw fileError(EINVAL, at: url)
        }
    }

    private static func openTemporaryFile(_ url: URL, in directory: Int32, replacing: Bool) throws -> Int32 {
        let flags = O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC
        if !replacing || fpathconf(directory, _PC_EXTENDED_SECURITY_NP) == 0 {
            let descriptor = openat(directory, url.lastPathComponent, flags, replacing ? 0o600 : 0o666)
            guard descriptor >= 0 else { throw fileError(errno, at: url) }
            return descriptor
        }
        // An inherited allow ACL can grant access even to a 0600 staging file.
        guard let security = filesec_init() else { throw fileError(errno, at: url) }
        defer { filesec_free(security) }
        guard var acl = acl_init(0) else { throw fileError(errno, at: url) }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var aclFlags: acl_flagset_t?
        var permissions: mode_t = 0o600
        guard acl_get_flagset_np(UnsafeMutableRawPointer(acl), &aclFlags) == 0,
              acl_add_flag_np(aclFlags, ACL_FLAG_NO_INHERIT) == 0,
              filesec_set_property(security, FILESEC_MODE, &permissions) == 0,
              filesec_set_property(security, FILESEC_ACL, &acl) == 0 else {
            throw fileError(errno, at: url)
        }
        let descriptor = openx_np(url.path, flags, security)
        guard descriptor >= 0 else { throw fileError(errno, at: url) }
        // openx_np has no directory-relative variant. Verify its empty file before writing.
        var opened = stat()
        var named = stat()
        if fstat(descriptor, &opened) != 0 ||
            fstatat(directory, url.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) != 0 ||
            !sameFile(opened, named) {
            if lstat(url.path, &named) == 0, sameFile(opened, named) {
                unlink(url.path)
            }
            close(descriptor)
            throw fileError(ESTALE, at: url)
        }
        return descriptor
    }

    private static func fileError(_ code: Int32, at url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
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
