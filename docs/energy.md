# Energy

VoiceParty runs all day and is used a few dozen times a day, so it should be close to invisible in energy. This page
says how to measure what it costs, what it cost in September 2026, and what was changed because of it.

## Measuring: `scripts/energy.sh`

macOS attributes energy to an app's *coalition*: the app and every process it launched, including ones that have
already exited. VoiceParty's llama-server model servers are its children, so their work — including a benchmark that
talks to them directly — counts as VoiceParty's (and can put it under "Using Significant Energy"). `vp-energy` (behind
`scripts/energy.sh`) reads the coalition's counters from the kernel, without sudo:

- **energy**: CPU, GPU and Neural Engine energy in joules (the kernel's own energy counters on Apple silicon),
- **time**: CPU time (and how much of it on performance cores), GPU time, Neural Engine time,
- **wakeups** (package idle and interrupt), disk reads and writes, processes started and exited,
- **memory**: the coalition's physical footprint, and each process's.

```
scripts/energy.sh idle [--seconds 600]          # nothing dictated, models as they are
scripts/energy.sh idle-loaded [--seconds 600]   # nothing dictated, models loaded and held
scripts/energy.sh routes [--repeats 5]          # per dictation: ASR only, skip, fast, strong, long (warm, then cold)
scripts/energy.sh loads [--repeats 3]           # loading the fast model, the strong one, both
scripts/energy.sh day [--gap 20]                # a dozen varied dictations, three after the models unloaded
scripts/energy.sh watch [--seconds 60]          # any window: while you dictate, record a meeting, keep the hub open…
scripts/energy.sh trace [--seconds 30]          # one line per half second (when does the energy land?)
scripts/energy.sh snap > a.json; …; scripts/energy.sh snap > b.json; scripts/energy.sh diff a.json b.json
```

The dictation scenarios need a development build with DebugURLs on. They use `voiceparty://debug/dictate?live=1&tiers=0`:
at "key-down" the app loads and warms the models exactly as a real dictation does, "speech" lasts as long as the audio,
then the audio is transcribed and cleaned up (nothing is pasted, nothing goes into history), and the latency from
"key-up" to the final text is reported (split into speech recognition and cleanup) with the route and the model that
ran. The audio is made with `say` from made-up text. Other hooks: `debug/unload-models` (a cold start without waiting
five minutes), `debug/load-models?which=fast,strong`, `debug/model-args?fast=…&strong=…&env=…&legacy=1` (restart the
servers with extra llama-server flags or environment, in memory only; `legacy=1` makes key-down behave as it did before
the changes below, for before/after runs in one session), and `debug/bar?seconds=20&level=0.5` / `?state=notes` (draw
the recording bar or the Notetaker pill). Run scenarios while nothing else uses the model servers.

Caveats (each cost a wrong conclusion once):

- **Compare in one session, alternating.** Speech recognition on the same audio took 370 ms in one run and 1.7 s two
  hours later (another load on the Mac); an after-run compared with an earlier before-run looked like a 2× latency
  regression that an alternating A/B then showed didn't exist. GPU power also rises as the GPU warms up (the same 150
  cleanups: 762 J of GPU energy at the start of a run, ~850 J later).
- **GPU energy is billed ~1.5 s after the GPU work** (`trace`), so leave a tail after the last request; per-dictation GPU
  numbers are noisy (compare medians), totals over a scenario are reliable.
- `vp-bench` sends a warm-up request before its cases: it hides the cost of whatever a cold model has to redo on its
  first request. Time raw requests (curl) for "first request after X".
- Apple's Foundation Models (the fallback when no local model is loaded) and the window server's work to draw the bar
  run in system processes: not in VoiceParty's coalition, not measured here.
- Numbers are from an M4 Max (48 GB) on AC power; absolute joules differ by machine, ratios less so.

## What VoiceParty cost (before the changes below)

