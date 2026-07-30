# Stairstep build orchestration.
#
# `make` / `make run` are exactly Xcode's ⌘B / ⌘R: the same project, scheme,
# configuration, destination, and default DerivedData, so make and Xcode share
# one incremental build. Dependency targets wrap the scripts in Scripts/ (which
# stay the source of truth) with existence checks so the hour-long OpenCascade
# builds only run when their outputs are missing.
#
#   make              build the macOS app, like pressing Build in Xcode,
#                     building the OpenCascade static libraries first if needed
#   make run          build and launch, like Build & Run
#   make release      the same build in the Release configuration
#   make ios          build the iOS app for the simulator (needs the XCFramework)
#   make spm          fast type-check build of the Swift package
#   make help         list all targets
#
# Knobs (environment or make variables):
#   CONFIGURATION=debug|release   app build configuration (default debug)
#   JOBS=N                        parallel jobs for the OpenCascade builds

CONFIGURATION ?= debug
ifeq ($(CONFIGURATION),release)
XCODE_CONFIGURATION := Release
else
XCODE_CONFIGURATION := Debug
endif

PROJECT := Stairstep.xcodeproj
SCHEME := Stairstep
MACOS_DESTINATION := platform=macOS,arch=arm64

# The scheme's build product in Xcode's own DerivedData, straight from
# xcodebuild — the identical .app that pressing Run would launch.
BUILT_APP = $$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	-configuration $(XCODE_CONFIGURATION) -destination '$(MACOS_DESTINATION)' \
	-showBuildSettings 2>/dev/null \
	| awk -F' = ' '/ TARGET_BUILD_DIR = /{d=$$2} / FULL_PRODUCT_NAME = /{n=$$2} END{print d "/" n}')

# One representative artifact per generated OpenCascade install. If the stamp
# exists the install is treated as complete; `make occt*` forces a rebuild.
OCCT_MACOS := Vendor/OpenCascadeStatic/macos-arm64/lib/libTKernel.a
OCCT_IOS := Vendor/OpenCascadeStatic/ios-arm64/lib/libTKernel.a
OCCT_XCFRAMEWORK := Vendor/OpenCascadeStatic/OpenCascadeStairs.xcframework/Info.plist

.PHONY: all app release run ios spm icon deps deps-ios deps-all \
	occt occt-ios occt-xcframework submodules \
	clean clean-occt help

all: app

## App

app: deps ## Build the macOS app, exactly like Xcode's Build (CONFIGURATION=debug|release)
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(XCODE_CONFIGURATION) \
		-destination '$(MACOS_DESTINATION)' \
		build
	@echo $(BUILT_APP)

release: deps ## Build the macOS app in Release configuration
	$(MAKE) app CONFIGURATION=release

run: app ## Build and launch the macOS app, like Xcode's Build & Run
	open "$(BUILT_APP)"

ios: deps-ios ## Build the iOS app for the arm64 simulator
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(XCODE_CONFIGURATION) \
		-destination 'generic/platform=iOS Simulator' \
		build

spm: deps ## Build the Swift package (fastest full type-check)
	swift build

icon: ## Regenerate App/Resources/AppIcon.icns from its generator script
	swift scripts/generate_app_icon.swift

## Dependencies (vendored OpenCascade static builds)

deps: $(OCCT_MACOS) ## Ensure the macOS OpenCascade static libraries exist

deps-ios: $(OCCT_XCFRAMEWORK) ## Ensure the iOS OpenCascade XCFramework exists

deps-all: deps deps-ios ## Ensure every OpenCascade artifact exists

$(OCCT_MACOS):
	git submodule update --init --recursive Vendor/OCCT Vendor/RapidJSON
	Scripts/build-occt.sh

$(OCCT_IOS):
	git submodule update --init --recursive Vendor/OCCT Vendor/RapidJSON
	Scripts/build-occt-ios.sh

# The XCFramework bundles the macOS, iOS, and iOS-simulator installs, so both
# static builds must exist before it can be assembled.
$(OCCT_XCFRAMEWORK): $(OCCT_MACOS) $(OCCT_IOS)
	Scripts/build-occt-xcframework.sh

occt: submodules ## Force-rebuild the macOS OpenCascade static libraries
	Scripts/build-occt.sh

occt-ios: submodules ## Force-rebuild the iOS/simulator OpenCascade static libraries
	Scripts/build-occt-ios.sh

occt-xcframework: ## Force-reassemble the OpenCascade XCFramework from the installs
	Scripts/build-occt-xcframework.sh

submodules: ## Initialize the OCCT and RapidJSON source submodules
	git submodule update --init --recursive Vendor/OCCT Vendor/RapidJSON

## Housekeeping

clean: ## Clean the Xcode build folder and local build products (keeps the OpenCascade installs)
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(XCODE_CONFIGURATION) \
		-destination '$(MACOS_DESTINATION)' \
		clean
	rm -rf build dist .build

clean-occt: ## Remove the generated OpenCascade installs (rebuilding takes a long time)
	rm -rf \
		Vendor/OpenCascadeStatic/macos-arm64 \
		Vendor/OpenCascadeStatic/ios-arm64 \
		Vendor/OpenCascadeStatic/ios-simulator-arm64 \
		Vendor/OpenCascadeStatic/OpenCascadeStairs.xcframework

help: ## List targets
	@awk -F':.*## ' '/^## /{printf "\n%s\n", substr($$0, 4)} /^[a-zA-Z][a-zA-Z0-9_-]*:.*## /{printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
