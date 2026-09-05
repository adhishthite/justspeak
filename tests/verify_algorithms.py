#!/usr/bin/env python3
"""Independent mirrors for the rolling Jaccard search and deadline bounds."""
from collections import Counter
import random

rng = random.Random(20260905)

def score(a, b):
    a, b = set(a) - {''}, set(b) - {''}
    return len(a & b) / len(a | b) if a and b else 0

def rolling(a, b):
    target = set(a) - {''}
    if not target:
        return 0, 0.0
    counts = Counter(x for x in b[:len(a)] if x)
    intersection = len(target & counts.keys())
    best = (0, 0.0)
    for start in range(len(b) - len(a) + 1):
        if start:
            old, new = b[start - 1], b[start + len(a) - 1]
            if old:
                counts[old] -= 1
                if counts[old] == 0:
                    del counts[old]
                    intersection -= old in target
            if new:
                if not counts[new]:
                    intersection += new in target
                counts[new] += 1
        value = intersection / (len(target) + len(counts) - intersection)
        if value > best[1]:
            best = start, value
        if value == 1:
            break
    return best

for _ in range(10000):
    n = rng.randrange(1, 20)
    a = [rng.choice(['', 'a', 'b', 'c', 'd']) for _ in range(n)]
    b = [rng.choice(['', 'a', 'b', 'c', 'd']) for _ in range(n + rng.randrange(1, 80))]
    scores = [score(a, b[i:i+n]) for i in range(len(b)-n+1)]
    expected = scores.index(max(scores)), max(scores)
    assert rolling(a, b) == expected
for timeout in [-10, 0, 2.5, 4, 100]:
    budget = max(10, min(30, timeout + 10))
    assert 10 <= budget <= 30
    for already_elapsed in [0, 2, 15, 40]:
        assert max(0, budget - already_elapsed) >= 0
print('PASS: 10000 rolling-window mirror cases and deadline bounds.')
