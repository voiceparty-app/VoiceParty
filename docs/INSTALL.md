# Installing VoiceParty

VoiceParty isn't on the App Store and isn't notarized by Apple (that needs a paid developer account). The
installer does the checking instead: the download must match its published fingerprint (SHA-256) and be signed
with VoiceParty's own certificate, or nothing is installed. It then removes macOS's download flag (the
"quarantine" attribute) so the app opens without a Gatekeeper warning.

## For family and friends

You need a Mac with Apple silicon (M1 or later) running macOS 26 or later.

1. Open **Terminal** (press ⌘Space, type `Terminal`, press Return).
2. Paste this line and press Return:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/voiceparty-app/VoiceParty/main/install.sh | bash
   ```

3. VoiceParty opens. Allow **Microphone** and **Accessibility** when it asks (it shows you where).
4. Click into any text box, hold the dictation key and talk. Let go and your words appear.

- **Update:** run the same line again. Your settings, history and dictionary stay.
- **Remove:** `curl -fsSL https://raw.githubusercontent.com/voiceparty-app/VoiceParty/main/install.sh | bash -s -- --uninstall`
  (add `--delete-data` to also remove history, dictionary and downloaded models).

Why Terminal instead of a download link? macOS shows "can't be opened" warnings for apps a browser, AirDrop
or Mail downloaded unless the developer pays Apple for a certificate. Downloads made in Terminal don't get
that label, so there's nothing to click through. That also means macOS's own check is skipped, which is why the
installer checks the fingerprint and the certificate itself. Please don't download the zip in a browser — use
the line above. You can read [install.sh](../install.sh) first.

## For the maintainer

- **Release:** `scripts/release.sh` builds, verifies the signature and packages `dist/VoiceParty.zip`, its
  SHA-256 and `install.sh`. `scripts/release.sh --publish` also creates a GitHub release (needs `gh`).
- **Same certificate, always:** macOS ties Microphone/Accessibility permission to the signing certificate
  ("VoiceParty Dev", self-signed, free). Releases signed with it update without asking for permissions
  again. Back it up once: `security export -t identities -f pkcs12 -o ~/VoiceParty-signing.p12`.
- **Hosting:** the installer downloads `…/releases/latest/download/VoiceParty.zip` from the GitHub repo in
  `REPO` (install.sh) — a public repo, so no login is needed. Any other static host works too:
  `VOICEPARTY_URL=https://…/VoiceParty.zip bash install.sh` (put `VoiceParty.zip.sha256` next to it).
- **Tested:** install from a local zip into a scratch folder; a wrong checksum, or an app signed by anyone else
  (even with VoiceParty's identifier), refuses to install.
