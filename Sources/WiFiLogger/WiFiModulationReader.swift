import Darwin
import Foundation
import os

actor WiFiModulationReader {
    enum ReadError: Error, Equatable {
        case requestInProgress
        case timedOut
        case outputTooLarge
        case commandFailed
        case systemCallFailed(Int32)
    }

    private static let worker = DispatchQueue(label: "wifi-logger.modulation", qos: .utility)
    private let command: WiFiDiagnosticCommand
    private let readBSSID: @Sendable (String) async -> String?
    private var spatialStreamsCommand: WiFiDiagnosticCommand?
    private var reading = false

    init(executablePath: String = "/usr/sbin/system_profiler",
         arguments: [String] = ["-json", "-detailLevel", "basic", "-timeout", "5", "SPAirPortDataType"],
         timeout: Duration = .seconds(7), outputLimit: Int = 1_048_576,
         spatialStreamsCommand: WiFiDiagnosticCommand? = nil,
         readBSSID: @escaping @Sendable (String) async -> String? = WiFiRadioReader.associatedBSSID) {
        command = WiFiDiagnosticCommand(executablePath: executablePath, arguments: arguments,
                                        timeout: timeout, outputLimit: outputLimit)
        self.spatialStreamsCommand = spatialStreamsCommand
        self.readBSSID = readBSSID
    }

    func read(interfaceName: String) async throws -> WiFiModulationSnapshot? {
        try Task.checkCancellation()
        guard !reading else { throw ReadError.requestInProgress }
        reading = true
        defer { reading = false }
        let command = self.command
        let spatialStreamsCommand = self.spatialStreamsCommand
        let initialBSSID = spatialStreamsCommand == nil ? nil : await readBSSID(interfaceName)
        try Task.checkCancellation()
        let cancelled = OSAllocatedUnfairLock(initialState: false)

        let result: Result<(snapshot: WiFiModulationSnapshot?, helperFailed: Bool), Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Self.worker.async {
                    continuation.resume(returning: Result {
                        if cancelled.withLock({ $0 }) { throw CancellationError() }
                        let startedAt = Date.now
                        let startedUptime = WiFiMonotonicClock.now
                        let data = try command.capture()
                        var snapshot = try WiFiModulationSnapshot.parse(data, interfaceName: interfaceName,
                                                                       startedAt: startedAt, finishedAt: .now,
                                                                       startedUptime: startedUptime,
                                                                       finishedUptime: WiFiMonotonicClock.now)
                        guard snapshot != nil, let spatialStreamsCommand, !cancelled.withLock({ $0 }) else {
                            return (snapshot, false)
                        }
                        do {
                            let output = try spatialStreamsCommand.capture(additionalArguments: [interfaceName])
                            let receivedUptime = WiFiMonotonicClock.now
                            let receivedAt = Date.now
                            if let count = WiFiSpatialStreams.parse(output) {
                                snapshot?.spatialStreams = WiFiSpatialStreamsReading(
                                    count: count, receivedAt: receivedAt, receivedUptime: receivedUptime
                                )
                            }
                            return (snapshot, false)
                        } catch {
                            return (snapshot, true)
                        }
                    })
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
        // The profiler can delegate to a separate process group. Let an active
        // capture finish under its own timeout before allowing another request.
        if case .success((_, true)) = result { self.spatialStreamsCommand = nil }
        try Task.checkCancellation()
        var snapshot = try result.get().snapshot
        if snapshot?.spatialStreams != nil {
            let finalBSSID = await readBSSID(interfaceName)
            try Task.checkCancellation()
            // Unknown identity at both ends still permits a separately timed NSS observation.
            if initialBSSID != finalBSSID { snapshot?.spatialStreams = nil }
        }
        return snapshot
    }
}

struct WiFiDiagnosticCommand: Sendable {
    let executablePath: String
    let arguments: [String]
    let timeout: Duration
    let outputLimit: Int

    typealias ReadError = WiFiModulationReader.ReadError

    func capture(additionalArguments: [String] = [], acceptedExitCodes: [Int32] = [0],
                 includeStandardError: Bool = false, isCancelled: () -> Bool = { false },
                 onStart: () -> Void = {}) throws -> Data {
        if isCancelled() { throw CancellationError() }
        let pipe = Pipe()
        let reader = pipe.fileHandleForReading
        let writer = pipe.fileHandleForWriting
        defer { try? reader.close() }
        defer { try? writer.close() }

        let fd = reader.fileDescriptor
        if fcntl(fd, F_SETFL, O_NONBLOCK) == -1 { throw ReadError.systemCallFailed(errno) }
        let deadline = ContinuousClock.now + timeout
        let pid = try spawn(stdout: writer.fileDescriptor, arguments: arguments + additionalArguments,
                            includeStandardError: includeStandardError)
        var needsReaping = true
        defer {
            if needsReaping {
                // The group's leader remains our unreaped child, so the ID cannot be reused.
                _ = kill(-pid, SIGKILL)
                while waitpid(pid, nil, 0) == -1 && errno == EINTR {}
            }
        }
        onStart()
        try writer.close()

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var stdout = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while ContinuousClock.now < deadline {
            if isCancelled() { throw CancellationError() }
            if stdout.fd >= 0 {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    guard count <= outputLimit - output.count else { throw ReadError.outputTooLarge }
                    output.append(contentsOf: buffer.prefix(count))
                    continue
                }
                if count == 0 {
                    stdout.fd = -1
                } else if errno != EAGAIN && errno != EINTR {
                    throw ReadError.systemCallFailed(errno)
                }
            }

            if stdout.fd < 0 {
                var status: Int32 = 0
                let waited = waitpid(pid, &status, WNOHANG)
                if waited == pid {
                    needsReaping = false
                    // Darwin stores the normal exit code in the high byte.
                    guard status & 0x7f == 0, acceptedExitCodes.contains((status >> 8) & 0xff) else {
                        throw ReadError.commandFailed
                    }
                    return output
                }
                if waited == -1 && errno != EINTR {
                    let error = errno
                    if error == ECHILD { needsReaping = false }
                    throw ReadError.systemCallFailed(error)
                }
            }

            if poll(&stdout, 1, 25) == -1 && errno != EINTR { throw ReadError.systemCallFailed(errno) }
        }
        throw ReadError.timedOut
    }

    private func spawn(stdout: Int32, arguments: [String], includeStandardError: Bool) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawn_file_actions_adddup2(&actions, stdout, STDOUT_FILENO))
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        if includeStandardError {
            try check(posix_spawn_file_actions_adddup2(&actions, stdout, STDERR_FILENO))
        } else {
            try check(posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0))
        }

        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))

        let strings = [executablePath] + arguments
        var argv = strings.map { strdup($0) }
        defer { argv.forEach { free($0) } }
        guard argv.allSatisfy({ $0 != nil }) else { throw ReadError.systemCallFailed(ENOMEM) }
        argv.append(nil)
        var pid: pid_t = 0
        try check(posix_spawn(&pid, executablePath, &actions, &attributes, &argv, environ))
        return pid
    }

    private func check(_ error: Int32) throws {
        if error != 0 { throw ReadError.systemCallFailed(error) }
    }
}
