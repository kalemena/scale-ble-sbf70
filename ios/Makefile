# Makefile for the SBF70 iOS app (SwiftUI) + Sbf70Kit Swift package.
#
# Two layers:
#   * Sbf70Kit (SPM)  — pure logic/protocol/storage; builds & tests WITHOUT Xcode
#                       project generation (`kit-*`, `smoke`, `test`).
#   * Sbf70App (Xcode) — SwiftUI app target; needs a generated .xcodeproj
#                        (`setup`/`generate`) and `xcodebuild` (`build`,
#                        `archive`, `ipa`).
#
# Quick start:
#   make setup        # install xcodegen (if needed) + generate the Xcode project
#   make smoke        # run the no-Xcode protocol checks (fast sanity)
#   make build        # build the app for the simulator
#
# Install a Release build on your own iPhone over cable (free Apple ID is fine;
# signing lasts ~7 days, then re-run):
#   make devices                               # find your iPhone's UDID
#   make install DEVELOPMENT_TEAM=ABCDE12345   # build + sign + install

.PHONY: help setup doctor generate open \
        kit-build kit-test smoke test \
        build build-device archive ipa \
        devices install \
        clean distclean

# ---- Configuration (override on the command line, e.g. `make build CONFIG=Release`) ----

PROJECT       ?= Sbf70App.xcodeproj
SCHEME        ?= Sbf70App
CONFIG        ?= Debug
KIT_DIR       ?= Sbf70Kit

# Simulator destination. Override DEVICE to target a specific simulator, e.g.
#   make build DEVICE='platform=iOS Simulator,name=iPhone 15'
DEVICE        ?= generic/platform=iOS Simulator
# Physical-device destination (requires provisioning/signing set up in Xcode).
DEVICE_REAL   ?= generic/platform=iOS

# Build output locations.
BUILD_DIR     ?= build
ARCHIVE_PATH  ?= $(BUILD_DIR)/$(SCHEME).xcarchive
EXPORT_DIR    ?= $(BUILD_DIR)/ipa

# ---- Code signing (device builds) ----
#
# Installing on your own iPhone needs your Apple ID Team ID. With a FREE Apple
# ID (Personal Team) this works but Apple caps the signing validity at 7 DAYS —
# the app stops launching after that until you re-run `make install`.
#
# Find your Team ID: Xcode > Settings > Accounts > (your Apple ID) > team, or
# developer.apple.com > Membership. It is 10 chars, e.g. ABCDE12345.
#
#   make install DEVELOPMENT_TEAM=ABCDE12345
#
# EXPORT_METHOD: `development` works for free + paid teams (what you want here).
#                `ad-hoc` / `release` need the paid Developer Program.
DEVELOPMENT_TEAM ?=
EXPORT_METHOD    ?= development
# Bundle identifier (must match project.yml); used to launch after install.
BUNDLE_ID        ?= org.kalemena.sbf70app
# Target device UDID for install. Empty = the single connected device.
DEVICE_UDID      ?=
IPA              ?= $(EXPORT_DIR)/$(SCHEME).ipa

XCODEBUILD    ?= xcodebuild
XCODEGEN      ?= xcodegen
XCPRETTY      := $(shell command -v xcpretty 2>/dev/null)

# Pipe xcodebuild through xcpretty when available, otherwise show raw output.
ifdef XCPRETTY
  FORMAT = | xcpretty && exit $${PIPESTATUS[0]}
else
  FORMAT =
endif

