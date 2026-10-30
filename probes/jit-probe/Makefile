# Pinned to the beta rather than inherited from xcode-select, which is machine
# state that can be flipped between runs. Override with DEVELOPER_DIR=... if
# that stops being the right one.
export DEVELOPER_DIR ?= /Applications/Xcode-beta.app/Contents/Developer

SCHEME  := JITProbe
PROJECT := JITProbe.xcodeproj
BUNDLE  := local.jitprobe.s0
DERIVED := build

# Passed in rather than committed: DEV_TEAM=XXXXXXXXXX make run
TEAMFLAG := $(if $(DEV_TEAM),DEVELOPMENT_TEAM=$(DEV_TEAM),)

.PHONY: help gen check device run run-debug journal clean

help:
	@echo "Xcode:  $(shell $(DEVELOPER_DIR)/usr/bin/xcodebuild -version 2>/dev/null | head -1) at $(DEVELOPER_DIR)"
	@echo
	@echo "make check      -- generate and compile for the simulator (no device, no signing)"
	@echo "make device     -- build for a real headset (needs DEV_TEAM=...)"
	@echo "make run        -- mode 1: install and launch DETACHED, stream the log"
	@echo "make run-debug  -- modes 2 and 3: launch stopped, attach lldb, detach, re-run in app"
	@echo "make journal    -- pull the crash journal off the device"
	@echo "make clean      -- drop the generated project and build output"
	@echo
	@echo "Protocol is in README.md. Pipe it: make run | tee /tmp/jitprobe.log"

gen:
	xcodegen generate

# Compiles against the visionOS SDK without a device or a team. Proves the
# code builds. Proves NOTHING about JIT: the simulator is a macOS process and
# inherits macOS policy, which is exactly the policy under question.
check: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'generic/platform=visionOS Simulator' \
		-derivedDataPath $(DERIVED) \
		CODE_SIGNING_ALLOWED=NO \
		ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
		build

# -allowProvisioningUpdates lets xcodebuild register an App ID and create a
# provisioning profile on your Apple account. That is a change on Apple's side
# made with your credentials, which is why it is explicit here rather than
# something a script does quietly. On a free personal team the profile expires
# in about a week; rerun this when it does.
device: gen
	@test -n "$(DEV_TEAM)" || { echo "set DEV_TEAM=... (security find-identity -p codesigning -v lists yours)"; exit 1; }
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'generic/platform=visionOS' \
		-derivedDataPath $(DERIVED) \
		$(TEAMFLAG) \
		-allowProvisioningUpdates \
		build

run: device
	@bash run.sh $(BUNDLE) $(SCHEME) $(DERIVED)

run-debug: device
	@bash run-debug.sh $(BUNDLE) $(SCHEME) $(DERIVED)

journal:
	@bash journal.sh $(BUNDLE)

clean:
	rm -rf $(PROJECT) $(DERIVED)
