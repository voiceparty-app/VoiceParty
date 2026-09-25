#!/bin/bash
# Installs (or updates) VoiceParty. Paste into Terminal:
#
#   curl -fsSL https://raw.githubusercontent.com/voiceparty-app/VoiceParty/main/install.sh | bash
#
# Why a Terminal command: macOS only runs its "unidentified developer" checks (Gatekeeper) on files that a
# browser, AirDrop or Mail downloaded, because those get a quarantine flag. curl doesn't set it, so there are no
# security dialogs to click through and no paid Apple developer account is needed. Instead this script checks
# the app itself: the download must match its published checksum, and the app must be signed with
# VoiceParty's own certificate (not just any valid signature) before anything is installed.
#
# Options (environment variables):
#   VOICEPARTY_URL=…        download from another address (a zip containing VoiceParty.app)
#   VOICEPARTY_DEST=…       install somewhere other than /Applications
#   VOICEPARTY_NO_LAUNCH=1  don't quit/relaunch the app (used by tests)
#   bash install.sh --uninstall [--delete-data]
set -euo pipefail

REPO="${VOICEPARTY_REPO:-voiceparty-app/VoiceParty}"
URL="${VOICEPARTY_URL:-https://github.com/$REPO/releases/latest/download/VoiceParty.zip}"
DEST="${VOICEPARTY_DEST:-/Applications}"
APP_ID="dev.voiceparty.VoiceParty"
# Who may sign VoiceParty: this identifier and this exact certificate (filled in when a release is made).
SIGNER='identifier "dev.voiceparty.VoiceParty" and certificate leaf = H"e02607b937d4fe8621a6eb7505e267e61943af1a"'
REQUIREMENT="${VOICEPARTY_REQUIREMENT:-$SIGNER}"

say() { printf '%s\n' "$*"; }
die() { printf '\n✗ %s\n' "$*" >&2; exit 1; }

quit_app() {
    [[ -n "${VOICEPARTY_NO_LAUNCH:-}" ]] && return
    osascript -e "quit app id \"$APP_ID\"" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x VoiceParty >/dev/null || break; sleep 0.3; done
    pkill -x VoiceParty 2>/dev/null || true
}

uninstall() {
    quit_app
    for dir in /Applications "$HOME/Applications"; do rm -rf "$dir/VoiceParty.app"; done
    if [[ "${1:-}" == "--delete-data" ]]; then
        rm -rf "$HOME/Library/Application Support/VoiceParty"
        defaults delete "$APP_ID" >/dev/null 2>&1 || true
        # Forget the Microphone, Accessibility, Calendar and other permissions it was given.
        tccutil reset All "$APP_ID" >/dev/null 2>&1 || true
        say "VoiceParty and all its data (history, dictionary, downloaded models, permissions) were removed."
    else
        say "VoiceParty was removed. Your history, dictionary and models are kept in ~/Library/Application Support/VoiceParty."
    fi
}

install() {
    # VoiceParty uses Apple's on-device speech and language models: Apple silicon, macOS 26 or later.
    [[ "$(uname -m)" == "arm64" ]] || die "VoiceParty needs a Mac with Apple silicon (M1 or later)."
    local major
    major="$(sw_vers -productVersion | cut -d. -f1)"
    (( major >= 26 )) || die "VoiceParty needs macOS 26 or later; this Mac has macOS $(sw_vers -productVersion). Update in System Settings → General → Software Update."
    [[ "$URL" != *"OWNER/"* && "$REQUIREMENT" != __DESIGNATED* ]] ||
        die "This installer hasn't been set up for a release yet."

    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    say "Downloading VoiceParty…"
    curl -fL --progress-bar "$URL" -o "$tmp/VoiceParty.zip" || die "Couldn't download $URL"

    # The release publishes a SHA-256 next to the zip: refuse anything that doesn't match it.
    curl -fsL "$URL.sha256" -o "$tmp/expected.sha256" || die "Couldn't download the checksum for $URL"
    local expected actual
    expected="$(tr -d '[:space:]' < "$tmp/expected.sha256" | cut -c1-64)"
    actual="$(shasum -a 256 "$tmp/VoiceParty.zip" | cut -c1-64)"
    [[ "$expected" == "$actual" ]] || die "The download didn't match its checksum, so nothing was installed. Try again."
    say "Checksum verified."

    ditto -x -k "$tmp/VoiceParty.zip" "$tmp/unpacked"
    local app="$tmp/unpacked/VoiceParty.app"
    [[ -d "$app" && ! -L "$app" ]] || die "The download didn't contain VoiceParty.app."
    codesign --verify --deep --strict -R="$REQUIREMENT" "$app" 2>/dev/null ||
        die "This copy of VoiceParty isn't signed by VoiceParty's developer, so it wasn't installed."
    say "Signature verified."
    local version
    version="$(defaults read "$app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"

    quit_app
    if [[ ! -w "$DEST" ]]; then
        DEST="$HOME/Applications"   # no admin rights: install just for this user
        mkdir -p "$DEST"
    fi
    # Copy next to the old app first, then swap, so a failed copy leaves the old version working.
    rm -rf "$DEST/.VoiceParty.app.new"
    ditto "$app" "$DEST/.VoiceParty.app.new" || die "Couldn't copy VoiceParty into $DEST."
    rm -rf "$DEST/VoiceParty.app"
    mv "$DEST/.VoiceParty.app.new" "$DEST/VoiceParty.app"
    xattr -dr com.apple.quarantine "$DEST/VoiceParty.app" 2>/dev/null || true

    say ""
    say "✓ VoiceParty $version is installed in $DEST."
    if [[ -z "${VOICEPARTY_NO_LAUNCH:-}" ]]; then
        open "$DEST/VoiceParty.app"
        say "  It's opening now: allow Microphone and Accessibility when it asks, then hold the dictation key and talk."
    fi
    say "  To update later, run the same command again. To remove it: bash install.sh --uninstall"
}

main() {
    if [[ "${1:-}" == "--uninstall" ]]; then
        uninstall "${2:-}"
    else
        install
    fi
}

# Nothing runs until the whole script has arrived (a cut-off download can't run half of it).
main "$@"