# ---- Help ----

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-14s\033[0m %s\n", $$1, $$2}'

# ---- Setup / tooling ----

setup: doctor generate ## Install tooling (xcodegen) and generate the Xcode project

doctor: ## Check required tools (Xcode, xcodegen) and install xcodegen if missing
	@command -v $(XCODEBUILD) >/dev/null 2>&1 || { \
		echo "ERROR: xcodebuild not found. Install Xcode from the App Store, then:"; \
		echo "       sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"; \
		exit 1; }
	@echo "xcodebuild: $$($(XCODEBUILD) -version | head -1)"
	@if ! command -v $(XCODEGEN) >/dev/null 2>&1; then \
		echo "xcodegen not found — attempting install..."; \
		if command -v brew >/dev/null 2>&1; then \
			brew install xcodegen; \
		else \
			echo "ERROR: Homebrew not found. Install xcodegen manually:"; \
			echo "       https://github.com/yonaskolb/XcodeGen#installing"; \
			exit 1; \
		fi; \
	fi
	@echo "xcodegen:   $$($(XCODEGEN) --version 2>/dev/null)"

generate: ## Regenerate $(PROJECT) from project.yml (requires xcodegen)
	@command -v $(XCODEGEN) >/dev/null 2>&1 || { echo "xcodegen missing — run 'make setup' first."; exit 1; }
	$(XCODEGEN) generate --spec project.yml
	@echo "Generated $(PROJECT)"

open: generate ## Open the project in Xcode
	open $(PROJECT)

# ---- Kit (SPM — no Xcode project needed) ----

kit-build: ## Build the Sbf70Kit Swift package (SPM)
	cd $(KIT_DIR) && swift build

kit-test: ## Run the Sbf70Kit XCTest suite (SPM)
	cd $(KIT_DIR) && swift test

smoke: ## Run the no-Xcode protocol smoke checks (swift run sbf70-smoke)
	cd $(KIT_DIR) && swift run sbf70-smoke

test: kit-test ## Alias: run the kit unit tests

# ---- App (xcodebuild — needs the generated project) ----

build: generate ## Build the app for the iOS Simulator
	set -o pipefail; $(XCODEBUILD) \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-destination '$(DEVICE)' \
		build $(FORMAT)

build-device: generate ## Build the app for a physical device (needs signing)
	set -o pipefail; $(XCODEBUILD) \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-destination '$(DEVICE_REAL)' \
		build $(FORMAT)

archive: generate ## Archive the app for a device (Release, signed — needs DEVELOPMENT_TEAM)
	@test -n "$(DEVELOPMENT_TEAM)" || { \
		echo "ERROR: DEVELOPMENT_TEAM is required for a device archive."; \
		echo "       Find your Team ID in Xcode > Settings > Accounts, then:"; \
		echo "       make archive DEVELOPMENT_TEAM=ABCDE12345"; \
		exit 1; }
	set -o pipefail; $(XCODEBUILD) \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Release \
		-destination '$(DEVICE_REAL)' \
		-archivePath $(ARCHIVE_PATH) \
		-allowProvisioningUpdates \
		DEVELOPMENT_TEAM=$(DEVELOPMENT_TEAM) \
		CODE_SIGN_STYLE=Automatic \
		archive $(FORMAT)

ipa: archive ## Export a signed .ipa (EXPORT_METHOD=development for free teams)
	@mkdir -p $(EXPORT_DIR)
	@printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0"><dict>' \
		'  <key>method</key><string>$(EXPORT_METHOD)</string>' \
		'  <key>signingStyle</key><string>automatic</string>' \
		'  <key>teamID</key><string>$(DEVELOPMENT_TEAM)</string>' \
		'  <key>destination</key><string>export</string>' \
		'  <key>stripSwiftSymbols</key><true/>' \
		'</dict></plist>' > $(BUILD_DIR)/ExportOptions.plist
	set -o pipefail; $(XCODEBUILD) \
		-exportArchive \
		-archivePath $(ARCHIVE_PATH) \
		-exportOptionsPlist $(BUILD_DIR)/ExportOptions.plist \
		-exportPath $(EXPORT_DIR) \
		-allowProvisioningUpdates $(FORMAT)
	@echo "IPA(s) in $(EXPORT_DIR):"; ls -1 $(EXPORT_DIR)/*.ipa 2>/dev/null \
		|| echo "  (export failed — check signing: 'make archive DEVELOPMENT_TEAM=...')"

# ---- Device install (over cable, via CoreDevice / devicectl) ----

devices: ## List connected iPhones (name + UDID) for install
	@echo "Connected devices:"
	@xcrun devicectl list devices 2>/dev/null \
		|| { echo "devicectl unavailable (needs Xcode 15+)."; exit 1; }

install: ipa ## Build, sign, and install the Release app on a cabled iPhone
	@IPA_FILE=$$(ls -1 $(EXPORT_DIR)/*.ipa 2>/dev/null | head -1); \
	test -n "$$IPA_FILE" || { echo "ERROR: no .ipa to install in $(EXPORT_DIR)."; exit 1; }; \
	if [ -n "$(DEVICE_UDID)" ]; then \
		echo "Installing $$IPA_FILE to $(DEVICE_UDID)..."; \
		xcrun devicectl device install app --device $(DEVICE_UDID) "$$IPA_FILE"; \
	else \
		echo "Installing $$IPA_FILE to the connected device..."; \
		xcrun devicectl device install app "$$IPA_FILE"; \
	fi
	@echo ""
	@echo "Installed. On the iPhone, first launch needs trust:"
	@echo "  Settings > General > VPN & Device Management > trust your developer Apple ID."
	@echo "NOTE: free Apple ID signing expires after ~7 days — re-run 'make install' to renew."

# ---- Cleanup ----

clean: ## Remove build artifacts (keeps the generated project)
	rm -rf $(BUILD_DIR)
	cd $(KIT_DIR) && swift package clean 2>/dev/null || true
	-$(XCODEBUILD) -project $(PROJECT) -scheme $(SCHEME) clean >/dev/null 2>&1 || true

distclean: clean ## Also remove the generated .xcodeproj and SPM build dir
	rm -rf $(PROJECT)
	rm -rf $(KIT_DIR)/.build
