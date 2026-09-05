#!/usr/bin/env python3
"""Explicitly open the default microphone in two Swift processes; retain no audio."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--run', action='store_true', help='Opt in to a short real microphone check')
args = parser.parse_args()
if not args.run:
    parser.error('Pass --run to authorize microphone use for this check.')
root = Path(__file__).resolve().parents[1]
peer_source = r'''
import Foundation
import AVFoundation
import Darwin
setbuf(stdout, nil)
let engine = AVAudioEngine()
let input = engine.inputNode
let format = input.outputFormat(forBus: 0)
guard format.sampleRate > 0, format.channelCount > 0 else { exit(1) }
let lock = NSLock()
var announced = false
var lastAnnouncement: TimeInterval = 0
input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
    guard buffer.frameLength > 0 else { return }
    lock.lock()
    let now = ProcessInfo.processInfo.systemUptime
    let first = !announced || now - lastAnnouncement > 0.25
    if first { lastAnnouncement = now }
    announced = true
    lock.unlock()
    if first { DispatchQueue.main.async { print("PEER_READY") } }
}
engine.prepare()
do { try engine.start() } catch { exit(1) }
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler { engine.stop(); input.removeTap(onBus: 0); exit(0) }
termination.resume()
DispatchQueue.main.asyncAfter(deadline: .now() + 20) { engine.stop(); exit(0) }
RunLoop.main.run()
'''
sources = ''.join(p.read_text() for p in sorted((root / 'src').glob('*.swift')) if p.name != '99-main.swift')
fixture = (root / 'tests/mic-hardware-check.swift').read_text()
with tempfile.TemporaryDirectory(prefix='justspeak-mic-hardware-') as tmp:
    directory = Path(tmp)
    program = directory / 'check.swift'
    peer = directory / 'peer.swift'
    program.write_text(sources + '\n' + fixture)
    peer.write_text(peer_source)
    process = subprocess.Popen(
        ['/usr/bin/swift', '-module-cache-path', str(Path(tempfile.gettempdir()) / 'justspeak-test-module-cache'), str(program), str(peer)],
        cwd=root, start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=35)
        result = process.returncode
        for line in stdout.splitlines():
            if line.startswith("MIC_CHECK "):
                print(line)
        if result and not any(line.startswith("MIC_CHECK FAIL") for line in stdout.splitlines()):
            reason = "coreaudio_unavailable" if "comp != nullptr" in stderr else "swift_process_failed"
            print(f"MIC_CHECK FAIL {reason} exit={result}")
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
        raise SystemExit('MIC_CHECK FAIL harness_timeout')
    raise SystemExit(result)
