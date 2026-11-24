import CoreWLAN
import Foundation
import ObjectiveC

enum WiFiSpatialStreams {
    static let commandLineFlag = "--read-spatial-streams"

    static var helperCommand: WiFiDiagnosticCommand? {
        Bundle.main.executableURL.map { executable in
            WiFiDiagnosticCommand(executablePath: executable.path, arguments: [commandLineFlag],
                                  timeout: .milliseconds(750), outputLimit: 16)
        }
    }

    static func parse(_ data: Data) -> Int? {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let count = UInt(text), plausibleCounts.contains(count) else { return nil }
        return Int(count)
    }

    private static let plausibleCounts: ClosedRange<UInt> = 1...16

    // Only the short-lived helper process may call the private API.
    @MainActor static func readInHelper(interfaceName: String) -> UInt? {
        let selector = NSSelectorFromString("numberOfSpatialStreams")
        guard let interface = CWWiFiClient.shared().interface(withName: interfaceName),
              interface.interfaceName == interfaceName, interface.interfaceMode() == .station,
              let method = class_getInstanceMethod(type(of: interface), selector),
              method_getNumberOfArguments(method) == 2 else { return nil }
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        guard String(cString: returnType) == "Q" else { return nil }

        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt
        let getter = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let count = getter(interface, selector)
        return plausibleCounts.contains(count) ? count : nil
    }
}
