**Performance change report**

Branch: `feat/astra-changes`. Baseline: `c82d3a1`. Configuration files and defaults are unchanged. The recording playground and private voice-benchmark data are excluded from Git.

**Outcome**

Correction analysis is 46–53 times faster on the measured inputs and runs off the main thread. Terminal output no longer blocks audio processing or paste processing. The Live comparison did not establish a network-latency improvement. Recovery now rejects incomplete streams, preserves completed text and usage, and cancels redundant work.

**Measured before and after**

All local measurements used Apple's Swift interpreter on the same Mac. Each correction row is the median of three runs. Both versions received the same synthetic 50-word paste within a larger field. The baseline implementation came from `c82d3a1`.

| Test | Before | After | Result |
|---|---:|---:|---|
| Correction scan, 1,000-word field | 96.89 ms | 2.13 ms | 45.5 times faster |
| Correction scan, 5,000-word field | 504.38 ms | 9.57 ms | 52.7 times faster |
| Correction scan, 20,000-word field | 2,031.83 ms | 38.50 ms | 52.8 times faster |
| Producer time for 10 log writes to a controlled slow sink | 540.56 ms | 0.11 ms | Producer does not wait for output |
| Live audio-end to client settlement, median | 549.20 ms | 559.80 ms | No demonstrated improvement |

The log test inserts a 50 ms wait into each output operation. It measures the effect of synchronous versus queued output. It does not represent the normal speed of a terminal. The queued logger still performs the output work on its worker queue.

The final Live comparison used two blocks per version, three turns per block, in the order before/after/after/before. Both versions used 150 ms chunks, 700 ms synthetic silence, manual activity detection, Smart mode, `en-US,mr-IN`, and unaligned endpoint signaling. No vocabulary was supplied. The source configuration remained unchanged. The sample was generated with the macOS Samantha voice at 175 words per minute: “Please send the Kubernetes deployment report to Priya by Friday. Set the retry limit to twenty seven.”

All 12 turns returned the expected English text, including Kubernetes, Priya, and 27. All used `server_turn_complete`. Before ranged from 491.15 to 590.37 ms. After ranged from 533.58 to 596.15 ms. The after median was 10.60 ms higher. This small sample does not establish whether that difference is repeatable.

The measured interval outside the client's commit timer was a median 0.05 ms before and 0.90 ms after. The after path drains audio sends before committing. This adds a small measured local cost to protect complete-audio delivery.

The Live test bypasses microphone capture, the HUD, terminal rendering, clipboard preparation, and the target application. It cannot measure total release-to-visible-text latency. It uses synthetic English speech; it does not establish Marathi or mixed-speech accuracy.

Raw evidence: [local benchmark](astra-local-benchmark.txt), [Live results](astra-live-results.json).

**Code changes**

- Correction learning uses a worker queue and a 50 ms Accessibility request budget. It normalizes words once and maintains counts while the search window moves. Existing correction gates and first-best tie selection are retained. Work is skipped above 512 pasted words, 50,000 field words, 16,000 pasted UTF-8 bytes, or 500,000 field UTF-8 bytes. Results are discarded after a new capture or focus change.
- Logging uses a separate bounded queue. It retains up to 128 pending lines and one latest meter update. Individual log messages are limited to 8,192 characters. Normal mode avoids meter formatting and output. Shutdown waits at most 200 ms for queued logs; slow output cannot hold shutdown indefinitely. Diagnostic output can be dropped when its queue is full.
- Clipboard preparation starts during capture. The paste path uses that owned snapshot only if the clipboard change count still matches. A missing, unfinished, or stale snapshot uses the original synchronous path. Clipboard restoration remains enabled when configured.
- Audio capture opens and closes its recording gate on the processing queue. Pre-roll, live audio, trailing audio, and synthetic silence retain their order.
- Live connections and turns have identifiers. Old socket callbacks cannot update a new connection. A turn with missing or failed sends is ineligible for Live completion. Commit waits for preceding sends to complete.
- Completed text received before local commit is retained. A heuristic settlement retires its socket to prevent delayed words entering a later turn. Metered usage is captured before reconnect resets session counters.
- Healthy socket rotation is deferred during a turn. The reconnect callback rechecks connection identity and turn activity before replacing the socket.
- REST requests and retries can be cancelled. Settlement cancels losing requests, retries, fallback timers, and the total deadline. The fallback delay now uses `REST_FALLBACK_TIMEOUT` directly instead of increasing with recording duration.
- A release-relative deadline limits waiting for unsettled transcription. It does not bound a blocked capture queue, clipboard provider, or target-app rendering. Its duration is `max(10, min(30, REST_FALLBACK_TIMEOUT + 10))` seconds: 12.5 seconds with the supplied configuration, 14 seconds with the code default. The Live text-settlement timers remain separate and unchanged. An unsettled transcription fails when the deadline handler runs instead of accumulating retries indefinitely. The deadline is cancelled before paste processing.
- HUD updates retain only the latest queued value. The streaming preview uses at most 512 trailing characters. Final text, history, and pasted text remain complete.
- Duration measurements use monotonic time in the changed processing paths. Diagnostics report event-queue delay, paste dispatch, and next-turn readiness. Paste dispatch is no longer labelled as confirmed visible paste.

**Verification**

- 318 Swift regression checks passed. Coverage includes correction gates, 300 comparisons against the prior correction algorithm, blocked logging, bounded output, cancellation, transcript preservation, stale socket messages, incomplete-stream rejection, idle rotation, and usage preservation.
- 10,000 independent Python rolling-window cases passed. Deadline-bound checks passed.
- All application source declarations loaded through Apple's Swift interpreter without starting the application.
- Formatting checks passed for changed source and Swift test files. `git diff --check` passed.
- The repository-wide `make lint` still reports the pre-existing trailing-comma finding in unchanged `src/04-sound.swift`. The same line exists in the baseline. No unrelated formatting was applied there.
- The requested reviewer identified two recovery races. Both were fixed and re-reviewed. The follow-up static review reported no further actionable findings.

**Remaining validation**

Clipboard preparation has not been timed against real clipboard providers. The no-key tests do not operate the microphone or clipboard. No target-app rendering benchmark was run. Network interruption, device changes, and sleep/wake still need interactive validation.

Before daily use, run these checks on the target Mac with the existing configuration:

1. Run `make check-offline`. It must report passing mirror and Swift checks.
2. Run `./justspeak`. Dictate short and long sentences. Confirm the first and last words, paste order, and immediate readiness for the next turn.
3. Enable the existing correction-learning setting. Edit a dictated proper noun inside a long document. Confirm that the hotkey remains responsive after the learning delay.
4. Copy a large image, dictate, and confirm that the prior clipboard returns. Repeat while copying something else during capture. The newer copy must be preserved for restoration.
5. Interrupt the connection during speech. Confirm that a partial Live result is not pasted and that fallback either returns the complete turn or reports failure once.
6. Test Marathi, mixed speech, release during a word, and a microphone change. Do not reduce silence settings until these cases pass.

**Reproduction**

Local comparison:

```sh
make benchmark
```

Live comparison, with `GEMINI_API_KEY` already available in the environment and a synthetic 16 kHz mono PCM16 little-endian file:

```sh
python3 tests/live_benchmark.py --pcm /path/to/synthetic.pcm --output /tmp/live-results.json
```

The Live command uses API quota. It does not record the microphone or synthesize paste events. The script fails if the audio is empty or has no meaningful energy. It suppresses raw API errors to avoid exposing credentials.
