#!/usr/bin/env python3
"""Alternate unchanged settings against baseline/current Live clients. Uses an environment key."""
import argparse
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--pcm', type=Path, required=True, help='Synthetic 16 kHz mono signed PCM16 LE')
parser.add_argument('--baseline', default='c82d3a1')
parser.add_argument('--rounds', type=int, default=2)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
assert os.environ.get('GEMINI_API_KEY'), 'GEMINI_API_KEY must be set in the environment'
audio = args.pcm.read_bytes()
assert len(audio) > 32000 and len(audio) % 2 == 0, 'Audio is empty or malformed'
assert max(abs(v[0]) for v in struct.iter_unpack('<h', audio)) > 500, 'Audio has no speech energy'
logger = '''import Foundation
import Darwin
setbuf(stdout, nil)
struct ANSI { static let bold=""; static let cyan=""; static let reset="" }
struct Logger {
 static func info(_ a:String,_ b:String) {}
 static func success(_ a:String,_ b:String) {}
 static func warn(_ a:String,_ b:String) {}
 static func error(_ a:String,_ b:String) { print("DIAGNOSTIC component=\\(a) error=true") }
 static func debug(_ a:String,_ b:String) {}
 static func meter(_ a:String) {}
 static func endMeter() {}
}
'''
versions = {
    'before': subprocess.check_output(['git', 'show', f'{args.baseline}:src/09-live-client.swift'], cwd=root, text=True),
    'after': (root / 'src/09-live-client.swift').read_text(),
}
rows = []
with tempfile.TemporaryDirectory(prefix='justspeak-live-') as tmp:
    for index in range(args.rounds):
        order = ['before', 'after'] if index % 2 == 0 else ['after', 'before']
        for version in order:
            print(f'RUN round={index + 1} version={version}', flush=True)
            script = Path(tmp) / 'benchmark.swift'
            script.write_text(logger + versions[version] + '\n' + (root / 'tests/live-fixture.swift').read_text())
            result = subprocess.run(['/usr/bin/swift', '-module-cache-path', str(Path(tempfile.gettempdir()) / 'justspeak-test-module-cache'), str(script), '150', '700', 'false', str(args.pcm.resolve())], capture_output=True, text=True, timeout=90)
            for line in result.stdout.splitlines():
                if line.startswith('RESULT {'):
                    row = json.loads(line[7:])
                    row.update(version=version, round=index + 1)
                    rows.append(row)
                    print(json.dumps(row), flush=True)
                elif line.startswith('RESULT '):
                    print(line, flush=True)
            args.output.write_text(json.dumps(rows, indent=2) + '\n')
            if result.returncode:
                raise SystemExit(f'Benchmark failed with exit code {result.returncode}; raw errors suppressed to protect credentials.')
