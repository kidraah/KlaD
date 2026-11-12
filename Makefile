# KlaD — build, bundle, sign (inside-out, never --deep), run, test.
#
#   make app        release build → build/KlaD.app (ad-hoc signed by default)
#   make run        build + open the app
#   make scan-home  build + open the app and immediately scan ~
#   make test       full Swift Testing suite (handles CLT-only toolchains)
#   make probe      release build of the headless scanner probe
#   make icon       regenerate Resources/AppIcon.icns
#
# Signing: SIGN_ID defaults to "-" (ad-hoc). Use a stable identity so macOS
# privacy grants (Full Disk Access) survive rebuilds, e.g.
#   make app SIGN_ID="Apple Development: Jane Doe (TEAMID)"

APP_NAME   := KlaD
BUILD_DIR  := build
APP        := $(BUILD_DIR)/$(APP_NAME).app
CONFIG     ?= release
SIGN_ID    ?= -
SWIFT      ?= swift
BIN_DIR     = $(shell $(SWIFT) build -c $(CONFIG) --show-bin-path)

.PHONY: all build app run scan-home test probe icon clean

all: app

build:
	$(SWIFT) build -c $(CONFIG) --product $(APP_NAME)

app: build
	@rm -rf "$(APP)"
	@mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	@cp "$(BIN_DIR)/$(APP_NAME)" "$(APP)/Contents/MacOS/$(APP_NAME)"
	@cp Info.plist "$(APP)/Contents/Info.plist"
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"; fi
	@# Inside-out signing: nested code first (frameworks, dylibs, helpers), then the bundle.
	@find "$(APP)/Contents" -depth \( -name "*.dylib" -o -name "*.framework" -o -name "*.xpc" -o -name "*.appex" \) \
		-exec codesign --force --timestamp=none --options runtime --sign "$(SIGN_ID)" {} \; 2>/dev/null || true
	@codesign --force --timestamp=none --options runtime --sign "$(SIGN_ID)" "$(APP)"
	@codesign --verify --strict --verbose=1 "$(APP)"
	@echo "Built $(APP)"

run: app
	open "$(APP)"

scan-home: app
	open "$(APP)" --args --scan "$(HOME)"

test:
	Scripts/test.sh

probe:
	$(SWIFT) build -c release --product klad-probe
	@echo "$$($(SWIFT) build -c release --show-bin-path)/klad-probe"

icon:
	$(SWIFT) Scripts/make-icon.swift Resources/AppIcon.icns

clean:
	rm -rf "$(BUILD_DIR)"
	$(SWIFT) package clean
