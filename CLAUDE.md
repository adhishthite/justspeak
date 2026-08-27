# CLAUDE.md

JustSpeak — ultra-low-latency push-to-talk macOS dictation. Hold a hotkey, speak, release; text is transcribed via Gemini and pasted into the frontmost app. Personal tool, runs on corporate Macs governed by Google's Santa binary-authorization.

## Hard constraints (non-negotiable)

- **No compiled binary, ever.** Santa blocks unsigned binaries. The code is *interpreted* by Apple-signed `/usr/bin/swift`. Never introduce `swiftc`, SwiftPM builds, or `swift build`.
- **Zero third-party dependencies.** Apple SDK modules only. `import SQLite3`, `Carbon`, `IOKit` are fine (system frameworks); GRDB/Sauce/anything-SwiftPM is not.
- **No async/await, no actors.** Concurrency is NSLock + DispatchQueue + completion handlers, matching the existing idiom throughout.
- Comment style is sparse rationale-only. Match it; don't add doc comments that restate signatures.

## Repo layout

- `src/*.swift` — the source, split along `// MARK:` boundaries, numerically prefixed (`00-header` … `22-app`, `99-main`). **Lexical order is load-bearing**: top-level statements live only in `00-header` (setbuf) and `99-main` (entry point); declarations in between can reference each other freely because it all becomes one file.
- `./justspeak` — the runner: concatenates `src/*.swift` into `.build/justspeak.gen.swift` (gitignored), injecting `#sourceLocation(file:line:)` at each boundary so compiler errors point at real `src/` files, then `exec /usr/bin/swift` on it. `00-header.swift`'s shebang must stay line 1 (it gets no directive).
- At runtime it's ONE file, so top-level `private` (e.g. `SQLITE_TRANSIENT`) is visible across all `src/` files. Don't "fix" access control for multi-file semantics.
- `Makefile` targets route through `./justspeak`. `.env` (gitignored) holds config incl. the API key; `.env.example` documents every knob; `vocabulary.example.txt` shows vocab + replacement-rule syntax.

## Development environment reality

This repo is usually edited on a **Linux VM with no Swift toolchain**. Consequences:

- You cannot compile or run anything. Never claim a change "works" — state what static checks you ran.
- Delivery is via git: commit to a feature branch, push; the user pulls and tests on their Mac, then reports back. Do not merge to `main` without explicit instruction.
- Always give the user a concrete local test script: steps, expected behavior, and the failure signature if it's still broken.

### Static verification protocol (do this after every edit)

1. **Delimiter balance** on the generated file (or the whole `src/` concatenation), via Python `count()`: `{`/`}` must be equal; `(` vs `)` delta must be exactly **−1** (a pre-existing unmatched paren in the ASCII-art banner string); `[`/`]` delta is **+12** (bare `[` inside ANSI escape strings). Any change to these deltas means you broke something.
2. **Python mirrors** for anything algorithmic (regex behavior, DSP/dB math, poll loops, SQL bind alignment) — port the logic to Python and run real cases.
3. **Lock hygiene review**: never `print`/`Logger`/callback while holding an NSLock. Snapshot under the lock, release, then act.
4. Re-read every edited hunk in full context; grep all call sites of any changed signature.

## Architecture map (one sentence per module)

