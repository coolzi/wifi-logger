# Build and test · Сборка и проверки

## Standard commands

Run these commands from the source directory on macOS with the Swift 6 toolchain from Xcode selected.

Команды выполняются из каталога исходников на macOS. Для стандартного запуска выберите инструменты Xcode со Swift 6.

```sh
make build
make test
make test-localization
make test-capture-stall
```

- `make build` creates the GUI and CLI app bundles under `.build/`.
- `make test` runs the automated test suite.
- `make test-localization` builds the GUI bundle and checks the packed language resources.
- `make test-capture-stall` runs a separate integration check for measurement capture while the main actor is blocked. Run it on a Mac with Wi-Fi.

## Command Line Tools

If SwiftPM reports missing Swift Testing framework or macro plugin components with standalone Command Line Tools, use the commands below. This configuration was verified with the Apple Swift 6.4.2 toolchain under `/Library/Developer/CommandLineTools`. Confirm that this is the active tools directory with `xcode-select -p`.

Если SwiftPM с отдельными Command Line Tools не находит компоненты Swift Testing, используйте эти команды. Они проверены с Apple Swift 6.4.2. Команда `xcode-select -p` должна показать каталог `/Library/Developer/CommandLineTools`.

```sh
wifi_clt="$(xcode-select -p)"
wifi_frameworks="$wifi_clt/Library/Developer/Frameworks"
wifi_testing_macros="$wifi_clt/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
wifi_swift_flags='--build-system native --disable-sandbox --manifest-cache local'
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"

make build SWIFT_FLAGS="$wifi_swift_flags"
make test SWIFT_FLAGS="$wifi_swift_flags -Xswiftc -F -Xswiftc $wifi_frameworks -Xswiftc -load-plugin-library -Xswiftc $wifi_testing_macros -Xlinker -F -Xlinker $wifi_frameworks -Xlinker -framework -Xlinker Testing"
make test-localization SWIFT_FLAGS="$wifi_swift_flags"
make test-capture-stall
```

## Local installer

On Apple Silicon, `make package` creates `dist/WiFi-Logger-<version>-macOS-arm64.pkg`. With the Command Line Tools setup above, run `make package SWIFT_FLAGS="$wifi_swift_flags"`. Use the build flags here without the test framework flags. The installer targets `/Applications/Wi-Fi Logger.app`.

На Apple Silicon команда `make package` собирает локальный установщик в `dist/`. Для конфигурации Command Line Tools выше укажите `SWIFT_FLAGS="$wifi_swift_flags"`. Пакет устанавливает приложение в `/Applications/Wi-Fi Logger.app`.

The Makefile builds ad-hoc signed apps and a local installer. A public downloadable installer needs a separate Developer ID signing and notarization workflow. Mac App Store submission also requires replacing the optional undocumented NSS API use with a public-API build. [Apple's macOS distribution overview](https://developer.apple.com/documentation/technologyoverviews/distribution) · [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/#performance)
