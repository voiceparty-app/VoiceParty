#!/bin/zsh
# Builds build/VoiceParty.app and signs it with a stable identity so macOS permissions
# (Microphone, Accessibility) survive rebuilds.
#
#   scripts/build-app.sh            # release build
#   CONFIG=debug scripts/build-app.sh
#   VOICEPARTY_SIGN_IDENTITY="Apple Development: …" scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# The macOS 27 SDK in Command Line Tools turns SwiftUI's @State into a macro whose plugin only ships
# with Xcode; the 26.x SDK matches the deployment target and builds with CLT alone.
if [[ -z "${SDKROOT:-}" ]]; then
  for sdk in /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk; do
    [[ -d $sdk ]] && export SDKROOT=$sdk && break
  done
fi

CONFIG=${CONFIG:-release}
# Development builds include the voiceparty://debug/… test hooks (still off unless the DebugURLs default is set);
# release builds (scripts/release.sh) leave them out entirely.
FLAGS=()
[[ "${VOICEPARTY_DEBUG_URLS:-1}" == 1 ]] && FLAGS=(-Xswiftc -DVOICEPARTY_DEBUG_URLS)
swift build -c "$CONFIG" --product VoiceParty "${FLAGS[@]}"
BIN_DIR=$(swift build -c "$CONFIG" --show-bin-path "${FLAGS[@]}")

APP=build/VoiceParty.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/VoiceParty" "$APP/Contents/MacOS/VoiceParty"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Where in-app updates come from ("owner/repo" on GitHub); releases set it, dev builds leave updates off.
if [[ -n "${VOICEPARTY_UPDATE_REPO:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :VoicePartyUpdateRepo $VOICEPARTY_UPDATE_REPO" "$APP/Contents/Info.plist"
fi
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM resource bundles: inside the app, so it runs on Macs without this build folder. FluidAudio's holds only
# text-to-speech pronunciation data (derived from GPL-licensed espeak-ng) that VoiceParty never uses: left out.
for bundle in "$BIN_DIR"/*.bundle(N); do
  [[ "$(basename "$bundle")" == FluidAudio_FluidAudio.bundle ]] && continue
  cp -R "$bundle" "$APP/Contents/Resources/"
done
# Licenses: ours, and the notices of what's compiled in (Credits.rtf is what the About panel shows).
cp LICENSE NOTICE THIRD_PARTY_NOTICES.md Resources/Credits.rtf "$APP/Contents/Resources/"

IDENTITY=${VOICEPARTY_SIGN_IDENTITY:-VoiceParty Dev}
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  # Hardened runtime: no injected libraries or DYLD_ variables, and only the entitlements listed.
  codesign --force --sign "$IDENTITY" --identifier dev.voiceparty.VoiceParty --options runtime \
    --entitlements Resources/VoiceParty.entitlements "$APP"
else
  echo "⚠️  No '$IDENTITY' signing certificate (run scripts/make-dev-cert.sh). Signing ad-hoc:"
  echo "    macOS will forget Accessibility/Microphone permission on every rebuild."
  codesign --force --sign - --identifier dev.voiceparty.VoiceParty --options runtime --entitlements Resources/VoiceParty.entitlements "$APP"
fi
echo "Built $APP"
