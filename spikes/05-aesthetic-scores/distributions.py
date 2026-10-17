#!/usr/bin/env python3 -I
"""Spike 5: the distribution of every score column in Photos.sqlite over the
photos PhotoKit shows, as one page of small histograms. Exact values that hold
2 % of the photos or more, and most of their bin, are drawn apart and labelled: they are where sentinels,
placeholders and neutral levels show. Under each histogram, the mean aesthetic
score per quintile of that column, which tells which end is the good one.

    python3 -I distributions.py <out dir> [<library.photoslibrary>]
"""
import json, os, sqlite3, sys
from collections import Counter

out = sys.argv[1]
library = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser('~/Pictures/Foto Library.photoslibrary')
BINS, SPIKE = 50, 0.02

GROUPS = [
    ('Main scores', [('a', 'ZOVERALLAESTHETICSCORE'), ('m', 'ZWALLPAPERSCORE'), ('a', 'ZCURATIONSCORE'),
                     ('a', 'ZHIGHLIGHTVISIBILITYSCORE'), ('m', 'ZBLURRINESSSCORE'), ('m', 'ZEXPOSURESCORE')]),
    ('Aesthetic sub-scores (ZCOMPUTEDASSETATTRIBUTES)', [('c', c) for c in (
        'ZFAILURESCORE', 'ZNOISESCORE', 'ZINTRUSIVEOBJECTPRESENCESCORE', 'ZPLEASANTCOMPOSITIONSCORE',
        'ZPLEASANTLIGHTINGSCORE', 'ZPLEASANTPATTERNSCORE', 'ZPLEASANTPERSPECTIVESCORE',
        'ZPLEASANTPOSTPROCESSINGSCORE', 'ZPLEASANTREFLECTIONSSCORE', 'ZPLEASANTSYMMETRYSCORE',
        'ZPLEASANTCAMERATILTSCORE', 'ZHARMONIOUSCOLORSCORE', 'ZLIVELYCOLORSCORE', 'ZIMMERSIVENESSSCORE',
        'ZINTERESTINGSUBJECTSCORE', 'ZSHARPLYFOCUSEDSUBJECTSCORE', 'ZTASTEFULLYBLURREDSCORE',
        'ZWELLCHOSENSUBJECTSCORE', 'ZWELLFRAMEDSUBJECTSCORE', 'ZWELLTIMEDSHOTSCORE', 'ZLOWLIGHT')]),
    ('With caution', [('a', 'ZICONICSCORE'), ('c', 'ZBEHAVIORALSCORE'), ('a', 'ZSTICKERCONFIDENCESCORE'),
                      ('c', 'ZINTERACTIONSCORE')]),
    ('Carry no information', [('a', 'ZPROMOTIONSCORE'), ('m', 'ZVIDEOSCORE'), ('m', 'ZAUDIOSCORE'),
                              ('m', 'ZACTIVITYSCORE'), ('m', 'ZAUTOPLAYSUGGESTIONSCORE'),
                              ('m', 'ZSETTLINGEFFECTSCORE'), ('m', 'ZVIDEOSTICKERSUGGESTIONSCORE')]),
]
TABLE = {'a': 'ZASSET', 'c': 'ZCOMPUTEDASSETATTRIBUTES', 'm': 'ZMEDIAANALYSISASSETATTRIBUTES'}

db = sqlite3.connect(f'file:{library}/database/Photos.sqlite?mode=ro', uri=True)
columns = [f'{t}.{c}' for _, cols in GROUPS for t, c in cols]
rows = db.execute(f'''
    select a.ZOVERALLAESTHETICSCORE, {", ".join(columns)}
    from ZASSET a
    join ZCOMPUTEDASSETATTRIBUTES c on c.ZASSET = a.Z_PK
    join ZMEDIAANALYSISASSETATTRIBUTES m on m.ZASSET = a.Z_PK
    where a.ZKIND = 0 and a.ZTRASHEDSTATE = 0 and a.ZHIDDEN = 0 and a.ZVISIBILITYSTATE = 0''').fetchall()
total = len(rows)

def describe(i, table, name):
    pairs = [(r[i + 1], r[0]) for r in rows if r[i + 1] is not None]
    values = sorted(p[0] for p in pairs)
    n = len(values)
    lo, hi = values[0], values[-1]
    exact = Counter(values)
    width = (hi - lo) / BINS or 1
    slot = lambda v: min(int((v - lo) / width), BINS - 1)
    per_bin = Counter(slot(v) for v in values)
    # A spike is one exact value that is both common and most of its bin: a
    # sentinel or a neutral level. Values near 0 in half precision come in
    # steps that are each common, but share their bin with their neighbours.
    spikes = sorted((v, k) for v, k in exact.items() if k / total >= SPIKE and k > per_bin[slot(v)] / 2)
    spiked = {v for v, _ in spikes}
    bins = [0] * BINS
    for v in values:
        if v not in spiked:
            bins[slot(v)] += 1
    # Direction: mean aesthetic score per quintile of this column, ties kept in order.
    pairs.sort(key=lambda p: p[0])
    quintiles = [sum(p[1] for p in pairs[k * n // 5:(k + 1) * n // 5]) / max(1, (k + 1) * n // 5 - k * n // 5)
                 for k in range(5)]
    mean_aesthetic = sum(p[1] for p in pairs) / n
    return dict(name=name, mean_aesthetic=mean_aesthetic, table=TABLE[table], n=n, nulls=total - n, min=lo, max=hi,
                mean=sum(values) / n, median=values[n // 2], p10=values[n // 10], p90=values[9 * n // 10],
                distinct=len(exact), top=exact.most_common(1)[0], lo=lo, width=width, bins=bins,
                spikes=spikes, quintiles=quintiles)

data, i = [], 0
for title, cols in GROUPS:
    group = []
    for table, name in cols:
        group.append(describe(i, table, name))
        i += 1
    data.append(dict(title=title, scores=group))

os.makedirs(out, exist_ok=True)
page = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'distributions.html')).read()
page = page.replace('/*DATA*/null', json.dumps(dict(total=total, spike=SPIKE, bins=BINS, groups=data, meanAesthetic=sum(r[0] for r in rows) / total)))
open(os.path.join(out, 'index.html'), 'w').write(page)
print('wrote', os.path.join(out, 'index.html'), total, 'photos,', i, 'columns')
