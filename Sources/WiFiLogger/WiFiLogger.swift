import CoreLocation
import Foundation

@main
@MainActor
enum WiFiLogger {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
        if arguments.isEmpty && executable == "wifi-logger-app" {
            WiFiLoggerApp.main()
            return
        }
        let usage = "Использование: wifi-logger [--request-location]"
        switch arguments {
        case _ where arguments.first == WiFiSpatialStreams.commandLineFlag:
            guard arguments.count == 2 else { exit(EX_USAGE) }
            if let count = WiFiSpatialStreams.readInHelper(interfaceName: arguments[1]) {
                print(count)
            }
        case [], ["--request-location"]:
            do {
                try TerminalLaunch.run(bundle: .main, requestLocation: !arguments.isEmpty)
            } catch {
                reportError("Ошибка запуска WiFi Logger: \(error.localizedDescription)")
                exit(EX_UNAVAILABLE)
            }
        case _ where arguments.first == "--app-session":
            guard arguments.count == 2 || (arguments.count == 3 && arguments.last == "--request-location"),
                  let launcher = pid_t(arguments[1]), launcher > 1 else {
                exit(EX_USAGE)
            }
            do {
                try TerminalLaunch.stopOnLauncherExit(launcher)
            } catch {
                reportError("Сессия Терминала недоступна: \(error.localizedDescription)")
                exit(EX_OSERR)
            }
            record(requestLocation: arguments.count == 3)
        case ["-h"], ["--help"]:
            print(usage)
        default:
            reportError(usage)
            exit(EX_USAGE)
        }
    }

    private static func record(requestLocation: Bool) {
        writeSample()

        let location = requestLocation ? CLLocationManager() : nil
        location?.requestWhenInUseAuthorization()

        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                writeSample()
            }
        }
        withExtendedLifetime(location) {
            RunLoop.main.run()
        }
    }

    private static let dateFormat = Date.ISO8601FormatStyle(
        timeZoneSeparator: .colon,
        timeZone: .autoupdatingCurrent
    )
    private static let reader = WiFiReader()

    private static func writeSample() {
        let sample = reader.sample()
        let line = sample.line(timestamp: sample.time.formatted(dateFormat))
        do {
            try FileHandle.standardOutput.write(contentsOf: Data("\(line)\n".utf8))
        } catch {
            reportError("Ошибка вывода замера: \(error.localizedDescription)")
            exit(EX_IOERR)
        }
    }

    private static func reportError(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data("\(message)\n".utf8))
    }
}
