.PHONY: build build-release test clean run install install-cli icon dmg-resources build-dmg swift-build core-build core-test

SCHEME = TongYou
DESTINATION = platform=macOS
BUILD_DIR = $(CURDIR)/build
APP_NAME = TongYou.app
INSTALL_DIR = /Applications
CLI_INSTALL_DIR = $(HOME)/.local/bin
PKG_DIR = Packages/TongYouCore

build:
	xcodebuild build -scheme $(SCHEME) -destination '$(DESTINATION)' | xcbeautify || true

build-release:
	xcodebuild build -scheme $(SCHEME) -destination '$(DESTINATION)' -configuration Release SYMROOT=$(BUILD_DIR) | xcbeautify || true

install: build-release
	@echo "Installing $(APP_NAME) to $(INSTALL_DIR)..."
	rm -rf "$(INSTALL_DIR)/$(APP_NAME)"
	cp -R "$(BUILD_DIR)/Release/$(APP_NAME)" "$(INSTALL_DIR)/$(APP_NAME)"
	@echo "Done."

install-cli:
	@echo "Building tongyou CLI..."
	cd $(PKG_DIR) && swift build -c release --product tongyou
	@mkdir -p $(CLI_INSTALL_DIR)
	@echo "Installing tongyou to $(CLI_INSTALL_DIR)..."
	cp $(PKG_DIR)/.build/release/tongyou $(CLI_INSTALL_DIR)/tongyou
	@echo "Done. Make sure $(CLI_INSTALL_DIR) is in your PATH."

test:
	xcodebuild test -scheme $(SCHEME) -destination '$(DESTINATION)' -parallel-testing-enabled NO -only-testing TongYouTests | xcbeautify || true

swift-build:
	swift build --build-path $(BUILD_DIR)/spn

swift-test:
	swift test --build-path $(BUILD_DIR)/spn

core-build:
	cd $(PKG_DIR) && swift build

core-test:
	cd $(PKG_DIR) && swift test

clean:
	xcodebuild clean -scheme $(SCHEME) -destination '$(DESTINATION)'
	@echo "Cleaning SPM build artifacts..."
	rm -rf .build build/spn $(PKG_DIR)/.build
	rm -f *.d *.dia *.swiftdeps *.swiftmodule
	@echo "Clean complete."

run: build
	@open "$$(xcodebuild -scheme $(SCHEME) -destination '$(DESTINATION)' -showBuildSettings 2>/dev/null | grep ' BUILT_PRODUCTS_DIR' | awk '{print $$3}')/TongYou.app"

icon:
	swift scripts/generate_icon.swift

dmg-resources: icon
	swift scripts/generate_dmg_background.swift
	swift scripts/generate_dmg_volume_icon.swift

build-dmg: build-release dmg-resources
	./scripts/build-dmg.sh
