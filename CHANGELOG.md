# Changelog

What changed in each VoiceParty release. VoiceParty checks for updates once a day and offers new versions on its own.

## 0.1.3 — 2026-10-07

Your corrections are finally learned, dictionary names come out right far more often, and questions get their question marks.

### What's new

- **Learning from your corrections works:** it never kicked in before. Fix a misheard word after dictating, even a name that's already in your dictionary, and VoiceParty learns the word and what it was misheard as (even another real name, like "Steven" for Stephen, or an ordinary word, which is then fixed only where it's written as a name), so the next dictation gets it right, even when a name is misheard a different way. A message shows what it learned, with Undo, and a fix made just before pressing Enter counts too.
- **Dictionary names come out right more often:** names the speech engine didn't know are matched to your dictionary by how they sound, not only how they're spelled ("Ben Lotavi" becomes Ben Holtavi, "KVOS" kivaOS, "Grat CN" Gradcn), and a name that sounds like an ordinary word is used when it's written as a name mid-sentence ("Endeavor" becomes Andevor, while the word "endeavor" stays). In two weeks of our own dictations, dictionary names came out right 93% of the time instead of 69%, with no wrong replacements.
- **Question marks and sentence breaks:** questions the speech engine ended with a period now get a "?" ("What can we do to solve this?"); where it forgot to end a sentence ("…correct And what would you…") the break comes back ("…correct? And what would you…?"); and a stray capital mid-sentence ("to Solve this") is fixed, even when no AI cleanup runs. "D to C" and "B to B" are written D2C and B2B.
- **Narrow windows:** the main window no longer shrinks past a width where pages break (800 points); Home, Insights and Dictionary rearrange to fit narrower windows instead of squeezing, and the usage bars in Insights line up.
- **Cleaner history:** hovering a dictation shows play, copy and "…" in their own space instead of covering the text; its details (app, length, AI cleanup) are under "…".
- **Notetaker stops when the call ends:** within a few seconds instead of 20 or more, and also when you started it by hand during the call. A mute or switching headphones doesn't stop it.
- **Fixed:** a phrase could appear twice, like "you can check You can check the logs", where the speech engine joins its 15-second windows in a longer dictation or meeting transcript. Restarts like "in the in the" are written once too.

## 0.1.2 — 2026-09-28

A mode for English as a second language, fewer dropped words, meeting notes that know whose task is whose, and lower energy use.

### What's new

- **English is my second language** (new setting, off by default): every dictation goes to the smart cleanup model, which also fixes non-native grammar, like "I am agree" → "I agree" or "since two years" → "for two years". In our tests it fixed 75% of the errors in 117 non-native sentences, up from 8%. Needs Smart cleanup; about 0.2 s slower per dictation.
- **Fewer dropped words:** if the fast cleanup model leaves out part of what you said, the smart model redoes that dictation (when both are installed).
- **Meeting notes get task owners right:** your own "I'll send the deck" stays yours instead of going to whoever spoke just before. With a calendar event attached, wrong owners in our test meetings fell from 10 of 50 to 2. Notes are also a little shorter.
- **Lower energy use:** the local cleanup models no longer keep CPU cores spinning while they wait, and each dictation loads only the models it can use. A cleanup with the fast model now takes about a third of the energy.
- **Automatic model memory** (the new default for new installs): models stay loaded for up to 30 idle minutes and are freed sooner when your Mac runs low on memory, down to a minute. If you're updating, pick it under Settings → General → Model memory. "Load when I dictate" now keeps the small fast model for 30 idle minutes, and the smart one too on Macs with 32 GB or more.
- **Plain dashes** (on by default): dictation, transforms and Command Mode write a regular dash instead of an em dash, which many readers take as a sign of AI-written text. "M dash" is now written "em dash".
- **Fixed:** an email could be signed with a name you never said; a sign-off name no longer gets a period; a stutter like "the, the" left in by the cleanup model is removed.

## 0.1.1 — 2026-09-25

A more accurate speech model, faster cleanup, and fixes.

### What's new

- **More accurate speech recognition:** the optional speech download is now NVIDIA's Parakeet Unified. In our tests on real dictation it misheard fewer words (9.0% vs 10.6% for the previous Parakeet, 11.4% for Apple's engine) and uses much less memory. Get it under Enhancements. If you already have the previous Parakeet, it keeps working and you can switch in Settings. Licensed by NVIDIA Corporation under the NVIDIA Open Model License.
- **Faster cleanup:** with the fast cleanup model, typical cleanup time is about a third lower.
- **Fixed:** the fast cleanup model's memory grew with every dictation; it now stays around 0.5 GB.
- **Fixed:** an "um" could survive when the smart cleanup model left it in; a cut-off word like "a s sub agent" is cleaned up.
- **Better without AI:** spoken corrections like "move it to thursday actually no friday" now work even with no AI model.
- **Safer model loading:** speech models always load the exact pinned version.

## 0.1.0 — 2026-09-25

The first release: private dictation for macOS. Hold a key, talk, and clean text appears wherever your cursor is. Speech recognition and cleanup run on your Mac.

### What's in 0.1

- Dictation in any app: hold fn (or Right ⌥) to talk, double-tap for hands-free, Command Mode to edit selected text.
- Cleanup that keeps your words: fillers and false starts removed, corrections applied, lists, emails and code formatted; a style per kind of app.
- A dictionary that learns from your corrections, snippets, and transforms on ⌥1–9.
- Notetaker: meeting summaries, decisions and action items, written on your Mac.
- Optional downloads: NVIDIA Parakeet speech recognition and small local cleanup models (S1-mini, Qwen3) via llama.cpp, each pinned and verified.
