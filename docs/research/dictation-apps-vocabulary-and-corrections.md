# How dictation apps learn vocabulary and capture corrections

Research date: 2026-08-27. No existing `docs/` convention was found in this repo (only `README.md`/`CLAUDE.md` at root), so this note lives at `docs/research/dictation-apps-vocabulary-and-corrections.md`.

Scope: does the app support custom vocabulary, how is it fed to the model, does it have deterministic text-replacement rules, and — the key question — does it observe what the user *types* in the target app after paste and learn from it. Marked **unverified** where a claim could only be traced to a secondary source (review/blog) and not to the app's own docs, changelog, or code.

---

## Superwhisper (closed source)

Docs: [superwhisper.com/docs](https://superwhisper.com/docs)

1. **Custom vocabulary**: "Vocabulary" words are sent alongside the audio as "custom recognition hints during the transcription process" — i.e. prompt bias at the ASR stage, not post-processing. Docs explicitly warn that too many vocabulary words "can confuse the AI transcription model," so they recommend keeping the list short and pushing the rest into Replacements. Source: [Vocabulary docs](https://superwhisper.com/docs/get-started/interface-vocabulary).
2. **Text replacements**: separate from vocabulary, applied "at the post-transcription stage," described as deterministic ("performed programmatically and does not rely on AI interpretation"). Matching is case-insensitive ("todo" matches "ToDo"/"TODO"/"Todo") and whole-word only ("Cat"→"Dog" does not touch "Caterpillar"); output casing follows what the user typed in the replacement's "to" field. No regex support is documented. Source: same [Vocabulary docs](https://superwhisper.com/docs/get-started/interface-vocabulary).
3. **Correction capture (typed, post-paste)**: **not found** in official docs. Superwhisper does read the active input field via the macOS Accessibility API, but only as *ambient context* fed to the AI-enhancement step of "Super Mode" — captured once, "after voice processing is complete, between the transcription and AI processing steps," i.e. before/at paste time, not a read-back of user edits afterward. Source: [Context Awareness docs](https://superwhisper.com/docs/common-issues/context). This is a distinct mechanism from correction learning and should not be conflated with it.
4. **History mining / auto-suggestion**: **not an official Superwhisper feature.** A third-party open-source CLI, [verygoodplugins/superwhisper-trainer](https://github.com/verygoodplugins/superwhisper-trainer), reads Superwhisper's local recording history at `~/Documents/superwhisper/recordings/`, mines saved transcripts (not audio) for frequent/fuzzy-matched terms, and writes a reviewable YAML config the user must manually apply — "miners only knows your transcripts. You know your stack." It is local-only (no LLM call, no upload). This is unofficial tooling built on top of Superwhisper's data, not a shipped feature. Source: [superwhisper-trainer README](https://github.com/verygoodplugins/superwhisper-trainer).
5. **AI post-processing**: built around "Modes" — each Mode bundles a hotkey, ASR model/language, an optional LLM post-processing step, vocabulary/replacement lists, and app-based auto-activation rules. Built-in modes (Voice to Text, Message, Email, Note, Meeting, Super Mode) ship with tuned system prompts; Custom Mode's instruction field is empty by default and the docs warn that "if left blank, AI will not know what task to perform." Source: [Modes / Custom docs](https://superwhisper.com/docs/modes/custom).

---

## Wispr Flow (closed source) — the one app that does this

Docs: [docs.wisprflow.ai](https://docs.wisprflow.ai)

1. **Custom vocabulary**: manual entries via Dictionary → Add new (desktop/iOS/Android). Desktop dictionary entries take precedence over team-dictionary entries on conflict, and entries can be starred for "higher priority during dictation." Mechanism (prompt bias vs. post-processing) is not specified in the docs. Source: [Teach Flow your words with the dictionary](https://docs.wisprflow.ai/articles/4052411709-teach-flow-your-words-with-the-dictionary).
2. **Text replacements**: dictionary entries function as replacements/snippets (bulk import supported); no regex documented. Source: [Bulk import for dictionary and snippets](https://docs.wisprflow.ai/articles/8955301725-how-do-i-bulk-import-for-dictionary-and-snippets).
3. **Correction capture — confirmed, documented, desktop-only**: this is the one official, first-party implementation of exactly the mechanism this research is asking about. Quoting the docs verbatim:
   - Trigger: *"On desktop, Flow adds words and short phrases to your dictionary as you correct dictated text."*
   - Scope of what's captured: *"Phrases of up to four words, up to four per edit — proper nouns, product and project names, acronyms, and technical terms."*
   - Explicit exclusions: *"Ordinary wording, grammar or style fixes, capitalization-only changes, filler words, and generic phrases are not saved."* Also excluded: *"Pure insertions, pure deletions, and blank edits; anything already in your dictionary or previously deleted."*
   - User visibility/control: *"A notification appears when Flow auto-learns an entry; undo the whole batch from that notification."*
   - iOS and Android do **not** support this — desktop only.
   Source: [Teach Flow your words with the dictionary](https://docs.wisprflow.ai/articles/4052411709-teach-flow-your-words-with-the-dictionary).
   Note: this is described as watching the user's typed edit to the dictated text (i.e., correcting the app's own text box / the pasted result), which matches "typed corrections in the target app after paste." The docs do not disclose the underlying detection technique (Accessibility API read-back vs. an in-app edit buffer) — treat "how" as unverified, "that it happens and what it captures" as verified from primary docs.
   Separately, Flow also does *inline* correction during dictation itself (mid-utterance "actually," "scratch that") via "Smart Formatting & Backtrack" — a different, same-turn mechanism, not post-paste learning. Source: [Smart Formatting & Backtrack](https://docs.wisprflow.ai/articles/5373093536-how-do-i-use-smart-formatting-and-backtrack).
4. **History mining / auto-suggestion**: not documented as a separate batch/scheduled process; learning is described as continuous and per-edit (see above), surfaced with a ✨ marker on AI-suggested dictionary words. **Unverified** whether there's any batch reprocessing of transcript history.
5. **AI post-processing**: Smart Formatting rewrites dictation using "your full dictation as context," including handling verbal backtracking — but no prompt template is published.

---

## VoiceInk (open source — Beingpax/VoiceInk, macOS, Swift)

Repo: [github.com/Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk)

1. **Custom vocabulary — two independent paths**:
   - `VoiceInk/Services/CustomVocabularyService.swift` just formats stored words into a string ("Important Vocabulary: word1, word2, ...").
   - This string is consumed by the AI-enhancement LLM prompt (`VoiceInk/Services/AIEnhancement/AIEnhancementService.swift`), which instructs the model: *"Use these custom vocabulary words... When the text clearly refers to one of these entries, replace similar-sounding [transcription] mistakes."* — i.e. vocabulary correction happens as an LLM post-processing instruction, not (per the code read) injected into the Whisper prompt itself.
   - `VoiceInk/Transcription/Whisper/WhisperPrompt.swift` builds the actual Whisper `initial_prompt` from a **per-language static greeting sentence** (e.g. English: "Hello, how are you doing? Nice to meet you.") to bias punctuation/formatting/language detection — this prompt path does **not** incorporate the user's vocabulary/dictionary words at all, contrary to what the marketing copy on tryvoiceink.com implies ("gives the transcription and enhancement models the vocabulary that matters to you"). Verified by reading both files directly; only the enhancement path actually receives the vocabulary list.
2. **Text replacements — "Smart Replace"**: `VoiceInk/Transcription/Processing/WordReplacementService.swift` implements deterministic post-transcription replacement:
   - Regex-based for spaced languages, with word-boundary lookarounds (`(?<!\w)pattern(?!\w)`); falls back to plain substring matching for unspaced scripts (CJK, Thai) since word-boundary regex doesn't apply there.
   - Case-insensitive matching throughout (`.caseInsensitive`).
   - **Longest-first ordering**: both across replacement rules and among comma-separated variants within one rule, so more specific triggers match before shorter overlapping ones.
   - **Many-to-one supported**: one replacement rule can list multiple comma-separated source variants mapping to a single output string.
   - A live feature request ([issue #676](https://github.com/Beingpax/VoiceInk/issues/676)) asks for a faster UI to add these and reports the one-to-one-per-entry limitation was already solved by the comma-separated-variants mechanism above (confirmed by reading the source rather than the issue thread, which doesn't itself explain the current implementation).
3. **Correction capture (typed, post-paste)**: **no such mechanism exists in the codebase.** VoiceInk does use the Accessibility API and `NSWorkspace`, but only to (a) identify the frontmost app and extract the browser URL for context, and (b) synthesize keystrokes to *insert* text — there is no code path that re-reads the target field after paste to diff it against what was inserted.
4. **History mining / auto-suggestion**: **none.** VoiceInk's history "Analyze" feature (docs: [Transcription History](https://tryvoiceink.com/docs/transcription-history)) is confirmed to be performance diagnostics only — "Opens performance analysis for the selected transcriptions," covering transcription/enhancement timing, audio duration, and system specs, explicitly "for comparing model speed or diagnosing slow output." It is not vocabulary mining. (Caution: an earlier web-search summary hallucinated a `PhoneticHintMiningService.swift`; this file does not exist anywhere in the repo's file tree — confirmed by pulling the full `git/trees` listing directly from the GitHub API and grepping it.)
5. **AI post-processing**: `AIEnhancementService.swift` routes transcripts through a user-selected provider (Gemini, Anthropic, Ollama, etc.) using a stored `CustomPrompt`, composed with: the custom-vocabulary block described above, plus optional context blocks (selected text, clipboard, screen-capture OCR) wrapped in XML-ish tags. Prompts are fully user-editable ("Smart Modes" let users switch prompt sets per use case); no single canonical prompt string is baked in.

---

## Whispering / Epicenter (open source — EpicenterHQ/epicenter, `apps/whispering`, Svelte 5 + Tauri)

Repo: [github.com/EpicenterHQ/epicenter](https://github.com/EpicenterHQ/epicenter) (formerly `braden-w/whispering`)

1. **Custom vocabulary**: no persistent "dictionary" entity in the source tree (`apps/whispering/src/lib/services/transcription/` has no vocabulary/dictionary file). Instead, each transcription provider declares a `supportsPrompt: boolean` capability (`providers.ts`), and the UI exposes a free-text **initial prompt** per transcription request — the release notes describe this as the vocabulary mechanism: *"You can now provide an initial prompt to guide transcription for more models... helps with domain-specific vocabulary, proper nouns, or formatting preferences,"* available for Whisper C++ and cloud services that support it. Source: [Release v7.11.0](https://github.com/EpicenterHQ/epicenter/releases/tag/v7.11.0). This is standard Whisper `initial_prompt` conditioning, not a persisted word list.
2. **Text replacements**: exposed as one step type inside "Transformations" (see below) — a find-and-replace step alongside LLM-prompt steps, chainable, config stored locally. No further detail (regex support, case handling) is published; **unverified** beyond "find-and-replace exists as a step type."
3. **Correction capture (typed, post-paste)**: **no evidence found** in the source tree (`services/`, `settings/`) or release notes. Nothing resembling an Accessibility-API read-back or clipboard diff turned up.
4. **History mining / auto-suggestion**: **none found.**
5. **AI post-processing**: "Transformations" — user-defined pipelines chaining multiple steps (LLM prompt calls to OpenAI/Anthropic/Gemini/Groq, or deterministic find-and-replace) applied to a transcript after ASR. Source: release notes/search results at [EpicenterHQ/epicenter](https://github.com/EpicenterHQ/epicenter); exact schema file was not locatable via the GitHub contents API in this pass — cite as **unverified in detail**, confirmed only that the feature exists and is described this way in the project's own release notes.

---

## MacWhisper (closed source)

Docs: [docs.macwhisper.com](https://docs.macwhisper.com)

1. **Custom vocabulary**: not distinct from replacements in the docs reviewed — MacWhisper's primary customization surface is Find & Replace (below). **Unverified** whether a separate ASR-time vocabulary/prompt-bias field exists beyond this.
2. **Text replacements — "Global Replace"**: deterministic, not regex-capable, literal string substitution applied to "all new transcriptions." Options: **Case Sensitive** toggle (off by default, so "You" and "you" match) and **"Only Replace Separate Words"** toggle (whole-word vs. substring). Rules are importable/exportable as JSON. Source: [Find And Replace in Transcriptions](https://docs.macwhisper.com/article/37-find-and-replace-in-transcriptions).
3. **Correction capture (typed, post-paste)**: **not documented.** No mention of any read-back of user edits.
4. **History mining / auto-suggestion**: **not found** in docs reviewed.
5. **AI post-processing**: "Dictation Prompts" — user-supplied ChatGPT-style prompts run over dictated text (documented use cases: cleanup of spelling/grammar, translation, tone changes/expansion). **App Specific Dictation Prompts** let a different prompt auto-select based on the frontmost app. Requires the user's own API key and a Pro license. Sources: [How to use the Dictation feature](https://docs.macwhisper.com/article/14-how-to-use-the-dictation-feature), [App Specific Dictation Prompts](https://docs.macwhisper.com/article/31-app-specific-dictation-prompts).

---

## Other open-source Whisper-based tools

### Handy (open source — cjpais/Handy, Tauri/Rust)
Repo: [github.com/cjpais/handy](https://github.com/cjpais/handy)
- **Custom vocabulary**: `CustomWords.tsx` stores a flat `custom_words` list via `getSetting`/`updateSetting`; consuming logic (prompt injection vs. post-hoc fuzzy correction) lives outside the reviewed UI file, but a companion debug setting, `word_correction_threshold` (`WordCorrectionThreshold.tsx`, range 0–1, default **0.18**), together with GitHub discussion of "n-gram matching for multi-word custom word correction" ([#360](https://github.com/cjpais/Handy/discussions/360)), indicates Handy fuzzy-matches ASR output against the custom-word list *after* transcription (needed because Handy's Parakeet backend has no vocabulary-biasing API at all) rather than biasing the decoder.
- **Text replacements**: the custom-words/fuzzy-correction mechanism above serves this role; no evidence of a separate regex replace feature.
- **Correction capture (typed, post-paste)**: **not found** in the reviewed files (`AccessibilityPermissions.tsx`/`AccessibilityOnboarding.tsx` are for grant-the-permission onboarding, not correction observation).
- **AI post-processing**: optional, separately configurable — `PostProcessingSettings.tsx`/`PostProcessingSettingsPrompts.tsx` let the user pick a provider (including on-device Apple Intelligence) and define custom prompts; no hardcoded default prompt ships in these files.

### WhimprFlow (open source, proof-of-concept — Blueturboguy07/WhimprFlow) — a second real implementation of post-paste correction learning
Repo: [github.com/Blueturboguy07/WhimprFlow](https://github.com/Blueturboguy07/WhimprFlow)
This is a small, unreleased personal project, not a shipped product — but its code is the clearest concrete example available of exactly the mechanism this research asked about, so it's worth citing in detail:
- `src-tauri/src/autolearn.rs` implements a **post-paste Accessibility observer** (macOS only, gated on `is_trusted()` Accessibility permission and the pasted text having ≥2 words):
  1. On paste, `watch_correction(inserted: &str)` grabs the focused element via `AXUIElementCreateSystemWide()` → `AXUIElementCopyAttributeValue(..., "AXFocusedUIElement")`, wraps the raw pointer in a `Send`-able struct, and hands it to a background thread.
  2. After a fixed `OBSERVE_DELAY` (7 seconds), it re-reads the field's `"AXValue"` attribute and diffs it against the originally-inserted text via `detect_correction(&inserted, &after)`.
  3. Filters for a **one-word correction**: exactly one word removed and one added (tokenized alphanumeric), both ≥3 characters and alphabetic, case-sensitive difference (not merely a case fix), the added word not in a ~50-word stoplist ("the," "their," "there," ...), the added word capitalized (proper-noun heuristic), and normalized Levenshtein distance between the two words in (0, 0.6] (phonetically/typographically close).
  4. If all gates pass, calls `dictionary_learn(correct, vec![mishear])`, storing the ASR mishearing as an alternate spelling for the corrected word.
- The repo also documents its own design process in `docs/research/gap-auto-learned-dictionary.md`, which explicitly cross-references Handy (fuzzy post-hoc correction, no ASR vocabulary API), VoiceInk ("two parallel correction paths" — soft LLM-context injection plus a hard deterministic regex path), and Wispr Flow's philosophy of personalization as "an on-device policy" applied at cleanup time. Its own design choice: don't do continuous AX polling ("thrashes the AX tree"); instead snapshot-on-paste and re-diff either on the next dictation into the same field or on a focus/app-change event. It also proposes gating learned words by corpus word-frequency (Zipf scale ≥3.0 rejected as "too common") and injecting only phonetically-plausible dictionary entries (Double Metaphone) into the cleanup-LLM prompt as "spelling authority" rather than as hard find/replace, to avoid dictionary poisoning.
  This document is a third-party synthesis of the other apps, not independent confirmation of their internals — treat its claims about Handy/VoiceInk/Wispr as corroborating (matches what was independently verified above), not as a new primary source.

### OpenWhispr (open source — OpenWhispr/openwhispr, Electron)
Repo: [github.com/OpenWhispr/openwhispr](https://github.com/OpenWhispr/openwhispr)
- **Custom vocabulary**: dictionary words are injected as prompt context to the transcription model per the changelog: *"Your dictionary reaches the assistant. Custom-dictionary words are injected into every assistant conversation, so replies come back using your names and jargon"* (v1.9.0, 2026-08-24). A separate "Snippets" feature does spoken trigger-word → replacement expansion before paste.
- **Correction capture (typed, post-paste) — confirmed real feature, third open-source example**: the CHANGELOG shows an "Auto-learn" toggle present since at least v1.7.6 (double-init bug fix: *"Auto-learn no longer double-initializes at launch"*), and search results describe the mechanism as accessibility-tree-based: *"apps that expose their accessibility tree keep auto-learn working as before, and apps that don't simply skip correction learning for that paste."* Source: [CHANGELOG.md](https://github.com/OpenWhispr/openwhispr/blob/main/CHANGELOG.md); mechanism description is from search-indexed release notes, not a file I could pull directly in this pass — **flagged as needing direct source confirmation** (the specific implementation file was not located in this session).
- **History**: dictionary syncs cross-device with last-writer-wins conflict resolution; no evidence of scheduled/batch history mining, only continuous per-paste learning.

### Speechify Voice Typing (closed source) — mentioned for completeness
- Speechify's own marketing copy claims the same pattern as Wispr Flow: *"Speechify will notice when you correct a dictated word and offer to learn it automatically."* Source: [speechify.com/voice-typing-dictation](https://speechify.com/voice-typing-dictation/). No docs page with implementation detail was found; **unverified** beyond this marketing claim, included only because it's a fourth independent claim of the same feature shape.

### whisper-writer (open source — savbell/whisper-writer)
Repo: [github.com/savbell/whisper-writer](https://github.com/savbell/whisper-writer)
- Config-driven wrapper around OpenAI Whisper / faster-whisper. Supports a plain `initial_prompt` string (default `null`) passed straight through to Whisper's own prompting mechanism per [OpenAI's prompting guide](https://platform.openai.com/docs/guides/speech-to-text/prompting) — no dedicated vocabulary UI, no replacement rules, no correction capture. This is the minimal baseline case: raw `initial_prompt` exposure and nothing else.

### Talon (voice control, adjacent — not Whisper-based, included for contrast)
- Vocabulary is managed as static config files the user edits by hand (`.talon-list`/CSV files under a `settings` directory), mapping "what you say" to "what gets typed" (e.g., "no js" → "Node.js"). Community package: [talonhub/community](https://github.com/talonhub/community). This is command-grammar customization, not ASR dictation correction, and there is no runtime correction-capture loop — vocabulary only changes when the user edits the list files directly.

---

## Cross-app synthesis

### Patterns that exist in the wild
- **Two-tier vocabulary architecture is close to universal**: an ASR-time bias mechanism (Whisper `initial_prompt`, Superwhisper's "vocabulary hints," OpenWhispr's prompt injection) *plus* a separate deterministic post-transcription replacement/find-and-replace layer (Superwhisper Replacements, MacWhisper Global Replace, VoiceInk Word Replacement, Whispering's find-and-replace transformation step). The two layers exist because a handful of biasing words help the decoder, but a large or highly specific correction list is better enforced deterministically after the fact — Superwhisper's docs say this explicitly.
- **Case-insensitive, whole-word matching is the de facto standard** for the deterministic replacement layer (Superwhisper, MacWhisper both document this explicitly; VoiceInk's regex enforces word boundaries and defaults case-insensitive).
- **LLM-mediated "soft" correction using a vocabulary list as context** is a second common pattern, distinct from hard find/replace: VoiceInk's AI Enhancement and MacWhisper's Dictation Prompts both let an LLM use the user's vocabulary/dictionary as a hint to fix "similar-sounding mistakes," rather than doing exact-string substitution. This is more tolerant of the ASR getting a word wrong in an unpredictable way, at the cost of being non-deterministic.
- **Post-paste correction learning via the Accessibility API is real, but rare and macOS/desktop-specific.** Confirmed independently in three places: Wispr Flow (official docs, desktop-only, explicit inclusion/exclusion rules, undo-by-notification), WhimprFlow (open-source code: AX read-back + word-diff + phonetic-distance + capitalization/stoplist gating, all locally in `autolearn.rs`), and OpenWhispr (changelog-documented "Auto-learn" toggle explicitly said to depend on the target app exposing an accessibility tree). Speechify claims the same in marketing copy (unverified in detail). All four that claim this feature gate it heavily (word-count limits, proper-noun/capitalization heuristics, frequency/stoplist filters, user-visible undo) — nobody ships an unconstrained "diff everything the user types" loop, because the false-positive risk (learning a typo, a stylistic edit, or a deletion as if it were an ASR correction) is treated as the dominant design risk across all of them.
- **History mining for vocabulary suggestion is a manual, offline, opt-in action, never automatic/scheduled**, everywhere it exists: Superwhisper's version is a third-party CLI reading local files and requiring manual review of a generated YAML before anything is applied; no first-party app in this survey runs a background/scheduled job that mines history and silently updates vocabulary. (This matches JustSpeak's own `--analyze` design in `src/25-analyzer.swift` — user-run, one REST call, never wired into the live dictation path per `CLAUDE.md`.)

### What nobody does
- **No app combines live post-paste correction detection with automatic silent application** — every implementation that does correction-learning inserts a human checkpoint: Wispr Flow shows a notification with one-shot undo; WhimprFlow's own design doc explicitly rejects "single-shot learning… risk of dictionary poisoning" as a tradeoff to be managed, not ignored, and proposes injecting learned words only as LLM context ("spelling authority") rather than as hard rules specifically to avoid a bad auto-learned entry corrupting future output silently and permanently.
- **No app treats accessibility-based correction-reading as safe by default across all target apps.** Every implementation is either macOS-only (Wispr Flow desktop, WhimprFlow) or explicitly degrades when the frontmost app doesn't expose an accessibility tree (OpenWhispr skips learning for that paste entirely rather than falling back to something riskier like raw keystroke monitoring or clipboard polling of arbitrary apps).
- **Nobody publishes the exact correction-diff algorithm except WhimprFlow** (open source, one-word-correction + Levenshtein + capitalization + stoplist) — Wispr Flow's docs describe *behavior and guardrails* ("up to four words," "not saved: capitalization-only changes...") but not the underlying detection technique (AX read-back vs. something else), so the mechanism itself is closed even though the product behavior is well documented.
- **No survey app does scheduled/background history mining that writes vocabulary automatically without a review step** — the closest thing (superwhisper-trainer) is unofficial, local-only, and explicitly requires the user to review a generated config before applying it.
