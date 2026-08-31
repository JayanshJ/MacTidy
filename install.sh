#!/bin/bash
#
# MacTidy one-command installer.
#
#   curl -fsSL https://raw.githubusercontent.com/JayanshJ/MacTidy/main/install.sh | bash
#
# Or clone and run locally:
#   ./install.sh
#
# Does everything except granting Full Disk Access (which macOS requires the
# user to do manually for non-notarized apps). Opens the right Settings pane
# and prints step-by-step instructions so the user only visits System Settings
# ONCE.
#
set -euo pipefail

BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

info()  { echo -e "${GREEN}✓${RESET} $1"; }
warn()  { echo -e "${YELLOW}⚠${RESET} $1"; }
step()  { echo -e "${BOLD}[$1]${RESET} $2"; }
fail()  { echo -e "${RED}✗${RESET} $1"; exit 1; }

APP_NAME="MacTidy"
APP_BUNDLE="MacTidy.app"
APP_PATH="/Applications/${APP_BUNDLE}"
REPO_URL="https://github.com/JayanshJ/MacTidy.git"
CERT_NAME="MacTidy Signing"

# ─── 0. Preflight ────────────────────────────────────────────────────────

step "1/6" "Checking prerequisites…"

if [[ "$(uname)" != "Darwin" ]]; then
    fail "This installer is for macOS only."
fi

if ! xcode-select -p &>/dev/null; then
    warn "Xcode Command Line Tools not found. Installing…"
    xcode-select --install 2>/dev/null || true
    echo ""
    echo "  A system dialog will appear. Click Install, wait for it to finish,"
    echo "  then re-run this script."
    echo ""
    exit 0
fi
info "Command Line Tools present."

if ! command -v swift &>/dev/null; then
    fail "Swift compiler not found. Install Xcode Command Line Tools first: xcode-select --install"
fi
info "Swift $(swift --version 2>&1 | head -1 | awk '{print $4}') present."

# ─── 1. Clone or update ──────────────────────────────────────────────────

TMP_DIR="${TMPDIR:-/tmp}/mactidy-build-$$"
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ -f "Package.swift" && -f "Makefile" ]]; then
    # Running from inside the repo already.
    BUILD_DIR="$(pwd)"
    step "2/6" "Building from current directory…"
else
    step "2/6" "Cloning MacTidy…"
    git clone --depth 1 "$REPO_URL" "$TMP_DIR" 2>/dev/null || fail "Could not clone the repository."
    BUILD_DIR="$TMP_DIR"
    info "Cloned to $TMP_DIR"
fi

# ─── 2. Create self-signed cert (one-time, so FDA survives rebuilds) ────

step "3/6" "Setting up signing certificate…"
cd "$BUILD_DIR"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    info "Signing certificate '$CERT_NAME' already exists."
else
    warn "Creating self-signed certificate '$CERT_NAME' (one-time)…"
    # This may prompt for keychain access — that's expected.
    if [[ -f "Support/make-signing-cert.sh" ]]; then
        bash Support/make-signing-cert.sh 2>/dev/null || {
            warn "Could not create certificate automatically. Will use ad-hoc signing."
            warn "Full Disk Access will need to be re-granted after each rebuild."
            warn "To fix: run 'make cert' manually after this script finishes."
        }
    else
        warn "make-signing-cert.sh not found. Using ad-hoc signing."
    fi
fi

# ─── 3. Build + sign ────────────────────────────────────────────────────

step "4/6" "Building ${APP_NAME}…"
echo "  (This takes about 30–60 seconds. Compiling release build…)"
make app 2>&1 | tail -3
info "Build complete."

# Verify the app was built.
if [[ ! -f "dist/${APP_BUNDLE}/Contents/MacOS/MacTidy" ]]; then
    fail "Build did not produce ${APP_BUNDLE}. Check the output above."
fi

# ─── 4. Install to /Applications ─────────────────────────────────────────

step "5/6" "Installing to /Applications…"

# Remove old version if present.
if [[ -d "$APP_PATH" ]]; then
    # Kill it if running.
    pkill -x MacTidy 2>/dev/null || true
    sleep 1
    rm -rf "$APP_PATH"
fi

cp -R "dist/${APP_BUNDLE}" "$APP_PATH"
info "Installed to $APP_PATH"

# Strip quarantine — prevents the "Apple cannot check it for malicious
# software" Gatekeeper dialog. Since the user built this from source
# themselves, quarantine (which is only set on downloaded files) may or may
# not be present, but stripping it is harmless and prevents the dialog.
xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true
info "Quarantine flag stripped."

# ─── 5. Open Full Disk Access settings ───────────────────────────────────

step "6/6" "Full Disk Access setup…"

echo ""
echo -e "${BOLD}Almost done! One manual step:${RESET}"
echo ""
echo "  ${APP_NAME} needs Full Disk Access to scan ~/Library completely."
echo "  Without it, macOS hides parts of ~/Library and the scan would be"
echo "  silently incomplete."
echo ""
echo -e "  ${BOLD}Opening System Settings → Privacy & Security → Full Disk Access…${RESET}"
echo ""

# Open the FDA settings pane directly (macOS 13+ URL).
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

echo "  Once the settings window opens:"
echo ""
echo -e "  ${GREEN}1.${RESET} Click the ${BOLD}+${RESET} button at the bottom"
echo -e "  ${GREEN}2.${RESET} Navigate to ${BOLD}/Applications${RESET} and select ${BOLD}MacTidy.app${RESET}"
echo -e "  ${GREEN}3.${RESET} Click ${BOLD}Open${RESET}"
echo ""
echo "  That's it — you only need to do this once. The self-signed cert"
echo "  means the grant survives future rebuilds."
echo ""

# Offer to launch the app.
read -rp "$(echo -e ${BOLD}Launch MacTidy now? [Y/n]${RESET} ) " launch
launch=${launch:-Y}
if [[ "$launch" =~ ^[Yy]$ ]]; then
    open "$APP_PATH"
    info "MacTidy launched!"
else
    info "You can launch it later: open /Applications/MacTidy.app"
fi

echo ""
echo -e "${GREEN}${BOLD}Installation complete!${RESET}"