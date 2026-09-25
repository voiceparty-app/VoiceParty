#!/bin/zsh
# Builds a shareable release into dist/: VoiceParty.zip, its SHA-256, and the installer.
#
#   scripts/release.sh                  # build + package
#   scripts/release.sh --publish        # …and create a GitHub release (needs `gh` and a GitHub remote)
#
# Every release must be signed with the same "VoiceParty Dev" certificate: macOS ties Microphone and
# Accessibility permission to it, so updates keep working on family Macs without re-granting. Back the
# certificate up once (it lives only in this Mac's login keychain):
#   security export -t identities -f pkcs12 -o ~/VoiceParty-signing.p12
set -euo pipefail
cd "$(dirname "$0")/.."

# The public GitHub repo ("owner/repo") releases come from: stamped into the app (in-app updates) and the installer.
REPO="${VOICEPARTY_UPDATE_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"
[[ -n "$REPO" ]] || { echo "✗ Set VOICEPARTY_UPDATE_REPO=owner/repo (or run inside the public repo)."; exit 1; }
VOICEPARTY_UPDATE_REPO="$REPO" VOICEPARTY_DEBUG_URLS=0 scripts/build-app.sh
APP=build/VoiceParty.app

# A release signed ad-hoc would make every update ask for permissions again.
authority="$(codesign -dvv "$APP" 2>&1 | grep '^Authority=' | head -1 || true)"
[[ "$authority" == "Authority=VoiceParty Dev" ]] || { echo "✗ Not signed with 'VoiceParty Dev' (run scripts/make-dev-cert.sh)."; exit 1; }
codesign --verify --deep --strict "$APP"
# No names from real dictations or the maintainer's details inside the app (string literals end up in the binary).
# The list is private, kept outside the repo.
TERMS="${VOICEPARTY_PRIVATE_TERMS:-$HOME/Library/Application Support/VoiceParty/eval/private-terms.txt}"
[[ -s "$TERMS" ]] || { echo "✗ No private-terms list at $TERMS."; exit 1; }
if strings -a "$APP/Contents/MacOS/VoiceParty" | grep -iE -f "$TERMS"; then echo "✗ Personal terms in the app binary (above)."; exit 1; fi
# Development hooks are compiled out of releases.
if strings -a "$APP/Contents/MacOS/VoiceParty" | grep -q "debug/hold-models"; then echo "✗ Debug URLs are compiled in."; exit 1; fi

version="$(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString)"
rm -rf dist && mkdir -p dist
ditto -c -k --keepParent "$APP" dist/VoiceParty.zip
shasum -a 256 dist/VoiceParty.zip | cut -c1-64 > dist/VoiceParty.zip.sha256
# The installer accepts only apps signed like this one (identifier + this certificate).
SIGNER="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
[[ "$SIGNER" == *"certificate leaf"* ]] || { echo "✗ Couldn't read the signing requirement."; exit 1; }
REPO="$REPO" SIGNER="$SIGNER" perl -pe 's#OWNER/VoiceParty#$ENV{REPO}#g; s#__DESIGNATED_REQUIREMENT__#$ENV{SIGNER}#g' install.sh > dist/install.sh
chmod +x dist/install.sh
echo "Packaged VoiceParty $version → dist/ ($(du -h dist/VoiceParty.zip | cut -f1))"

if [[ "${1:-}" == "--publish" ]]; then
    command -v gh >/dev/null || { echo "✗ Install the GitHub CLI (brew install gh) to publish."; exit 1; }
    gh release create "v$version" dist/VoiceParty.zip dist/VoiceParty.zip.sha256 --repo "$REPO" \
        --title "VoiceParty $version" --notes "Install or update: curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | bash"
fi
