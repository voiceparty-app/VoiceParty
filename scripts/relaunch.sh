#!/bin/zsh
# Restarts build/VoiceParty.app in the background (no windows brought forward), waiting for the old copy to
# exit first — opening it while the old one is still quitting fails with LaunchServices error -600.
set -euo pipefail
cd "$(dirname "$0")/.."
pkill -TERM -x VoiceParty 2>/dev/null || true
for _ in {1..40}; do pgrep -x VoiceParty >/dev/null || break; sleep 0.25; done
pgrep -x VoiceParty >/dev/null && { echo "✗ The old VoiceParty didn't quit."; exit 1; }
# Right after a rebuild LaunchServices can still refuse the launch (-600) for a moment: retry a few times.
for attempt in 1 2 3 4 5; do
  open -g build/VoiceParty.app --args --background 2>/dev/null && break
  sleep 1
done
for _ in {1..40}; do pgrep -x VoiceParty >/dev/null && { echo "VoiceParty relaunched (pid $(pgrep -x VoiceParty))."; exit 0; }; sleep 0.25; done
echo "✗ VoiceParty didn't start."; exit 1
