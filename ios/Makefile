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
#   make archive ipa  # produce a .xcarchive and an unsigned .ipa

.PHONY: help setup doctor generate open \
        kit-build kit-test smoke test \
        build build-device archive ipa \
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

archive: generate ## Archive the app (Release .xcarchive)
	set -o pipefail; $(XCODEBUILD) \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Release \
		-destination '$(DEVICE_REAL)' \
		-archivePath $(ARCHIVE_PATH) \
		archive $(FORMAT)

ipa: archive ## Export an unsigned .ipa from the archive into $(EXPORT_DIR)
	@mkdir -p $(EXPORT_DIR)
	@printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0"><dict>' \
		'  <key>method</key><string>development</string>' \
		'  <key>signingStyle</key><string>automatic</string>' \
		'  <key>destination</key><string>export</string>' \
		'  <key>stripSwiftSymbols</key><true/>' \
		'</dict></plist>' > $(BUILD_DIR)/ExportOptions.plist
	set -o pipefail; $(XCODEBUILD) \
		-exportArchive \
		-archivePath $(ARCHIVE_PATH) \
		-exportOptionsPlist $(BUILD_DIR)/ExportOptions.plist \
		-exportPath $(EXPORT_DIR) $(FORMAT)
	@echo "IPA(s) in $(EXPORT_DIR):"; ls -1 $(EXPORT_DIR)/*.ipa 2>/dev/null || echo "  (export may require valid signing — see Xcode Signing & Capabilities)"

# ---- Cleanup ----

clean: ## Remove build artifacts (keeps the generated project)
	rm -rf $(BUILD_DIR)
	cd $(KIT_DIR) && swift package clean 2>/dev/null || true
	-$(XCODEBUILD) -project $(PROJECT) -scheme $(SCHEME) clean >/dev/null 2>&1 || true

distclean: clean ## Also remove the generated .xcodeproj and SPM build dir
	rm -rf $(PROJECT)
	rm -rf $(KIT_DIR)/.build