| Scenario | Energy | Wakeups | Memory |
|---|---|---|---|
| Idle, models unloaded (5 min) | 0.01 J (≈0.03 mW) | 1.1/s | 551 MB (the app, speech model loaded) |
| Idle, both models loaded (5 min) | 0.12 J (0.4 mW) | 331/s (165/s per server) | 1.5 GB |
| Dictation, warm, no model (ASR only or skip) | 0.47 J | ~1,200–2,700 | |
| Dictation, warm, fast model | 1.6–1.8 J | ~3,500 | |
| Dictation, warm, strong model | 6.3–7.9 J | ~4,000 | |
| Dictation, 41 s hands-free (strong model) | 24–25 J | ~17,500 | |
| Loading the fast model (after the idle unload) | 2.0 J, ready in 1.1 s | | +0.3 GB |
| Loading the strong model | 15–25 J, ready in 4.2 s | | +0.65 GB (+2.4 GB file cache) |
| 150 cleanups back to back (a benchmark) | 949–1,040 J at 31–35 W | 450/s | |
| A dozen dictations 20 s apart, three cold (6.3 min) | 122 J (321 mW average) | 354/s | peak 1.2–1.7 GB |

Where it went:

- **Idle was already near-invisible** (0.03 mW with the models unloaded). The oddity: a loaded model server wakes ~165
  times a second while idle — llama.cpp's Metal residency-set keep-alive thread, which sleeps a few milliseconds at a
  time. It costs ~0.2 mW per server.
- **Every model request spun 12 CPU cores.** The whole model runs on the GPU, so llama.cpp's CPU threads only
  spin-wait for the next step (`--poll 50`): ~20% of a request's energy and 94% of the servers' CPU energy. During a
  benchmark that is 2.2 cores busy doing nothing (6 W); that plus the GPU (~25 W) is what put VoiceParty under "Using
  Significant Energy".
- **Every dictation sent a warm-up request to every loaded model**, although each already held the cleanup instructions
  in its cache: those two requests (and the spinning they set off) were most of the energy of a dictation that didn't
  use a model (0.47 J; 0.14 J without them).
- **Cold starts dominate a normal day.** A warm dictation costs 0.5–8 J; loading the strong model costs 15–25 J, most of
  it the GPU reading its ~1,300-token instructions (the warm-up that makes its first request fast). Under "Load when I
  dictate" a dictation after 5 idle minutes reloaded both models, whichever one it needed.
- The recording bar redrew its waveform every frame even in silence (4 mW, 7% of an efficiency core), and the
  Notetaker's pill redrew its pulsing dot every frame for a whole meeting (5 mW, 5% of a core).

## What changed

1. **No spinning CPU threads**: the strong model's llama-server runs with `--poll 0` (its threads wait for work
   asleep), the fast model's with `-t 1` (no thread pool). 150 cleanups, same run, alternating: CPU energy 187–195 J →
   11–13 J, total 949–1,040 J → 836–875 J (−18%), CPU time 67 s → 3 s, p50 117–119 → 106–110 ms; outputs identical on
   all 150 (final text and every raw model output) with either flag. On isolated dictations (two rounds of five), the
   fast model's cleanup took 160/155 ms spinning, 172/161 ms with `--poll 0` (waking 12 threads per step) and 164/153 ms
   with `-t 1`, at 0.9–1.0 J vs 0.5 J per dictation; the strong model's 286/284 ms spinning and 264/269 ms with
   `--poll 0`.
2. **Only the models a dictation can use** (`ModelWarmup.plan`). Key-down loaded every installed model even with AI
   cleanup off or at cleanup level "none". Now: nothing when no model can run; only the strong model
   where the router can only pick it (email, code, "more" cleanup, "English is my second language", Command Mode); both
   for everyday dictation, where the transcript decides at key-up.
3. **No redundant warm-up requests.** The key-down warm-up now runs only when a model's last request had other
   instructions (after meeting notes, a transform or a Command Mode answer), and for "English is my second language" it
   warms that prompt (the old one replaced it with the standard prompt on every dictation).
4. **The fast model stays loaded 30 minutes** under "Load when I dictate" (the strong one still goes after 5): reloading
   it costs 2 J, keeping it ~0.2 mW (~0.4 J per half hour), and short dictations after a pause get it instead of racing
   its load.
5. **Holds end with their owner.** A benchmark's `debug/hold-models` used to be a bare counter: a bench killed before its
   release kept both models loaded for the rest of the session. Holds now name their process (`?pid=`; bench.sh sends its
   own), end when it exits, and end anyway after 10 minutes without model work (`ModelHolds`). The Notetaker's hold is
   unchanged. The idle check also counts sustained server work it didn't ask for (a bench without a hold) and runs only
   while a model is loaded.
