#!/usr/bin/env python3 -I
"""Spike 5: can Vision's overallScore stand in for Photos' score once mapped onto
its scale? The map is monotone, by quantiles: a Vision score goes to its quantile
among Vision scores, and from there to Photos' score at the same quantile. It is
fitted on one half of the photos and judged on the other (two folds, by UUID).

The yardstick is how far Photos disagrees with itself: the same photo analysed on
two profiles of one iCloud library.

    python3 -I calibrate.py <sergio-assets.csv> <second-assets.csv> <vision.csv>...
"""
import bisect, csv, hashlib, statistics, sys

sergio_csv, second_csv, *vision_csvs = sys.argv[1:]

def visible(path):
    return [r for r in csv.DictReader(open(path)) if r['photokit'] == '1' and r['kind'] == '0']

def placeholder(r):
    # Unanalysed photos carry exactly 0.5 and no failure score; their curation is
    # 0 on some Macs and 0.5 on others, so it is not part of the test.
    return float(r['score']) == 0.5 and r['failure'] in ('null', '0', '0.0', '-0.0')

sergio = {r['uuid']: r for r in visible(sergio_csv)}
photos = {u: float(r['score']) for u, r in sergio.items() if not placeholder(r)}

vision = {}                                   # size -> uuid -> score
for path in vision_csvs:
    for r in csv.DictReader(open(path)):
        if r['overall']:
            vision.setdefault(int(r['size']), {})[r['uuid']] = float(r['overall'])

def ranks(xs):
    order = sorted(range(len(xs)), key=lambda i: xs[i])
    out = [0.0] * len(xs)
    for position, i in enumerate(order):
        out[i] = position
    return out

def spearman(a, b):
    return statistics.correlation(ranks(a), ranks(b))

def fit(pairs):
    """The quantile map from the first value of each pair onto the second."""
    xs = sorted(p[0] for p in pairs)
    ys = sorted(p[1] for p in pairs)
    def apply(x):
        q = bisect.bisect_left(xs, x) / len(xs)
        return ys[min(int(q * len(ys)), len(ys) - 1)]
    return apply

def drop_agreement(truth, estimate, share):
    """Of the photos the truth puts in the worst `share`, how many the estimate
    puts there too (both drop the same number of photos)."""
    n = round(len(truth) * share)
    worst = lambda values: set(sorted(range(len(values)), key=lambda i: values[i])[:n])
    return len(worst(truth) & worst(estimate)) / n

def report(name, truth, estimate):
    gaps = sorted(abs(a - b) for a, b in zip(truth, estimate))
    print(f'{name:<28} n {len(truth):>6}  spearman {spearman(truth, estimate):.3f}  '
          f'|gap| median {gaps[len(gaps) // 2]:.3f} p90 {gaps[int(len(gaps) * .9)]:.3f}  '
          f'same worst 5% {drop_agreement(truth, estimate, .05):.2f}  '
          f'10% {drop_agreement(truth, estimate, .10):.2f}  20% {drop_agreement(truth, estimate, .20):.2f}')

# Yardstick: Photos against Photos, two profiles.
second = {r['cloud_guid']: r for r in visible(second_csv) if not placeholder(r)}
pairs = [(float(r['score']), float(second[r['cloud_guid']]['score']))
         for r in sergio.values() if not placeholder(r) and r['cloud_guid'] in second]
report('Photos, second profile vs Sergio', [p[1] for p in pairs], [p[0] for p in pairs])

fold = lambda u: hashlib.sha1(u.encode()).digest()[0] % 2
for size in sorted(vision, reverse=True):
    common = sorted(u for u in vision[size] if u in photos)
    truth, mapped, raw = [], [], []
    for k in (0, 1):
        apply = fit([(vision[size][u], photos[u]) for u in common if fold(u) != k])
        for u in common:
            if fold(u) == k:
                truth.append(photos[u]); mapped.append(apply(vision[size][u])); raw.append(vision[size][u])
    report(f'Vision {size} mapped', truth, mapped)
    gaps = sorted(abs(a - b) for a, b in zip(truth, raw))
    print(f'{"":<28} unmapped |gap| median {gaps[len(gaps) // 2]:.3f} p90 {gaps[int(len(gaps) * .9)]:.3f}')

# The map itself, fitted on everything at the size that ranks closest to Photos.
best = max(vision, key=lambda s: spearman([photos[u] for u in vision[s] if u in photos],
                                          [vision[s][u] for u in vision[s] if u in photos]))
apply = fit([(vision[best][u], photos[u]) for u in vision[best] if u in photos])
print(f'\nmap at {best} px (Vision -> Photos):',
      ', '.join(f'{v:+.1f}->{apply(v):.2f}' for v in (-0.8, -0.4, 0, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8)))
