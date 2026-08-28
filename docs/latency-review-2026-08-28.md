# Review of the Gemini Latency Report

Date: 2026-08-28
Scope: checks each of the six proposed optimizations (OPT-1 … OPT-6) against the
actual source in `src/`. The 193-turn numbers come from the user's local history DB
and could not be re-run here; only their internal consistency was checked.
Status: findings only; no code changed.

## Short version

- The baseline breakdown is roughly right, but the **projected 883 ms → 220–280 ms is
  not achievable**. The report's own data caps the gain: the fastest WS roundtrip ever
  recorded was 410 ms, and 160 ms of that is client-side grace, so network + server
  never went below ~250 ms. A realistic p50 target is **~450–550 ms (35–45% faster)**,
  not 70%.
- Only **one** proposal (OPT-2, adaptive post-roll) is both verified in code and worth
  a code change. It is also the largest real win.
- **OPT-1** (silence flush) is worth an A/B test via `.env`, but its claimed gain is a
  guess: nothing in the DB separates "server ingesting silence" from "server thinking".
- **OPT-3** (settle grace) may yield zero. It only applies to turns that settled via
  `final_grace`; turns settled by the server's echoed `turnComplete` never touch that
  timer. Query `settle_path` before deciding.
- **OPT-4** misdiagnoses the tail. The 4.7 s outliers match the REST hedge timer, which
  can never fire before 3.0 s (`max(2.5, min(8, dur*0.4+3))`), plus a ~1.3 s REST call.
  A ping helps a half-open socket, but the timer floor is the actual cliff.
- **OPT-5 and OPT-6** are not worth doing. OPT-6 is based on a wrong premise: the
  pending chunk buffer is flushed at key-up regardless of `CHUNK_MS`, so chunk size adds
  no queueing delay at release.

## Where the 883 ms actually goes (verified against code)

| Phase | p50 | What the code does |
|---|---|---|
| Capture finalize | 290 ms | `stopRecording` waits `POST_ROLL_MS` = 250 ms of continuous quiet, polled every 25 ms, **with a floor of 250 ms since entry even if the room was already quiet** (`08-audio-engine.swift:537`, the `elapsedSinceEntry >= graceSec` clause). Then `audioProcessingQueue.sync {}` and the 22.4 KB silence append. 250 + one 25 ms poll + ~15 ms drain ≈ 290. The minimum of 283 confirms the floor. |
| WS roundtrip | 556 ms | Measured from commit dispatch to the WS completion callback. Includes: sending `audioStreamEnd` + `activityEnd` + `turnComplete`, server processing of the tail (which includes the 700 ms synthetic silence sent just before), then either the echoed `turnComplete` (settles immediately) or `settleFinalGrace` 150 ms + 10 ms cushion. The report's split (300 ms silence / 160 ms grace / 95 ms network) is **invented** — no instrumentation distinguishes these. |
| Inject | 13 ms | 10 ms is the hard-coded `usleep(10_000)` between ⌘V down and up (`05-injector.swift:82`). |
| Remainder | 1 ms | Queue hops. The 2.3 s p99 outlier is almost certainly the REST empty-transcript retry: `restStartTime` is reset on the retry (`22-app.swift:715`), so the first attempt's time lands in "remainder". Not a dispatch problem. |

Speech length barely matters (r = 0.17) because the server transcribes during the hold.
That part of the report is correct and is why the remaining latency is all "after key-up"
overhead.

## Verdict per proposal

### OPT-2 — Adaptive zero-wait post-roll. **Do it. Largest real win.**

Claim: skip the 250 ms wait when audio was already quiet before release.
Code check: correct diagnosis. The loop only starts counting quiet *after* key-up and
additionally enforces `elapsedSinceEntry >= graceSec`, so a user who finished speaking
and then released the key still pays the full 250 ms + 25 ms poll.

Fix shape (about 15 lines in `08-audio-engine.swift`): track `lastSpeechTime` under
`lock` in the per-buffer RMS path (`lastLevelDb` is already updated there), seed
`quietStart` from it at `stopRecording` entry, and drop the `elapsedSinceEntry >= graceSec`
floor. The `maxTrailMs` cap and the "still speaking" branch stay untouched, so releases
mid-word still get the adaptive trail.

Expected gain: up to −250 ms on already-quiet releases. Given p75 = 302 ms, at least
three quarters of turns are in this bucket. **p50 estimate: 883 → ~650 ms (−25%).**
Risk: soft trailing consonants ("s", "th") can sit below `TRAIL_SILENCE_DB` (−40 dB) and
be treated as quiet; a small floor (50–80 ms) is a cheap hedge. Validate by ear on words
ending in fricatives, and via `capture_finalize_ms` in the DB.

### OPT-1 — `SILENCE_FLUSH_MS` 700 → 250. **A/B test it; do not assume the number.**

