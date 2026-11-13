# KlaD — build, bundle, sign (inside-out, never --deep), run, test.
#
#   make app        release build → build/KlaD.app (ad-hoc signed by default)
#   make run        build + open the app
#   make scan-home  build + open the app and immediately scan ~
#   make test       full Swift Testing suite (handles CLT-only toolchains)
#   make probe      release build of the headless scanner probe
#   make icon       regenerate Resources/AppIcon.icns
#   make media      README screenshots, GIFs and videos (fictional demo data)
#   make dmg        universal (Apple silicon + Intel) build/KlaD-<version>.dmg
#
# Signing: if the local identity from `make signing-identity` exists it is used,
# so macOS remembers folder permissions across rebuilds; otherwise ad-hoc ("-").
# Override with: make app SIGN_ID="Apple Development: Jane Doe (TEAMID)"

APP_NAME   := KlaD
BUILD_DIR  := build
APP        := $(BUILD_DIR)/$(APP_NAME).app
CONFIG     ?= release
LOCAL_KEYCHAIN := $(HOME)/Library/Keychains/klad-signing.keychain-db
LOCAL_PASSFILE := $(HOME)/.config/klad/signing-keychain-password
HAS_LOCAL_ID   := $(shell security find-certificate -c "KlaD Local Signing" "$(LOCAL_KEYCHAIN)" >/dev/null 2>&1 && test -f "$(LOCAL_PASSFILE)" && echo yes)
ifeq ($(HAS_LOCAL_ID),yes)
SIGN_ID    ?= KlaD Local Signing
SIGN_FLAGS := --keychain "$(LOCAL_KEYCHAIN)"
else
SIGN_ID    ?= -
SIGN_FLAGS :=
endif
SWIFT      ?= swift
BIN_DIR     = $(shell $(SWIFT) build -c $(CONFIG) --show-bin-path)

.PHONY: all build app run scan-home test probe icon clean signing-identity unlock-signing universal dmg media

all: app

build:
	$(SWIFT) build -c $(CONFIG) --product $(APP_NAME)

signing-identity:
	Scripts/make-signing-identity.sh

unlock-signing:
	@if [ "$(HAS_LOCAL_ID)" = yes ]; then security unlock-keychain -p "$$(cat $(LOCAL_PASSFILE))" "$(LOCAL_KEYCHAIN)"; fi

app: build unlock-signing
	@rm -rf "$(APP)"
	@mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	@cp "$(BIN_DIR)/$(APP_NAME)" "$(APP)/Contents/MacOS/$(APP_NAME)"
	@cp Info.plist "$(APP)/Contents/Info.plist"
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"; fi
	@# Inside-out signing: nested code first (frameworks, dylibs, helpers), then the bundle.
	@find "$(APP)/Contents" -depth \( -name "*.dylib" -o -name "*.framework" -o -name "*.xpc" -o -name "*.appex" \) \
		-exec codesign --force --timestamp=none --options runtime $(SIGN_FLAGS) --sign "$(SIGN_ID)" {} \; 2>/dev/null || true
	@codesign --force --timestamp=none --options runtime $(SIGN_FLAGS) --sign "$(SIGN_ID)" "$(APP)"
	@codesign --verify --strict --verbose=1 "$(APP)"
	@echo "Built $(APP)"

VERSION    := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
DMG        := $(BUILD_DIR)/$(APP_NAME)-$(VERSION).dmg

# One binary for Apple silicon and Intel, then the same bundle + signing as `app`.
universal: unlock-signing
	$(SWIFT) build -c release --product $(APP_NAME) --triple arm64-apple-macosx14.0
	$(SWIFT) build -c release --product $(APP_NAME) --triple x86_64-apple-macosx14.0
	@rm -rf "$(APP)"
	@mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	@lipo -create -output "$(APP)/Contents/MacOS/$(APP_NAME)" \
		.build/arm64-apple-macosx/release/$(APP_NAME) .build/x86_64-apple-macosx/release/$(APP_NAME)
	@cp Info.plist "$(APP)/Contents/Info.plist"
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"; fi
	@codesign --force --timestamp=none --options runtime $(SIGN_FLAGS) --sign "$(SIGN_ID)" "$(APP)"
	@codesign --verify --strict --verbose=1 "$(APP)"
	@lipo -archs "$(APP)/Contents/MacOS/$(APP_NAME)"

# Drag-to-Applications disk image.
dmg: universal
	@rm -rf "$(BUILD_DIR)/dmg" "$(DMG)"
	@mkdir -p "$(BUILD_DIR)/dmg"
	@cp -R "$(APP)" "$(BUILD_DIR)/dmg/"
	@ln -s /Applications "$(BUILD_DIR)/dmg/Applications"
	@hdiutil create -quiet -volname "$(APP_NAME) $(VERSION)" -srcfolder "$(BUILD_DIR)/dmg" -fs APFS -format ULFO -ov "$(DMG)"
	@codesign --force --timestamp=none $(SIGN_FLAGS) --sign "$(SIGN_ID)" "$(DMG)"
	@rm -rf "$(BUILD_DIR)/dmg"
	@shasum -a 256 "$(DMG)"
	@echo "Built $(DMG)"

media: app
	Scripts/make-media.sh

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
