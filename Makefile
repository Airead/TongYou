.PHONY: build build-release test clean run install icon

SCHEME = TongYou
DESTINATION = platform=macOS
BUILD_DIR = $(CURDIR)/build
APP_NAME = TongYou.app
INSTALL_DIR = /Applications

build:
	xcodebuild build -scheme $(SCHEME) -destination '$(DESTINATION)' | xcbeautify || true

build-release:
	xcodebuild build -scheme $(SCHEME) -destination '$(DESTINATION)' -configuration Release SYMROOT=$(BUILD_DIR) | xcbeautify || true

install: build-release
	@echo "Installing $(APP_NAME) to $(INSTALL_DIR)..."
	rm -rf "$(INSTALL_DIR)/$(APP_NAME)"
	cp -R "$(BUILD_DIR)/Release/$(APP_NAME)" "$(INSTALL_DIR)/$(APP_NAME)"
	@echo "Done."

test:
	xcodebuild test -scheme $(SCHEME) -destination '$(DESTINATION)' -parallel-testing-enabled NO -only-testing TongYouTests | xcbeautify || true

clean:
	xcodebuild clean -scheme $(SCHEME) -destination '$(DESTINATION)'

run: build
	@open "$$(xcodebuild -scheme $(SCHEME) -destination '$(DESTINATION)' -showBuildSettings 2>/dev/null | grep ' BUILT_PRODUCTS_DIR' | awk '{print $$3}')/TongYou.app"

icon:
	swift scripts/generate_icon.swift