6. **Qwen's prompt cache capped at 2 GB** (`-cram 2048`, default 8 GB). It brings back the cleanup instructions or a
   meeting transcript after another prompt came between (a repeated 2,500-token notes prompt took 1.75 s with it, 3.4 s
   without); cleanup, second-language and notes prompts together used ~0.9 GB. Uncapped, the process had grown to ~9 GB
   after a day of benchmarks with many different prompts.
7. **The waveform pauses in silence, and the Notetaker's dot pulses in Core Animation** (the window server runs it): bar
   in silence 4 → 1 mW (CPU 1.4 → 0.2 s per 20 s), Notetaker pill 5 → 1 mW (1.0 → 0.1 s per 20 s). The bar while you
   speak is unchanged (7–8 mW).
8. **Slower permission polling once everything is granted** (every 10 s instead of 1.5 s) and tolerance on the app's
   periodic timers. Idle was already ~0.03 mW; no measurable change.

Kept as they were, after measuring: **Metal residency sets** (with `GGML_METAL_NO_RESIDENCY=1` an idle server wakes
1.5 times a second instead of 165, but strong-model cleanups a few seconds apart were ~40 ms slower and ~0.4 J dearer);
**`--no-warmup`** (saves ~2–3 J per load, within noise, since the app warms the model up itself right after).

## After (same session as a before-run, alternating)

Warm dictations, median of 3. Before = `legacy=1` with the old server flags (key-down loads and warms every model, CPU
threads spin, Qwen's cache uncapped); after = this branch, in that run still with residency sets off (the final build's
numbers, below the table, are the same within noise):

| Dictation | Energy before → after | Key-up → text before → after (cleanup part) |
|---|---|---|
| ASR only (2 words) | 0.46 → 0.13 J | 117 → 144 ms (17 → 28) |
| Skip (clean sentence) | 0.52 → 0.14 J | 297 → 294 ms (43 → 44) |
| Fast model | 1.57 → 0.53 J | 400 → 456 ms (168 → 183) |
| Strong model | 7.89 → 4.34 J | 698 → 694 ms (333 → 311) |
| 41 s hands-free (strong) | 24.1 → 14.7 J | 2.59 → 2.50 s (902 → 819) |

On the final build (residency sets on, `-t 1` for the fast model), a little later: 0.13, 0.14, 0.51, 3.9–4.3 and 14.6 J, with
the fast and strong dictations at 422–452 and 575–627 ms.

**A dozen dictations** (the day scenario, 6.3 minutes, three of them cold), same session: the dictations' own windows
117.9 → 106.2 J (−10%), CPU 25.5 → 14.9 J; every warm dictation cost less (a short message 0.49 → 0.15 J, the 41 s one
23.4 → 20.5 J, an email 13.3 → 10.5 J) and none got slower (median key-up → text 612 → 526 ms). The scenario's total,
135 → 147 J, is inside the noise of its three cold starts, which load both models (15–27 J each, attributed a second or
two late) and are most of it either way: that's what proposals A and B are about.

**Cold starts** (a dictation right after the idle unload, both models loading): 17–24 J before and after for everyday
dictation. Contexts that can only use the strong model no longer load the fast one (2 J), and with AI cleanup off (or
at level "none") nothing loads at all.

**Idle**: models unloaded, 0.01 J per 5 minutes before; after, 0.02 J per 10 minutes (0.6 wakeups/s; 1.1 before, and
1.3 in one 5-minute window after), with the hub open 0.01 J per 5 minutes (0.7/s). Both models loaded, 0.4 mW before and
after (residency sets kept: ~335 wakeups/s; with `GGML_METAL_NO_RESIDENCY=1`, 3.3 wakeups/s and ~0 mW).

**Holds**: a bench that dies without releasing its hold no longer keeps both models loaded (and waking 335 times a
second) for the rest of the session: its hold ends with its process, or after 10 minutes without model work.

Quality: `scripts/bench.sh` before (the running release) and after: hand 98.4, homophones 99.2, grammar 97.7, L2 93.3,
dev 92.5, held-out 95.4, paragraphs F1 0.597 — identical, and latency p50 equal or lower (held-out 116 → 112 ms).

