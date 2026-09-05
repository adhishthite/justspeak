# Microphone recovery and performance changes

Baseline: `9e13087`. Implementation branch: `feat/astra-changes`. Configuration defaults remain unchanged.

## Result

Microphone recovery now rebuilds the complete capture path and confirms fresh audio before accepting a turn. Interrupted or dropped audio invalidates the turn. Clipboard preparation cannot hold the paste path indefinitely inside a data provider. Live startup audio is buffered in order with explicit limits. The HUD avoids repeated layout work and displays startup and failure states reliably.

## Microphone behavior

- Separate requested capture from verified capture health.
- Require fresh converted audio before the listening cue and active recording state.
- Rebuild tap and converter after a configuration change or stalled capture.
- Coalesce configuration notifications over 100 ms. Use three recovery attempts; brief unstable audio does not reset the budget.
- Detect stale capture at 750 ms, checked every 250 ms while capture is requested.
- Limit queued hardware buffers to eight. Reject interrupted audio after queue overflow or conversion failure.
- Reject old-device buffers by generation. Notify the app outside locks.
- Cancel pending startup when the user releases the hotkey. Reset toggle state after failure or interruption.

The actual two-process hardware test passed. Both processes received ongoing audio from the default microphone. Forced idle configuration changes recovered; a forced mid-recording configuration change produced one interruption and an invalidated recording; capture became ready again. No microphone audio was saved, printed, transcribed, or transmitted. This does not reproduce the user's unidentified triggering application or every headset mode.

## Other engineering changes

- Live messages wait in an ordered startup queue. Pending data is limited to 256 KiB and three seconds, including in-flight data. Incomplete streams cannot settle successfully.
- End-of-turn writes must complete before settlement is allowed. Early server completion is retained until the write gate opens.
- Clipboard preparation runs in a coalesced worker. A bounded 150 ms asynchronous wait permits a late snapshot to complete. If unavailable, the old clipboard is preserved and delivery failure is shown. With history enabled, the transcript is recorded as `delivery_failed`.
- Empty clipboard restoration and consecutive-turn restoration preserve the user's original clipboard.
- Paste returns an explicit dispatch outcome. AppleScript fallback was removed. Event dispatch does not prove target-app rendering.
- Focus-screen Accessibility requests run off the main event loop.
- The HUD reveals errors even when previously hidden, cancels obsolete hide timers during startup, and acknowledges a press while the previous turn finishes.
- History stores event-queue delay, next-turn readiness, delivery outcome, and input device on successful turns. Failed transcription includes capture and elapsed timings.
- `make check` now runs offline regression checks and source lint. Hardware and HUD checks have separate targets.

## Measurements

A real AppKit benchmark compared 10,000 unchanged-layout calls, with three runs per version:

| Version | Median | Range |
| --- | ---: | ---: |
| Pushed baseline | 18.323 ms | 17.685–18.813 ms |
| Updated layout cache | 3.538 ms | 3.465–3.651 ms |

This is an 80.7% reduction in the measured function's execution time. It does not establish a frame-rate, energy, or dictation-latency improvement.

A fresh 12-trial synthetic English Live comparison used 150 ms chunks, alternating before/after/after/before blocks, and three turns per block. Baseline used 700 ms silence; the candidate used 350 ms. All trials returned the expected text through server completion. Baseline median was 530.7 ms; candidate median was 564.1 ms. The result did not confirm the earlier saved voice benchmark's gain. The default therefore remains 700 ms. These tests bypass microphone capture, post-roll, HUD, clipboard, and target-app rendering.

Raw synthetic comparison: [results](recovery-live-flush-comparison.json).

The final implementation was also checked in six new Live trials with unchanged 700 ms silence on both versions. All six returned the expected text through server completion. Baseline median was 561.6 ms; final implementation median was 564.1 ms. This small smoke test establishes no network speed improvement. Raw results: [final default-settings check](recovery-live-final-defaults.json).

## Completed checks

- `make check`: 392 Swift regression checks, 10,000 independent Python cases, and strict source lint passed.
- `python3 tests/run.py --hud`: 24 HUD checks passed. Its rendered image was inspected.
- `python3 tests/mic_hardware.py --run`: real two-process microphone sharing and recovery passed, including the final conversion-failure hardening.
- Swift test formatting, Python syntax, and `git diff --check` passed.
- Source delimiter deltas match the baseline: braces 0, parentheses -1, brackets +12.


## Validation limits

A specific app/headset reproduction, real destination-app paste confirmation, and a human-scored Marathi/mixed-language corpus remain outside the completed checks. Concurrent next-turn capture, offline recognition, and a new speech-end detector were not added: each requires separate behavior and accuracy validation. The existing post-roll policy is retained.

Reproduction commands:

```sh
make check
make check-hud
make check-mic
python3 tests/live_benchmark.py --baseline 9e13087 --pcm /path/to/synthetic.pcm --flush-ms 350 --output /tmp/live-results.json
```

The Live benchmark uses an existing `GEMINI_API_KEY` environment variable. It does not print credentials or raw API errors. The microphone check opens the default input in two processes briefly and stops both.
