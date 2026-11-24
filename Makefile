APP := .build/WiFiLogger.app
COMMAND := $(APP)/Contents/MacOS/wifi-logger
GUI_APP := .build/WiFiLoggerGUI.app
GUI_EXECUTABLE := $(GUI_APP)/Contents/MacOS/wifi-logger-app
GUI_ICON := .build/WiFiLogger.icns
LOCALIZATIONS := ar bn en es fr hi id pt ru ur zh-Hans
VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
INSTALLER := dist/WiFi-Logger-$(VERSION)-macOS-arm64.pkg

.PHONY: build test test-capture-stall test-localization package

build: $(GUI_ICON)
	swift build $(SWIFT_FLAGS) --product wifi-logger
	build_bin="$$(swift build $(SWIFT_FLAGS) --show-bin-path)" && \
		mkdir -p "$(APP)/Contents/MacOS" "$(GUI_APP)/Contents/MacOS" && \
		cp "$$build_bin/wifi-logger" "$(COMMAND).next" && \
		mv -f "$(COMMAND).next" "$(COMMAND)" && \
		cp "$$build_bin/wifi-logger" "$(GUI_EXECUTABLE).next" && \
		mv -f "$(GUI_EXECUTABLE).next" "$(GUI_EXECUTABLE)"
	rm -f "$(APP)/Contents/MacOS/wifi-logger-app"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	cp Resources/Info.plist "$(GUI_APP)/Contents/Info.plist"
	plutil -replace CFBundleExecutable -string wifi-logger-app "$(GUI_APP)/Contents/Info.plist"
	plutil -replace CFBundleIdentifier -string local.wifi-logger.gui "$(GUI_APP)/Contents/Info.plist"
	plutil -replace CFBundleName -string "Wi-Fi Logger" "$(GUI_APP)/Contents/Info.plist"
	plutil -insert CFBundleDevelopmentRegion -string ru "$(GUI_APP)/Contents/Info.plist"
	plutil -insert CFBundleIconFile -string "$(notdir $(GUI_ICON))" "$(GUI_APP)/Contents/Info.plist"
	mkdir -p "$(APP)/Contents/Resources" "$(GUI_APP)/Contents/Resources"
	cp LICENSE "$(APP)/Contents/Resources/"
	cp LICENSE "$(GUI_APP)/Contents/Resources/"
	cp "$(GUI_ICON)" "$(GUI_APP)/Contents/Resources/"
	@set -e; for language in $(LOCALIZATIONS); do \
		destination="$(GUI_APP)/Contents/Resources/$$language.lproj"; \
		mkdir -p "$$destination"; \
		cp Resources/$$language.lproj/*.strings "$$destination/"; \
	done
	codesign --force --sign - --options runtime \
		--entitlements Resources/Location.entitlements.plist "$(APP)" "$(GUI_APP)"
	@# Refresh the cached Finder icon after updating the existing bundle.
	touch "$(GUI_APP)"

$(GUI_ICON): Resources/WiFiLogger-icon.png
	@set -eu; \
		mkdir -p "$(@D)"; \
		icon_dir="$$(mktemp -d "$(@D)/wifi-icon.XXXXXX")"; \
		trap 'rm -rf "$$icon_dir"' EXIT; \
		iconset="$$icon_dir/WiFiLogger.iconset"; \
		mkdir "$$iconset"; \
		for size in 16 32 128 256 512; do \
			sips -z "$$size" "$$size" "$<" --out "$$iconset/icon_$${size}x$${size}.png" >/dev/null; \
			retina=$$((size * 2)); \
			sips -z "$$retina" "$$retina" "$<" --out "$$iconset/icon_$${size}x$${size}@2x.png" >/dev/null; \
		done; \
		iconutil -c icns "$$iconset" -o "$$icon_dir/WiFiLogger.icns"; \
		mv -f "$$icon_dir/WiFiLogger.icns" "$@"

test:
	swift test $(SWIFT_FLAGS) --disable-xctest

test-localization: build
	xcrun swift Tests/Integration/WiFiLocalization.swift "$(abspath $(GUI_APP))"

test-capture-stall:
	mkdir -p .build
	xcrun swiftc -O -parse-as-library -swift-version 6 -target "$$(uname -m)-apple-macosx14.0" \
		-module-cache-path .build/capture-stall-cache \
		$(filter-out Sources/WiFiLogger/WiFiLogger.swift,$(wildcard Sources/WiFiLogger/*.swift)) \
		Tests/Integration/WiFiCaptureStall.swift -o .build/test-capture-stall
	.build/test-capture-stall

package:
	$(MAKE) build SWIFT_FLAGS='$(SWIFT_FLAGS) -c release --arch arm64'
	codesign --verify --deep --strict "$(GUI_APP)"
	@set -eu; \
		stage_dir="$$(mktemp -d .build/installer.XXXXXX)"; \
		trap 'rm -rf "$$stage_dir"' EXIT; \
		mkdir -p "$$stage_dir/root/Applications" dist; \
		ditto --noqtn "$(GUI_APP)" "$$stage_dir/root/Applications/Wi-Fi Logger.app"; \
		pkgbuild --root "$$stage_dir/root" \
			--component-plist Resources/InstallerComponents.plist \
			--identifier local.wifi-logger.gui \
			--version "$(VERSION)" --install-location / \
			"$$stage_dir/WiFiLogger.pkg"; \
		productbuild --product Resources/InstallerRequirements.plist \
			--package "$$stage_dir/WiFiLogger.pkg" "$$stage_dir/Installer.pkg"; \
		mv -f "$$stage_dir/Installer.pkg" "$(INSTALLER)"
	@echo "$(INSTALLER)"
