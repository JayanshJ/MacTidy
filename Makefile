# MacTidy — build, test, and package (no Xcode required, CLT is enough).

APP := dist/MacTidy.app

# The Command Line Tools ship Swift Testing outside the default search
# paths. The -F flag must be global (not per-target in Package.swift):
# SwiftPM's synthesized test runner is a separate module whose
# `#if canImport(Testing)` silently compiles to a no-op without it.
CLT_FRAMEWORKS := $(wildcard /Library/Developer/CommandLineTools/Library/Developer/Frameworks)
TEST_FLAGS := $(if $(CLT_FRAMEWORKS),-Xswiftc -F -Xswiftc $(CLT_FRAMEWORKS),)

# Sign with the stable "MacTidy Signing" identity when it exists (create it
# once with `make cert`) so the Full Disk Access grant survives rebuilds;
# fall back to ad-hoc otherwise.
SIGN_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q "MacTidy Signing" && echo "MacTidy Signing" || echo "-")

.PHONY: build test app run cert clean

build:
	swift build -c release

test:
	swift test $(TEST_FLAGS)

# Wrap the SwiftPM binary into a real .app bundle and ad-hoc sign it
# (codesign -s -). Never add the App Sandbox entitlement — it breaks
# the whole tool. Grant the app Full Disk Access on first run.
app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/release/MacTidy $(APP)/Contents/MacOS/MacTidy
	cp Support/Info.plist $(APP)/Contents/Info.plist
	cp Support/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	codesign --force --sign "$(SIGN_IDENTITY)" $(APP)
	@echo "Built $(APP) (signed: $(SIGN_IDENTITY))"

run: app
	open $(APP)

cert:
	./Support/make-signing-cert.sh

clean:
	swift package clean
	rm -rf dist
