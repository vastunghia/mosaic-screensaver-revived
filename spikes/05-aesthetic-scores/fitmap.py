#!/usr/bin/env python3 -I
"""The map from Vision's overall score onto Photos' scale, as the table
`VisionScoreMap` keeps: Vision's and Photos' scores at the same quantiles of the
photographs both scored, denser in the tail where the bar cuts. Prints Swift.

    python3 -I fitmap.py <sergio-assets.csv> <probe.csv> <column>

`probe.csv` is `--probe-quality`'s output, `column` the score to fit, such as
exact_overall. Between knots the map is linear, so it also prints how far that
is from the step map `calibrate.py` judged.
"""
import bisect, csv, statistics, sys

assets_csv, probe_csv, column = sys.argv[1:]

def placeholder(r):
    return float(r['score']) == 0.5 and r['failure'] in ('null', '0', '0.0', '-0.0', '')

photos = {r['uuid']: float(r['score']) for r in csv.DictReader(open(assets_csv))
          if r['photokit'] == '1' and r['kind'] == '0' and not placeholder(r)}
vision = {r['id'].split('/')[0]: float(r[column]) for r in csv.DictReader(open(probe_csv)) if r[column]}
common = sorted(u for u in vision if u in photos)
xs = sorted(vision[u] for u in common)
ys = sorted(photos[u] for u in common)
n = len(common)

quantiles = [0, .01, .02, .03, .04, .05, .06, .07, .08, .09, .10, .11, .12, .13, .14, .15, .175, .20,
             .25, .30, .35, .40, .45, .50, .55, .60, .65, .70, .75, .80, .85, .90, .95, .975, .99, 1]
def at(values, q):
    return values[min(int(q * (len(values) - 1) + .5), len(values) - 1)]
knots = []
for q in quantiles:
    x, y = at(xs, q), at(ys, q)
    if knots and x <= knots[-1][0]:
        continue
    knots.append((x, max(y, knots[-1][1]) if knots else y))

def linear(v):
    if v <= knots[0][0]: return knots[0][1]
    if v >= knots[-1][0]: return knots[-1][1]
    i = bisect.bisect_right([k[0] for k in knots], v)
    (x0, y0), (x1, y1) = knots[i - 1], knots[i]
    return y0 + (y1 - y0) * (v - x0) / (x1 - x0)

def step(v):
    q = bisect.bisect_left(xs, v) / n
    return ys[min(int(q * n), n - 1)]

def ranks(values):
    order = sorted(range(len(values)), key=lambda i: values[i])
    out = [0] * len(values)
    for position, i in enumerate(order): out[i] = position
    return out

truth = [photos[u] for u in common]
mapped = [linear(vision[u]) for u in common]
gaps = sorted(abs(linear(vision[u]) - step(vision[u])) for u in common)
print(f'// {n} photographs, column {column}; Spearman with Photos '
      f'{statistics.correlation(ranks(truth), ranks(mapped)):.3f}; '
      f'linear against step: median {gaps[n // 2]:.4f}, max {gaps[-1]:.4f}')
for x, y in knots:
    print(f'        ({x:.4f}, {y:.4f}),')
