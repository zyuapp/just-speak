SHELL := /bin/bash

PROJECT := JustSpeak.xcodeproj
SCHEME := JustSpeak
CONFIGURATION ?= Debug
DERIVED_DATA := build
APP_PATH := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/JustSpeak.app
RECORDING_CUE_PATH := $(APP_PATH)/Contents/Resources/DoubleSpark.wav
DEV_BUNDLE_IDENTIFIER := com.zyu.just-speak.dev
DEV_DISPLAY_NAME := Just Speak Dev
INSTALL_PATH := /Applications/Just Speak Dev.app
LEGACY_INSTALL_PATH := /Applications/JustSpeakDev.app
XCODE_DERIVED_DATA := $(HOME)/Library/Developer/Xcode/DerivedData

.PHONY: build release test performance-test run open install clean-debug-apps clean rebuild

build:
	mkdir -p "$(DERIVED_DATA)"
	touch "$(DERIVED_DATA)/.metadata_never_index"
	xcodebuild -quiet -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration "$(CONFIGURATION)" -derivedDataPath "$(DERIVED_DATA)" PRODUCT_BUNDLE_IDENTIFIER="$(DEV_BUNDLE_IDENTIFIER)" APP_DISPLAY_NAME="$(DEV_DISPLAY_NAME)" SWIFT_ACTIVE_COMPILATION_CONDITIONS='$$(inherited) LOCAL_BUILD' build
	test -f "$(RECORDING_CUE_PATH)"
	./scripts/sign-local.sh "$(APP_PATH)"
	./scripts/verify-local-signing.sh "$(APP_PATH)"

release:
	$(MAKE) build CONFIGURATION=Release

test:
	xcodebuild -project "$(PROJECT)" -scheme JustSpeakPerformanceTests -configuration Release -derivedDataPath "$(DERIVED_DATA)" test -only-testing:JustSpeakPerformanceTests/CoreMLTranscriptionEngineTests

performance-test:
	xcodebuild -project "$(PROJECT)" -scheme JustSpeakPerformanceTests -configuration Release -derivedDataPath "$(DERIVED_DATA)" test

run: build
	open "$(APP_PATH)"

open:
	open "$(APP_PATH)"

install: release
	pkill -x JustSpeak 2>/dev/null || true
	rm -rf "$(LEGACY_INSTALL_PATH)"
	rm -rf "$(INSTALL_PATH)"
	ditto "$(DERIVED_DATA)/Build/Products/Release/JustSpeak.app" "$(INSTALL_PATH)"
	$(MAKE) clean-debug-apps
	rm -rf "$(DERIVED_DATA)/Build/Products/Release/JustSpeak.app"
	open "$(INSTALL_PATH)"

clean-debug-apps:
	rm -rf "$(DERIVED_DATA)/Build/Products/Debug/JustSpeak.app"
	if [ -d "$(XCODE_DERIVED_DATA)" ]; then find "$(XCODE_DERIVED_DATA)" -type d -path "*/Build/Products/Debug/JustSpeak.app" -prune -exec rm -rf {} +; fi

clean:
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration "$(CONFIGURATION)" -derivedDataPath "$(DERIVED_DATA)" clean
	rm -rf "$(DERIVED_DATA)"

rebuild: clean build
