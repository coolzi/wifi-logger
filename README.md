# Wi-Fi Logger

[Русская версия](README.ru.md)

Wi-Fi Logger records the current Wi-Fi connection on a Mac. It charts signal strength, noise and SNR over time, and marks observed disconnections, reconnections, channel changes and access point changes. Select a point on a chart to inspect the measurements at that time.

- The **Wi-Fi Measurements** tab samples the connection approximately every 250 ms.
- The **Modulation Snapshots** tab shows available MCS, modulation, coding rate, PHY transmit rate and spatial stream measurements. macOS supplies these snapshots separately.
- **Save CSV** exports all radio measurements or all modulation snapshots as separate files. **File → Import Access Point Names…** adds readable names for BSSIDs from a CSV.

## Build and run

You need macOS 14 or later and Swift 6. Xcode is the standard toolchain for Apple platforms. The project uses Apple SDK frameworks and has no external Swift package dependencies. [Swift setup on macOS](https://www.swift.org/install/macos/)

```sh
make
open .build/WiFiLoggerGUI.app
```

Click **Start Recording**. Open **Wi-Fi Logger Help** from the **Help** menu for chart navigation, CSV columns and the access point import format. The app supports Arabic, Bengali, English, French, Hindi, Indonesian, Portuguese, Russian, Simplified Chinese, Spanish, and Urdu. Choose a language for Wi-Fi Logger under **System Settings → General → Language & Region → Applications**, then reopen the app. [Apple's language settings guide](https://support.apple.com/guide/mac-help/change-the-system-language-mh26684/mac)

The command-line app prints approximately one measurement per second. Stop it with Ctrl+C.

```sh
./.build/WiFiLogger.app/Contents/MacOS/wifi-logger
```

See [Build and test](BUILD.md) for tests, Command Line Tools flags and the local Apple Silicon installer.

## Data and permissions

Recordings live in memory. You can save a CSV during recording. The file includes data collected up to the moment you confirm the save. To keep all radio measurements and modulation snapshots, pause recording and save each available CSV before closing the recording window or starting a new session. Use the Charts toggles to select radio measurements and gateway RTT on the same timeline. The imported access point directory is stored in the user's Library under Application Support and remains available after restarting.

macOS may require Location Services permission to expose the network name (SSID) and hardware address of the access point (BSSID). The GUI offers **Allow** when access can be requested. To ask from the command line, pass `--request-location`. These identifiers and measurement timestamps can be present in CSV exports and terminal output. Check them before sharing a file or a log.

Transmit rate is the reported Wi-Fi link rate.

## Spatial streams (NSS)

Wi-Fi Logger reads NSS by calling the undocumented CoreWLAN selector `numberOfSpatialStreams` on a `CWInterface` instance. A short-lived helper resolves it with `NSSelectorFromString("numberOfSpatialStreams")` and `class_getInstanceMethod`. It checks that the method takes no explicit arguments and returns a 64-bit unsigned integer before calling the implementation.

```swift
typealias Getter = @convention(c) (AnyObject, Selector) -> UInt
let getter = unsafeBitCast(method_getImplementation(method), to: Getter.self)
let count = getter(interface, selector)
```

The helper has a 750 ms timeout and accepts counts from 1 to 16. If it cannot obtain a count, NSS is shown as missing and recording continues. [NSS helper source](Sources/WiFiLogger/WiFiSpatialStreams.swift)

## Contributing

When reporting a problem, include the macOS and Swift versions, the steps to reproduce it and the result you expected. Use synthetic SSIDs and BSSIDs in examples and tests. Run the checks in [Build and test](BUILD.md) before submitting a change.

## License

[MIT](LICENSE)