Claim: the server spends 300–450 ms ingesting 22.4 KB of zeros.
Code check: the flush is sent as one WS frame right before `activityEnd`. It does not
sleep on the client. Whether the server takes 30 ms or 300 ms to run 700 ms of silence
through the encoder is unknown; a streaming encoder is usually well faster than
real-time. Under manual VAD, `activityEnd` already tells the server speech has ended, so
the flush may be partly redundant — or it may be what saves the last word. Nobody has
measured it.

How to test: the DB already stores `silence_flush_ms` per row. Run ~30 turns each at
700 / 300 / 0 and compare `roundtrip_ms` and last-word accuracy (names, numbers, words
ending in plosives). Expected gain: **0 to −200 ms, unknown until measured.**
Risk: last-word truncation if too short. Zero code change.

### OPT-3 — `settleFinalGrace` 150 → 40 ms. **Only if `settle_path` says so. Prefer 80 ms.**

Claim: −110 ms, "single constant".
Code check: the constant is real (`09-live-client.swift:82`) but it only governs turns
that settle via the `final_grace` rule. The legacy (non-aligned, default) endpoint also
sends `clientContent.turnComplete`, and when the server echoes it the turn settles
immediately (`settle_path = "server_turn_complete"`) — the grace timer never fires. If
most rows show `server_turn_complete`, this change does nothing.

The grace exists so a second segment's final (after a mid-dictation pause) is not
dropped. 40 ms is aggressive for a network-delivered second message; 80 ms is a safer
first step.

Expected gain: **0 to −70 ms depending on `settle_path` mix.** Query first:

```sql
SELECT settle_path, COUNT(*), ROUND(AVG(roundtrip_ms)) FROM transcriptions
WHERE status='success' GROUP BY 1;
```

### OPT-4 — WebSocket ping keep-alive. **Wrong root cause; fix the hedge timer instead.**

Claim: NAT idle drops cause 4.7 s turns; a 30 s ping removes them.
Code check: no ping exists, so the idea is not harmful. But the arithmetic points
elsewhere. The REST hedge fires at `max(REST_FALLBACK_TIMEOUT, min(8, dur*0.4+3))`,
which is **≥ 3.0 s regardless of config** — the `.env` value of 2.5 can never take
effect (the Codex audit noted the same). 3.0 s hedge + ~0.3 s capture + ~1.3 s REST ≈
4.6 s, matching the p99 of 4.67 s. A dead-but-connected socket therefore always costs
~4.7 s.

Better fix: make the hedge honor `REST_FALLBACK_TIMEOUT` as an actual ceiling (or at
least start it from ~1.5 s when no post-commit token has arrived), and fail the WS route
fast when the `activityEnd` send errors (its error is currently ignored:
`{ _ in }`). A ping is a fine addition after that. Check `fallback_reason` to see which
failure mode the outliers actually were.

Expected gain: affects ~2% of turns; −2 to −3 s on those. **p50: 0.** p99: large.

### OPT-5 — ⌘V hold 10 ms → 1 ms. **Skip.**

Real but worth 9 ms (1%). Below perception. An intermittent dropped paste in a slow
Electron app would cost more than it saves. If touched at all, try 3–5 ms, not 1.

### OPT-6 — `CHUNK_MS` 150 → 100. **Skip; premise is wrong.**

Claim: reduces audio queued at key release by 33%.
Code check: `stopRecording` flushes whatever is in `pendingChunkBuffer` immediately
(`trailingChunk`, step 4), so at key-up nothing is "queued" regardless of chunk size.
Chunk size only changes how far behind the interim display runs mid-utterance, which
the final does not depend on. Expected end-to-end gain: **~0 ms**, plus 50% more WS
frames.

### DISC-1 / DISC-2 (Opus, speculative typing) — correctly rejected.

## Realistic projection

| Step | p50 after | Cumulative |
|---|---|---|
| Baseline | 883 ms | — |
| OPT-2 adaptive post-roll | ~650 ms | −26% |
| OPT-1 if the flush turns out to cost ~100 ms | ~550 ms | −38% |
| OPT-3 if `final_grace` dominates (80 ms) | ~480 ms | −45% |

Floor: the observed minimum network + server time is ~250 ms, plus ~40 ms capture drain
and ~13 ms inject. Anything under ~350 ms p50 is not reachable by client-side changes.
The 220–280 ms figure in the report is below the fastest turn ever recorded.

## Recommended order

1. Run the two SQL queries (`settle_path`, `fallback_reason`) — 2 minutes, decides
   OPT-3 and OPT-4.
2. Implement OPT-2 (one branch, Python-verified poll loop, DB-verifiable).
3. A/B `SILENCE_FLUSH_MS` 700 / 300 / 0 over a day of normal use; keep whichever does
   not lose last words.
4. Fix the hedge timer floor; optionally add a ping.
5. Revisit `settleFinalGrace` only with data from step 1.

Everything above the line is measurable with columns already in `history.db`; no new
instrumentation is needed.
