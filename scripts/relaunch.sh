#!/bin/zsh
# Restarts build/VoiceParty.app in the background (no windows brought forward), waiting for the old copy to
# exit first — opening it while the old one is still quitting fails with LaunchServices error -600.
set -euo pipefail
cd "$(dirname "$0")/.."
pkill -TERM -x VoiceParty 2>/dev/null || true
for _ in {1..40}; do pgrep -x VoiceParty >/dev/null || break; sleep 0.25; done
pgrep -x VoiceParty >/dev/null && { echo "✗ The old VoiceParty didn't quit."; exit 1; }
# voiceparty:// links open whichever copy LaunchServices picks: a build in an agent worktree (.claude/worktrees/…) once took
# them, so a debug URL started that old copy next to this one and ran stale code. Only this build stays registered.
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSR" -dump 2>/dev/null | sed -n 's/^path: *\(.*VoiceParty\.app\) (0x[0-9a-f]*)$/\1/p' | sort -u | while read -r app; do
  [[ "$app" == "$PWD/build/VoiceParty.app" ]] || "$LSR" -u "$app" 2>/dev/null || true
done
"$LSR" -f "$PWD/build/VoiceParty.app" 2>/dev/null || true
# Right after a rebuild LaunchServices can still refuse the launch (-600) for a moment: retry a few times.
for attempt in 1 2 3 4 5; do
  open -g build/VoiceParty.app --args --background 2>/dev/null && break
  sleep 1
done
for _ in {1..40}; do pgrep -x VoiceParty >/dev/null && { echo "VoiceParty relaunched (pid $(pgrep -x VoiceParty))."; exit 0; }; sleep 0.25; done
echo "✗ VoiceParty didn't start."; exit 1