- `02-config` — `Config` struct; every knob has **two parse sites** (inline `.env` switch AND process-env overrides) — new knobs must update both, plus `.env.example` and the README table.
- `05-injector` — clipboard write (transient pasteboard types) + synthesized ⌘V; `copyOnly` for downgrades; changeCount-guarded restore after 1s; trailing space appended **after** the internal trim.
- `06-replacement-engine` — deterministic `wrong => right` post-transcription rules (ported from Jot): longest-first, lookaround boundaries, case propagation.
- `07-history-store` — SQLite at `~/.justspeak/history.db` (WAL, 0600); one row per turn (success/empty/error) incl. tokens, cost, latencies, frontmost app; all writes are fire-and-forget `queue.async` **after** the paste; schema changes need a best-effort `ALTER TABLE` migration (duplicate-column errors deliberately ignored); INSERT columns/placeholders/binds must stay aligned (currently 34).
- `08-audio-engine` — always-on AVAudioEngine with pre-roll ring buffer; per-buffer RMS while recording feeds the adaptive trailing capture in `stopRecording` (quiet-window `POST_ROLL_MS`, cap `POST_ROLL_MAX_MS`); `duration` is measured at entry (micro-click guard depends on it); input-device changes (`AVAudioEngineConfigurationChange`, main thread) rebuild tap + converter and restart only if the engine was meant to be running.
- `09-live-client` — Gemini Live WebSocket (`gemini-3.5-transcribe-live`): `setup.inputAudioTranscription` at TOP LEVEL (`{mode: SMART|VERBATIM, languageCodes, customVocabulary}`) — NOT under `generationConfig`; manual VAD (`realtimeInputConfig.automaticActivityDetection.disabled: true` + `activityStart`/`activityEnd`) is the documented push-to-talk recipe; segment accumulator survives mid-utterance pauses; cumulative `usageMetadata` diffed per turn for cost.
- `10-validation-gate` / `11-rest-client` — REST fallback (`gemini-3.5-flash-lite`, prompted): validation gate rejects model-voice output (precision-first — patterns must never reject dictations like "Sure, sounds good" or "As an AI engineer…"); 429 retry-delay honoring; one re-send on empty transcript.
- `12-hotkey` — CGEventTap on the **main run loop** (so key handlers run on main; NSWorkspace reads there are safe).
- `14-secure-input` — `IsSecureEventInputEnabled()` + IOKit holder lookup; dictation refuses at key-down, downgrades to copy-only at paste time.
- `17-hud-aura` — `strokeHalo` (crisp rim + two offset-shadow gaussian passes, Talkify's glow construction) serves both geometries: the dilated notch path and, in `pillMode`, the even-odd-clipped pill capsule; the pill panel margin in `21-hud` must exceed the halo's worst-case spread (~44px) or the fade gets a panel-edge cutoff. Design reference for notch HUD treatments: https://github.com/tornikegomareli/Talkify (SwiftUI — `HUDEdgeGlowView` has the glow recipe: crisp stroke at w/2 + two blurred copies at blur r and r/2, voice level swelling width and blur; also open-silhouette stroking that never draws the hidden top edge, and sweep/particle ideas we haven't ported).
- `21-hud` — notch-anchored pill; truncation is controlled by the attributed string's NSParagraphStyle (cell `lineBreakMode` is ignored for attributed values).
- `22-app` — `JustSpeakApp` orchestrator; see invariants below.
- `24-network-monitor` — `NWPathMonitor` singleton behind an NSLock; the key-down offline gate reads `isOnline` (optimistic until the first path update so a slow monitor never blocks a healthy network).
- `25-analyzer` — `--analyze` / `make analyze`: mines the history DB (success rows, newest-first, 300k-char payload cap) for vocab suggestions via one REST call (`responseMimeType: application/json`); suggestions are rendered in vocabulary-file syntax so the interactive append is a plain string concat `parseVocabulary` already reads; strictly user-run — never wired into the dictation path.

## Invariants that past bugs were made of

- **Settle-once turn arbiter**: `currentTurnId`/`turnSettled`/`pendingFallbackTimer` are mutated only on `sessionQueue`; `settle()` is the sole path to paste-or-error; WS and REST *race* and the first result for a live turnId wins. Never add a second path to `handleTranscribedText`.
- `isProcessing` is set in `handleKeyUp` (BEFORE the pipeline's post-roll drain), not inside `runTurnPipeline` — a re-press during the up-to-1.5s drain must be refused by the key-down guard or it clears the buffers mid-finalize. Consequently **every** pipeline exit path (micro-click guard, silent-clip gate, settle) must clear it.
- `captureActive` (main-thread-only) records whether the last key-down actually started a capture; `handleKeyUp` ignores releases without it. Blocked key-downs (secure input, offline, isProcessing) still deliver their key-up, and running the pipeline then would resurrect the PREVIOUS turn's buffer (`stopRecording` has no is-recording guard by design).
- The micro-click guard and silent-clip gate return **without** committing the WS turn — that abandoned-turn pattern is established and safe; the next `startNewTurn` resets state.
- `handleKeyDown`/`handleKeyUp` run on the main thread; `handleTranscribedText` runs on `sessionQueue`; nothing may call `sessionQueue.sync` from main (a tiny `DispatchQueue.main.sync` from sessionQueue for the frontmost-app read relies on this).
- History/latency/HUD always show the clean transcript; only the pasted payload gets the trailing space.
- Never store estimated token counts in the DB — raw API values or NULL, plus `tokens_metered`.

## Gemini API facts (as of Aug 2026 — verify against docs, not memory)

- `gemini-3.5-transcribe-live` launched 2026-08-26; generic Live-API docs may lag it — consult the live-transcribe page specifically.
- Language codes are region-qualified BCP-47 from the docs table (`en-IN`, `mr-IN`, `pa-Guru-IN`); `Config.normalizeLanguageCode` canonicalizes casing. Defaults: `en-IN,mr-IN`.
- Auth via `x-goog-api-key` header, not URL query.
- Pricing knobs in config (per 1M tokens): live $3.50 in / $21.00 out; flash-lite $0.30 / $2.50; ~25 audio tokens/sec.

## Workflow with the user

- Feature work: branch from `main`, commit per feature (small, behavioral messages), push; user pulls, live-tests on their Mac, reports back. PRs/merges only when asked.
- Larger implementations may be delegated to cheaper subagents with precise specs, but **you verify everything yourself** before committing (the specs and verification protocol above).
- The user's `.env` is sacred and gitignored; never commit it, never print the API key.
