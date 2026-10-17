#!/usr/bin/env python3 -I
"""Spike 5: ten random photos from each tenth of Photos' aesthetic score
(0-0.1, ..., 0.9-1), across the whole library, to judge the score by eye.

    python3 -I deciles.py ids <assets.csv> <dir>     # writes <dir>/ids.txt
    (probe) --previews <dir>/previews --ids <dir>/ids.txt
    python3 -I deciles.py page <assets.csv> <dir>    # writes <dir>/index.html
"""
import csv, datetime, html, os, random, sys

mode, assets, out = sys.argv[1:4]
PER_BAND, SEED = 10, 17

rows = [r for r in csv.DictReader(open(assets))
        if r['photokit'] == '1' and r['kind'] == '0' and r['score'] != 'null']
for r in rows:
    r['s'] = float(r['score'])
scores = sorted(r['s'] for r in rows)
bands = [[] for _ in range(10)]
for r in rows:
    bands[min(int(r['s'] * 10), 9)].append(r)
rng = random.Random(SEED)
picks = [sorted(rng.sample(sorted(b, key=lambda r: r['uuid']), min(PER_BAND, len(b))), key=lambda r: r['s'])
         for b in bands]

if mode == 'ids':
    os.makedirs(out, exist_ok=True)
    open(os.path.join(out, 'ids.txt'), 'w').write('\n'.join(r['uuid'] for p in picks for r in p) + '\n')
    sys.exit()

def percentile(x):
    import bisect
    return 100 * bisect.bisect_left(scores, x) / len(scores)

def tile(r):
    created = datetime.datetime(2001, 1, 1) + datetime.timedelta(seconds=float(r['created']))
    tags = ' · screenshot' if r['screenshot'] == '1' else ''
    return (f'<figure><a href="previews/{r["uuid"]}.jpg"><img loading="lazy" src="previews/{r["uuid"]}.jpg"></a>'
            f'<figcaption><b>{r["s"]:.3f}</b> · {created:%Y-%m-%d}<br>'
            f'fail {float(r["failure"] or 0) if r["failure"] != "null" else 0:+.3f} · cur {float(r["curation"]):.2f}{tags}</figcaption></figure>')

parts = []
for i, (band, pick) in enumerate(zip(bands, picks)):
    lo, hi = i / 10, (i + 1) / 10
    top = '1' if i == 9 else f'{hi:.1f}'
    parts.append(f'<h2>{lo:.1f} – {top} <small>{len(band):,} photos, {100 * len(band) / len(rows):.1f} % of the library, '
                 f'percentiles {percentile(lo):.1f} – {percentile(hi) if i < 9 else 100:.1f}</small></h2>'
                 f'<div class="grid">{"".join(tile(r) for r in pick)}</div>')

page = f'''<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Score deciles</title>
<style>
:root {{ color-scheme: light dark; --bg: #fff; --fg: #111; --muted: #666; --tile: #eee }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg: #1c1c1e; --fg: #eee; --muted: #999; --tile: #2c2c2e }} }}
body {{ font: 13px -apple-system, sans-serif; margin: 16px; background: var(--bg); color: var(--fg) }}
.grid {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 10px }}
figure {{ margin: 0 }} img {{ width: 100%; height: 170px; object-fit: contain; background: var(--tile) }}
figcaption {{ font-size: 11px; line-height: 1.4 }} h2 {{ margin-top: 28px; font-size: 17px }}
small {{ font-weight: normal; color: var(--muted) }} p {{ color: var(--muted) }}
</style>
<h1>Photos' aesthetic score, ten random photos per tenth</h1>
<p>{len(rows):,} photos visible to PhotoKit in the library, score = ZOVERALLAESTHETICSCORE (0 is a real score, the
bottom of the scale). Within a band, lowest score first. fail = ZFAILURESCORE, cur = ZCURATIONSCORE.
Random seed {SEED}. Click a photo for a 640 px preview.</p>
''' + ''.join(parts)
open(os.path.join(out, 'index.html'), 'w').write(page)
print('wrote', os.path.join(out, 'index.html'), [len(p) for p in picks])
