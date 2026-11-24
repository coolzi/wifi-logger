import CoreWLAN
import Dispatch
import Foundation
import SystemConfiguration

struct WiFiReader {
    private let client = CWWiFiClient.shared()
    private let store = SCDynamicStoreCreate(nil, "wifi-logger" as CFString, nil, nil)

    var interfaceName: String? { client.interface()?.interfaceName }

    func associatedBSSID(interfaceName: String) -> String? {
        guard let interface = client.interface(withName: interfaceName),
              interface.interfaceMode() == .station,
              let bssid = interface.bssid()?.lowercased(),
              !bssid.isEmpty, bssid != "00:00:00:00:00:00" else { return nil }
        return bssid
    }

    func sample() -> WiFiSample {
        let time = Date.now
        let monotonicTime = WiFiMonotonicClock.now
        guard let interface = client.interface(), let name = interface.interfaceName else {
            return WiFiSample(time: time, monotonicTime: monotonicTime,
                              state: .unknown, measurements: WiFiMeasurements())
        }

        let state = WiFiState(
            powerOn: interface.powerOn(),
            linkActive: linkActive(for: name),
            stationMode: interface.interfaceMode() == .station
        )
        guard state == .connected else {
            return WiFiSample(time: time, monotonicTime: monotonicTime,
                              state: state, measurements: WiFiMeasurements())
        }

        let measurements = WiFiMeasurements(
            ssid: interface.ssid(),
            bssid: interface.bssid(),
            rssi: interface.rssiValue(),
            noise: interface.noiseMeasurement(),
            channel: interface.wlanChannel().map(WiFiChannel.init),
            phyMode: phyModeLabel(interface.activePHYMode()),
            transmitRate: interface.transmitRate(),
            ssidData: interface.ssidData()
        )
        return WiFiSample(time: time, monotonicTime: monotonicTime, state: state, measurements: measurements)
    }

    private func linkActive(for name: String) -> Bool? {
        let key = SCDynamicStoreKeyCreateNetworkInterfaceEntity(
            nil, kSCDynamicStoreDomainState, name as CFString, kSCEntNetLink
        )
        let link = SCDynamicStoreCopyValue(store, key) as? [String: Any]
        return link?[kSCPropNetLinkActive as String] as? Bool
    }

    private func phyModeLabel(_ mode: CWPHYMode) -> String? {
        switch mode {
        case .mode11a: "802.11a"
        case .mode11b: "802.11b"
        case .mode11g: "802.11g"
        case .mode11n: "802.11n"
        case .mode11ac: "802.11ac"
        case .mode11ax: "802.11ax"
        // The macOS 15 SDK omits the named case for 802.11be.
        default: mode.rawValue == 7 ? "802.11be" : nil
        }
    }
}

actor WiFiRadioReader {
    static let shared = WiFiRadioReader()

    // CoreWLAN makes synchronous system calls. Keep the GUI reader on a dedicated serial executor.
    private let queue = DispatchSerialQueue(label: "wifi-logger.radio", qos: .userInitiated)
    private lazy var reader = WiFiReader()

    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    var interfaceName: String? { reader.interfaceName }

    static func associatedBSSID(_ interfaceName: String) async -> String? {
        await shared.associatedBSSID(interfaceName: interfaceName)
    }

    private func associatedBSSID(interfaceName: String) -> String? {
        reader.associatedBSSID(interfaceName: interfaceName)
    }

    func sample() -> WiFiSample { reader.sample() }

    func capture(into buffer: WiFiCaptureBuffer) async {
        let clock = ContinuousClock()
        let interval = Duration.milliseconds(250)
        let reader = reader
        while !Task.isCancelled, buffer.isOpen {
            let sampleStartedAt = clock.now
            guard buffer.submit(reader.sample()) else { return }
            do {
                try await clock.sleep(until: sampleStartedAt + interval, tolerance: .milliseconds(5))
            } catch {
                return
            }
        }
    }
}

private extension WiFiChannel {
    init(_ channel: CWChannel) {
        band = switch channel.channelBand {
        case .band2GHz: "2,4 ГГц"
        case .band5GHz: "5 ГГц"
        case .band6GHz: "6 ГГц"
        case .bandUnknown: nil
        @unknown default: nil
        }
        number = channel.channelNumber > 0 ? channel.channelNumber : nil
        width = switch channel.channelWidth {
        case .width20MHz: 20
        case .width40MHz: 40
        case .width80MHz: 80
        case .width160MHz: 160
        case .widthUnknown: nil
        @unknown default: nil
        }
    }
}
