import Darwin
import Foundation

enum TerminalLaunch {
    static func run(bundle: Bundle, requestLocation: Bool) throws {
        guard bundle.bundleURL.pathExtension == "app" else {
            throw LaunchError.bundleRequired
        }

        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("wifi-logger-\(UUID())")
        try files.createDirectory(at: directory, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }

        let output = try OutputChannel(url: directory.appendingPathComponent("stdout"))
        let errors = try OutputChannel(url: directory.appendingPathComponent("stderr"))

        let launch = Process()
        launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launch.arguments = [
            "-n", "--stdout", output.url.path, "--stderr", errors.url.path,
            bundle.bundleURL.path, "--args", "--app-session", String(getpid()),
        ]
        if requestLocation {
            launch.arguments?.append("--request-location")
        } else {
            launch.arguments?.insert("-g", at: 0)
        }
        try launch.run()
        launch.waitUntilExit()
        guard launch.terminationStatus == 0 else {
            throw LaunchError.openFailed(launch.terminationStatus)
        }

        // LaunchServices now owns the writing ends. Closing the bootstrap descriptors
        // lets the terminal receive EOF when the sampler exits.
        try output.bootstrap.close()
        try errors.bootstrap.close()
        try files.removeItem(at: directory)

        let diagnostics = DispatchGroup()
        DispatchQueue.global().async(group: diagnostics) {
            try? errors.forward(to: .standardError)
        }
        try output.forward(to: .standardOutput)
        diagnostics.wait()
        throw LaunchError.sessionEnded
    }

    static func stopOnLauncherExit(_ launcher: pid_t) throws {
        let queue = kqueue()
        guard queue >= 0 else { throw lastPOSIXError }

        // LaunchServices opens the output FIFOs read/write. Use a process event
        // so the launched sampler exits even if its own descriptors keep them open.
        var watch = kevent(ident: UInt(launcher), filter: Int16(EVFILT_PROC),
                           flags: UInt16(EV_ADD | EV_ONESHOT), fflags: UInt32(NOTE_EXIT),
                           data: 0, udata: nil)
        guard kevent(queue, &watch, 1, nil, 0, nil) == 0 else {
            let error = lastPOSIXError
            close(queue)
            throw error
        }
        DispatchQueue.global().async {
            var event = kevent()
            var result: Int32
            repeat {
                result = kevent(queue, nil, 0, &event, 1, nil)
            } while result == -1 && errno == EINTR
            close(queue)
            exit(result == 1 ? EXIT_SUCCESS : EX_OSERR)
        }
    }

    private enum LaunchError: LocalizedError {
        case bundleRequired
        case openFailed(Int32)
        case sessionEnded

        var errorDescription: String? {
            switch self {
            case .bundleRequired: "Запусти команду из пакета WiFiLogger.app, собранного через make."
            case .openFailed(let status): "LaunchServices завершил запуск с кодом \(status)."
            case .sessionEnded: "Процесс замеров завершился."
            }
        }
    }
}

private struct OutputChannel: Sendable {
    let url: URL
    let bootstrap: FileHandle
    private let reader: FileHandle

    init(url: URL) throws {
        self.url = url
        bootstrap = try createFIFO(at: url)
        let readEnd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard readEnd >= 0 else { throw lastPOSIXError }
        reader = FileHandle(fileDescriptor: readEnd, closeOnDealloc: true)
    }

    func forward(to destination: FileHandle) throws {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(reader.fileDescriptor, &buffer, buffer.count)
            switch count {
            case 0: return
            case -1 where errno == EINTR: continue
            case -1: throw lastPOSIXError
            default: try destination.write(contentsOf: Data(buffer.prefix(count)))
            }
        }
    }
}

private func createFIFO(at url: URL) throws -> FileHandle {
    guard mkfifo(url.path, 0o600) == 0 else { throw lastPOSIXError }
    // The read/write descriptor lets LaunchServices open either end without blocking.
    let descriptor = open(url.path, O_RDWR | O_CLOEXEC)
    guard descriptor >= 0 else { throw lastPOSIXError }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
}

private var lastPOSIXError: NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
}
