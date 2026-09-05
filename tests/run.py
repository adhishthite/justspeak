#!/usr/bin/env python3
"""Run dependency-free Swift checks through Apple's interpreter, without app startup."""
import argparse
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
mode = parser.add_mutually_exclusive_group()
mode.add_argument('--benchmark', action='store_true')
mode.add_argument('--hud', action='store_true')
parser.add_argument('--baseline', default='c82d3a1')
args = parser.parse_args()
sources = ''.join(p.read_text() for p in sorted((root / 'src').glob('*.swift')) if p.name != '99-main.swift')
legacy = subprocess.check_output(['git', 'show', f'{args.baseline}:src/28-correction-watcher.swift'], cwd=root, text=True)
legacy = 'struct LegacyCorrectionWatcher { struct Pair { let wrong: String; let right: String }\n' + legacy[legacy.index('    static func extractCorrections'):]
fixture = (root / 'tests' / ('benchmark.swift' if args.benchmark else 'hud-check.swift' if args.hud else 'regressions.swift')).read_text()
if not args.benchmark and not args.hud:
    for extra in sorted((root / 'tests').glob('*-regressions.swift')):
        fixture += '\n' + extra.read_text()
    fixture += '\nprint(\"PASS: \\(checks) total regression checks.\")\n'
with tempfile.TemporaryDirectory(prefix='justspeak-test-') as tmp:
    generated = Path(tmp) / 'checks.swift'
    generated.write_text(sources + '\n' + legacy + '\n' + fixture)
    subprocess.run(['/usr/bin/swift', '-module-cache-path', str(Path(tempfile.gettempdir()) / 'justspeak-test-module-cache'), str(generated)], check=True, cwd=root)
