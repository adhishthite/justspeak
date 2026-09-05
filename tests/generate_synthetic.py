#!/usr/bin/env python3
"""Generate synthetic benchmark audio. Never print credentials or raw API errors."""
import argparse
import base64
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
import math
import os
from pathlib import Path
import re
import struct
import subprocess
import time
import urllib.error
import urllib.request
import wave

parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--model', default='gemini-3.1-flash-tts-preview')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
samples = json.loads((root / 'tests/synthetic-corpus.json').read_text())
key = os.environ.get('GEMINI_API_KEY')
assert key, 'GEMINI_API_KEY is missing from the environment'
args.output.mkdir(parents=True, exist_ok=True)

def generate(sample):
    target = args.output / sample['id']
    metadata = target.with_suffix('.json')
    if metadata.exists():
        return json.loads(metadata.read_text())
    prompt = f"Read only the following text exactly as written. Do not add introductions or explanations. Delivery: {sample['style']}.\n\n{sample['text']}"
    payload = {
        'contents': [{'parts': [{'text': prompt}]}],
        'generationConfig': {'responseModalities': ['AUDIO'], 'speechConfig': {'voiceConfig': {'prebuiltVoiceConfig': {'voiceName': sample['voice']}}}},
    }
    request = urllib.request.Request(f'https://generativelanguage.googleapis.com/v1beta/models/{args.model}:generateContent', data=json.dumps(payload).encode(), headers={'x-goog-api-key': key, 'Content-Type': 'application/json'})
    started = time.monotonic()
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                body = json.load(response)
            break
        except urllib.error.HTTPError as error:
            if error.code in [429, 500, 502, 503, 504] and attempt < 2:
                hint = error.headers.get('Retry-After', '2')
                delay = float(hint) if hint.replace('.', '', 1).isdigit() else 2
                if delay > 60:
                    raise RuntimeError(f'TTS HTTP {error.code}; retry delay exceeds run budget') from None
                time.sleep(max(1, delay))
            else:
                raise RuntimeError(f'TTS HTTP {error.code}') from None
        except urllib.error.URLError:
            raise RuntimeError('TTS network failure') from None
    parts = body.get('candidates', [{}])[0].get('content', {}).get('parts', [])
    audio_parts = [p['inlineData'] for p in parts if 'inlineData' in p and p['inlineData'].get('mimeType', '').startswith('audio/')]
    if not audio_parts:
        raise RuntimeError('TTS returned no audio')
    mime = audio_parts[0].get('mimeType', '')
    match = re.search(r'rate=(\d+)', mime)
    rate = int(match.group(1)) if match else 24000
    pcm = b''.join(base64.b64decode(p['data']) for p in audio_parts)
    if len(pcm) < rate * 2 or len(pcm) % 2:
        raise RuntimeError('TTS returned empty or malformed audio')
    original = target.with_suffix('.wav')
    with wave.open(str(original), 'wb') as out:
        out.setnchannels(1); out.setsampwidth(2); out.setframerate(rate); out.writeframes(pcm)
    converted = target.with_name(target.name + '-16k.wav')
    subprocess.run(['/usr/bin/afconvert', str(original), str(converted), '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1'], check=True, capture_output=True)
    with wave.open(str(converted), 'rb') as inp:
        assert inp.getframerate() == 16000 and inp.getnchannels() == 1 and inp.getsampwidth() == 2
        raw = inp.readframes(inp.getnframes())
    values = [x[0] for x in struct.iter_unpack('<h', raw)]
    active = []
    for offset in range(0, len(values), 320):
        frame = values[offset:offset+320]
        rms = math.sqrt(sum(x*x for x in frame) / len(frame)) / 32768
        if rms > 10 ** (-60 / 20):
            active.append(offset)
    if not active:
        raise RuntimeError('TTS audio has no meaningful energy')
    # Preserve the original WAV; remove only outer silence for a repeatable release point.
    begin = max(0, active[0] - 1600)
    end = min(len(values), active[-1] + 320 + 1600)
    trimmed = raw[begin*2:end*2]
    target.with_suffix('.pcm').write_bytes(trimmed)
    result = dict(sample, model=args.model, pcm=str(target.with_suffix('.pcm').resolve()), original_wav=str(original.resolve()), duration_s=len(trimmed)/32000, original_duration_s=len(raw)/32000, outer_silence_guard_ms=100, trim_threshold_db=-60, sha256=hashlib.sha256(trimmed).hexdigest(), generation_seconds=time.monotonic()-started, usage=body.get('usageMetadata', {}))
    metadata.write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n')
    return result

results = []
with ThreadPoolExecutor(max_workers=3) as pool:
    futures = {pool.submit(generate, s): s['id'] for s in samples}
    for future in as_completed(futures):
        try:
            result = future.result()
        except Exception as error:
            print('FAILED', futures[future], type(error).__name__, str(error) if isinstance(error, RuntimeError) else '', flush=True)
            raise SystemExit(1)
        results.append(result)
        print('GENERATED', result['id'], 'duration_s=', round(result['duration_s'], 2), flush=True)
results.sort(key=lambda r: r['id'])
(args.output/'manifest.json').write_text(json.dumps(results, ensure_ascii=False, indent=2)+'\n')
print('Corpus ready:', len(results), 'clips', flush=True)