## Proposals (tradeoffs, not changed)

The largest cost left is loading the strong model: 15–25 J and ~4 s to ready, most of it re-reading its instructions on
the GPU. Everyday dictation still loads it at key-down after a pause, because only the transcript (known at key-up)
says whether it's needed; a dictation that needs it while it's still loading falls back to the fast model.

- **A. Keep the strong model loaded longer** (adopted for Macs with 32 GB or more: 30 minutes like the fast one; still
  5 minutes below that). Considered: 30 minutes everywhere, or "Always ready" by default on Macs with
  ≥ 32 GB. Saves a 15–25 J reload for every dictation 5–30 minutes after the last one; keeping it loaded costs ~0.2 mW.
  Latency: better (no load racing the speech). Cost: memory — ~0.65 GB of footprint plus the 2.4 GB model file held
  resident, plus up to 2 GB of prompt cache.
- **B. Load the strong model only when the dictation is likely to need it** (the strong-only contexts as now, plus a
  recording that passes ~8 s), otherwise at key-up when the router asks for it. Saves a strong load on most cold starts.
  Cost: a short dictation that routes strong after a pause waits up to ~4 s, or gets the fast model (self-corrections
  like "actually, make that six" then fall to the rules, less reliably).
- **C. Remember the integrity check for the session.** Every server start hashes its files: the strong model 3.6 J and
  1.0 s of its ~4 s to ready, the fast one 0.7 J and 0.2 s. Re-hashing only when the file's identity or change time
  (ctime, which a normal process can't set) changed would still refuse files modified on disk, but trusts file metadata
  instead of the content; the current rule is a re-verification before each use, so this is a policy call.
- **D. Save the warmed-up strong model's cache to disk.** Its load is mostly the GPU re-reading ~1,300 tokens of fixed
  instructions; llama-server can save and restore a slot's cache (`--slot-save-path`), which would make that a ~170 MB
  read. It needs the slots API (turned off so the last prompt can't be read back) and the saved file would need the same
  integrity check as the model.
- **E. Waveform at 60 fps on 120 Hz displays** while speaking: the bar costs 7–8 mW and ~10% of an efficiency core while
  you talk; capping its redraw rate would roughly halve that, for a slightly less fluid animation.
- **F. Residency keep-alive without the polling thread**: llama.cpp's keep-alive thread wakes 165 times a second even when
  its keep-alive has expired (`GGML_METAL_RESIDENCY_KEEP_ALIVE_S=0` doesn't stop it). An upstream fix (sleep until the
  next use) would remove the idle wakeups without the ~40 ms `GGML_METAL_NO_RESIDENCY` costs.

## Not measured

- **A live Notetaker meeting** (it needs the microphone and a call app's audio). Measured instead: the pill (above), and
  one notes request on the strong model — a made-up 2,500-token transcript, 300 tokens of notes: 163 J and 4.9 s, or
  109 J and 3.2 s when the prompt cache already holds the transcript. That is the single most expensive thing VoiceParty
  does (a dictation is 0.1–15 J), once per meeting; the meeting's audio goes through the same speech engine as dictation
  (Neural Engine: 0.12 J for a few seconds of audio, 0.5 J for 41 s).
- **Battery power**: all numbers are on AC. On battery macOS favours efficiency cores and lower GPU clocks.
- The window server's share of drawing the bars, and Apple's Foundation Models when they stand in for a local model.
- Speech engines other than Parakeet Unified.

## Automatic model memory (adopted)

Settings → Model memory → **Automatic** is the default for new installs ("Load when I dictate" and "Always ready" stay,
and a saved choice is kept). It uses the "Load when I dictate" times while the Mac has memory to spare, and frees models
sooner as macOS's own free-memory figure (`kern.memorystatus_level`, what `memory_pressure` prints) drops: at 50% free
or more, 30 minutes (the smart model 5 on Macs under 32 GB); at 25% or less, 1 minute for the smart model and 5 for the
fast one; linear in between. It's read once per 30 s idle check (one sysctl, no new timer). macOS's memory-pressure
warning still unloads both at once, with a 2-minute pause before reloading. Checked in the app with `debug/memory?free=20`:
the smart model unloaded 61 s after its last use, the fast one stayed.
