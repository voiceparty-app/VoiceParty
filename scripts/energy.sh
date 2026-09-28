#!/bin/zsh
# Energy use of VoiceParty: the app plus the model servers it launched (they count as VoiceParty's energy in macOS),
# from the kernel's per-app counters: CPU, GPU and Neural Engine energy, CPU/GPU time, wakeups, memory. No sudo.
# See docs/energy.md for what the numbers mean and the last measurements.
#
#   scripts/energy.sh idle [--seconds 600]          # nothing dictated, models as they are
#   scripts/energy.sh idle-loaded [--seconds 600]   # nothing dictated, models loaded and held
#   scripts/energy.sh routes [--repeats 5]          # per dictation: ASR only, skip, fast, strong, long (warm, then cold)
#   scripts/energy.sh day [--gap 20]                # a dozen varied dictations, three after the models unloaded
#   scripts/energy.sh watch [--seconds 60]          # any window (while you dictate, record a meeting, open the hub…)
#   scripts/energy.sh snap > a.json; …; scripts/energy.sh snap > b.json; scripts/energy.sh diff a.json b.json
#   (--json out.json keeps the numbers, --label names them)
#
# The dictation scenarios need a development build with DebugURLs on (they run voiceparty://debug/dictate?live=1:
# key-down loads and warms the models like a real dictation, nothing is pasted or saved). Run them while nothing else
# uses the model servers: a bench talking to them counts as VoiceParty's energy too.
set -euo pipefail
cd "$(dirname "$0")/.."
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
swift build -c release --product vp-energy 2>&1 | grep -E "error" || true
exec .build/release/vp-energy "$@"
