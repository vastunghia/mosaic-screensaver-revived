#!/usr/bin/env python3 -I
"""Spike 5: reads the folders `run.sh` leaves on other Macs and says, for each,
how many photos have a real score in Photos' database, what Vision gets to see
there without the network, and how Vision agrees with the database.

    python3 -I remote.py <results dir>...
"""
import csv, os, statistics, sys
from collections import Counter

def placeholder(r):
    # Unanalysed photos carry exactly 0.5 and no failure score; their curation is
    # 0 on some Macs and 0.5 on others, so it is not part of the test.
    return float(r['score']) == 0.5 and r['failure'] in ('null', '0', '0.0', '-0.0')

def ranks(xs):
    order = sorted(range(len(xs)), key=lambda i: xs[i])
    out = [0.0] * len(xs)
    for position, i in enumerate(order):
        out[i] = position
    return out

def worst_agreement(truth, estimate, share):
    n = max(1, round(len(truth) * share))
    worst = lambda v: set(sorted(range(len(v)), key=lambda i: v[i])[:n])
    return len(worst(truth) & worst(estimate)) / n

for folder in sys.argv[1:]:
    print(f'=== {os.path.basename(folder.rstrip("/"))}')
    system = open(os.path.join(folder, 'system.txt')).read().splitlines()
    print('   ' + ' | '.join(l.strip() for l in system[1:]))
    rows = [r for r in csv.DictReader(open(os.path.join(folder, 'assets.csv')))
            if r['photokit'] == '1' and r['kind'] == '0']
    held = [r for r in rows if placeholder(r)]
    print(f'   database: {len(rows)} visible images, placeholder {len(held)} ({100 * len(held) / len(rows):.1f} %), '
          f'analysis versions {Counter(r["analysis_version"] for r in rows).most_common(3)}')
    score = {r['uuid']: float(r['score']) for r in rows if not placeholder(r)}

    path = os.path.join(folder, 'vision.csv')
    if not os.path.exists(path):
        print('   vision: not run'); continue
    by_size = {}
    for r in csv.DictReader(open(path)):
        by_size.setdefault(int(r['size']), []).append(r)
    for size in sorted(by_size, reverse=True):
        rs = by_size[size]
        ok = [r for r in rs if r['overall']]
        sides = Counter()
        for r in ok:
            side = max(int(r['width']), int(r['height']))
            sides['<300' if side < 300 else '<427' if side < 427 else '<854' if side < 854 else '>=854'] += 1
        both = [r for r in ok if r['uuid'] in score]
        line = (f'   vision {size}: {len(ok)} of {len(rs)} available locally, long side {dict(sides)}, '
                f'isUtility {sum(r["is_utility"] == "true" for r in ok)}')
        if len(both) > 10:
            t = [score[r['uuid']] for r in both]; v = [float(r['overall']) for r in both]
            line += (f'\n      vs database ({len(both)} with a real score): spearman {statistics.correlation(ranks(t), ranks(v)):.3f}, '
                     f'same worst 10% {worst_agreement(t, v, .10):.2f}, 20% {worst_agreement(t, v, .20):.2f}')
        print(line)
