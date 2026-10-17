#!/usr/bin/env python3 -I
"""Spike 5, questions 5-7: Vision's scores against Photos' own, and which photos
each utility criterion would leave out. Reads the probe's vision.csv and the
library's databases (read only), writes summary.txt and index.html next to the CSV.

    python3 -I analyze.py <specimen dir> [<library.photoslibrary>]
"""
import csv, html, os, sqlite3, struct, sys, uuid
from collections import Counter, defaultdict

out = sys.argv[1]
library = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser('~/Pictures/Foto Library.photoslibrary')

# Scene labels that mark a utility shot. "strict" is what nobody would want on a
# screen saver; "broad" adds labels that also tag real photographs.
STRICT = {492: 'document', 1664: 'handwriting', 18512: 'writing', 1663: 'ticket', 14852: 'menu',
          10580: 'barcode', 337: 'blackboard', 1494: 'whiteboard', 340: 'chart', 15832: 'chart',
          15291: 'nutrition label', 910: 'newspaper', 16933: 'blueprint', 402: 'computer monitor',
          12424: 'screen', 14412: 'LCD screen', 12995: 'flat monitor'}
BROAD = {**STRICT, 241: 'book', 839: 'map', 12516: 'drawing', 11921: 'comics', 15494: 'paper'}
SCENE_CONFIDENCE = 0.5

def ro(path):
    return sqlite3.connect(f'file:{path}?mode=ro', uri=True)

# --- Vision, from the probe
vision = defaultdict(dict)            # uuid -> size -> (overall, is_utility)
cost = defaultdict(list)
for row in csv.DictReader(open(os.path.join(out, 'vision.csv'))):
    if not row['overall']:
        continue
    size = int(row['size'])
    vision[row['uuid']][size] = (float(row['overall']), row['is_utility'] == 'true')
    cost[size].append((float(row['fetch_ms']), float(row['vision_ms'])))
uuids = sorted(vision)
sizes = sorted({s for v in vision.values() for s in v}, reverse=True)

# --- Photos.sqlite
db = ro(os.path.join(library, 'database/Photos.sqlite'))
marks = ','.join('?' * len(uuids))
photos = {}
for r in db.execute(f'''
        select a.ZUUID, a.ZOVERALLAESTHETICSCORE, a.ZCURATIONSCORE, c.ZFAILURESCORE, c.ZNOISESCORE,
               c.ZPLEASANTCOMPOSITIONSCORE, a.ZISDETECTEDSCREENSHOT, a.Z_PK
        from ZASSET a left join ZCOMPUTEDASSETATTRIBUTES c on c.ZASSET = a.Z_PK
        where a.ZUUID in ({marks})''', uuids):
    photos[r[0]] = dict(db=r[1], curation=r[2], failure=r[3], noise=r[4], composition=r[5],
                        screenshot=bool(r[6]), pk=r[7], scenes={}, collections=set())
by_pk = {p['pk']: u for u, p in photos.items()}
pks = ','.join(str(pk) for pk in by_pk)
for asset, scene, confidence in db.execute(f'''
        select aa.ZASSET, s.ZSCENEIDENTIFIER, s.ZCONFIDENCE
        from ZSCENECLASSIFICATION s join ZADDITIONALASSETATTRIBUTES aa on aa.Z_PK = s.ZASSETATTRIBUTES
        where aa.ZASSET in ({pks}) and s.ZCLASSIFICATIONTYPE = 0 and s.ZCONFIDENCE >= ?''',
        (SCENE_CONFIDENCE,)):
    if scene in BROAD:
        photos[by_pk[asset]]['scenes'][BROAD[scene]] = confidence

# --- psi.sqlite: Photos' Utilities collections
psi = ro(os.path.join(library, 'database/search/psi.sqlite'))
for u0, u1, name in psi.execute('''
        select a.uuid_0, a.uuid_1, g.content_string
        from groups g join ga on ga.groupid = g.rowid join assets a on a.rowid = ga.assetid
        where g.category = 2800'''):
    u = str(uuid.UUID(bytes=struct.pack('<qq', u0, u1))).upper()
    if u in photos:
        photos[u]['collections'].add(name.rstrip('\x00'))

# --- Question 5: correlation
def ranks(xs):
    order = sorted(range(len(xs)), key=lambda i: xs[i])
    r = [0.0] * len(xs)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and xs[order[j + 1]] == xs[order[i]]:
            j += 1
        for k in range(i, j + 1):
            r[order[k]] = (i + j) / 2
        i = j + 1
    return r

def spearman(a, b):
    ra, rb = ranks(a), ranks(b)
    n = len(a); ma = sum(ra) / n; mb = sum(rb) / n
    cov = sum((x - ma) * (y - mb) for x, y in zip(ra, rb))
    return cov / (sum((x - ma) ** 2 for x in ra) * sum((y - mb) ** 2 for y in rb)) ** 0.5

both = [u for u in uuids if u in photos and photos[u]['db'] is not None and all(s in vision[u] for s in sizes)]
lines = [f'photos: {len(uuids)} with a Vision score, {len(both)} also in Photos.sqlite', '']
for size in sizes:
    f = [c[0] for c in cost[size]]; v = sorted(c[1] for c in cost[size])
    lines.append(f'cost at {size} px: fetch {sum(f)/len(f):.1f} ms, Vision mean {sum(v)/len(v):.1f} ms, '
                 f'median {v[len(v)//2]:.1f} ms, p95 {v[int(len(v)*.95)]:.1f} ms, first {cost[size][0][1]:.0f} ms')
lines.append('')
dbs = [photos[u]['db'] for u in both]
for size in sizes:
    lines.append(f'spearman Photos vs Vision {size}: {spearman(dbs, [vision[u][size][0] for u in both]):.3f}')
if len(sizes) > 1:
    lines.append(f'spearman Vision {sizes[0]} vs {sizes[1]}: '
                 f'{spearman([vision[u][sizes[0]][0] for u in both], [vision[u][sizes[1]][0] for u in both]):.3f}')
for size in sizes:
    vs = sorted(vision[u][size][0] for u in both)
    lines.append(f'Vision {size} range {vs[0]:.3f} .. {vs[-1]:.3f}, median {vs[len(vs)//2]:.3f}')
lines.append(f'Photos range {min(dbs):.3f} .. {max(dbs):.3f}, median {sorted(dbs)[len(dbs)//2]:.3f}, zeros {dbs.count(0)}')
lines.append('')

# --- Question 7: utility
main = sizes[0]
criteria = {
    'collections': lambda u: bool(photos[u]['collections']),
    'scenes strict': lambda u: any(k in STRICT.values() for k in photos[u]['scenes']),
    'scenes broad': lambda u: bool(photos[u]['scenes']),
    'screenshot': lambda u: photos[u]['screenshot'],
    f'vision isUtility {main}': lambda u: vision[u][main][1],
}
if len(sizes) > 1:
    criteria[f'vision isUtility {sizes[1]}'] = lambda u: vision[u][sizes[1]][1]
flagged = {name: {u for u in both if test(u)} for name, test in criteria.items()}
for name, s in flagged.items():
    lines.append(f'utility by {name}: {len(s)}')
names = list(flagged)
lines.append('overlaps:')
for i, a in enumerate(names):
    for b in names[i + 1:]:
        lines.append(f'  {a} & {b}: {len(flagged[a] & flagged[b])}')
coll = Counter(c for u in both for c in photos[u]['collections'])
scenes = Counter(k for u in both for k in photos[u]['scenes'])
lines.append(f'collections: {dict(coll)}')
lines.append(f'scenes (confidence >= {SCENE_CONFIDENCE}): {dict(scenes.most_common())}')
open(os.path.join(out, 'summary.txt'), 'w').write('\n'.join(lines) + '\n')
print('\n'.join(lines))

# --- Question 6: the page
def tile(u):
    p = photos[u]
    v = ' / '.join(f'{vision[u][s][0]:.2f}' for s in sizes)
    tags = sorted(p['collections']) + [f'{k} {c:.2f}' for k, c in sorted(p['scenes'].items())]
    if p['screenshot']: tags.append('screenshot')
    if vision[u][main][1]: tags.append(f'isUtility {main}')
    if len(sizes) > 1 and vision[u][sizes[1]][1]: tags.append(f'isUtility {sizes[1]}')
    return (f'<figure><a href="previews/{u}.jpg"><img loading="lazy" src="previews/{u}.jpg"></a>'
            f'<figcaption><b>P {p["db"]:.3f}</b> · V {v}<br>fail {p["failure"] or 0:+.2f} · cur {p["curation"] or 0:.2f}'
            f'{"<br><i>" + html.escape(", ".join(tags)) + "</i>" if tags else ""}</figcaption></figure>')

def section(title, note, us):
    section.n = getattr(section, 'n', -1) + 1
    return f'<h2 id="s{section.n}">{html.escape(title)} <small>({len(us)})</small></h2><p>{html.escape(note)}</p><div class="grid">' + ''.join(tile(u) for u in us) + '</div>'

N = 64
by_db = sorted(both, key=lambda u: photos[u]['db'])
by_v = sorted(both, key=lambda u: vision[u][main][0])
mid = len(by_db) // 2
rank_db = {u: i for i, u in enumerate(by_db)}; rank_v = {u: i for i, u in enumerate(by_v)}
diff = sorted(both, key=lambda u: rank_db[u] - rank_v[u])
others = lambda name: set().union(*(flagged[n] for n in names if n != name and not (name.startswith('scenes') and n.startswith('scenes')) and not (name.startswith('vision') and n.startswith('vision'))))
sections = [
    section(f'Worst {N} by Photos', 'Lowest ZOVERALLAESTHETICSCORE first.', by_db[:N]),
    section(f'Worst {N} by Vision {main}', 'Lowest overallScore first.', by_v[:N]),
    section(f'{N} around the median, by Photos', '', by_db[mid - N // 2: mid + N // 2]),
    section(f'Best {N} by Photos', 'Highest first.', by_db[::-1][:N]),
    section(f'Best {N} by Vision {main}', 'Highest first.', by_v[::-1][:N]),
    section('Photos low, Vision high', 'Largest rank gap where Photos ranks the photo lower.', diff[:32]),
    section('Vision low, Photos high', 'Largest rank gap where Vision ranks the photo lower.', diff[::-1][:32]),
]
for name in names:
    alone = sorted(flagged[name] - others(name), key=lambda u: photos[u]['db'])
    sections.append(section(f'Utility only by {name}', 'Flagged by this criterion and by no criterion of another kind.', alone))
everyone = set.intersection(flagged['collections'], flagged['scenes broad'] | flagged['screenshot'], flagged[f'vision isUtility {main}'])
sections.append(section('Utility by all three kinds', 'Collections, scene labels or screenshot, and Vision.', sorted(everyone, key=lambda u: photos[u]['db'])))

page = f'''<!doctype html><meta charset="utf-8"><title>Spike 5 scores</title>
<style>
body {{ font: 13px -apple-system, sans-serif; margin: 16px; background: #fff; color: #111 }}
.grid {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(170px, 1fr)); gap: 8px }}
figure {{ margin: 0 }} img {{ width: 100%; height: 120px; object-fit: contain; background: #eee }}
figcaption {{ font-size: 11px; line-height: 1.35 }} h2 {{ margin-top: 32px }} pre {{ background: #f4f4f4; padding: 8px }}
</style>
<h1>Spike 5: Photos' scores and Vision's on the {len(both)} indexed photos</h1>
<p>P = Photos.sqlite ZOVERALLAESTHETICSCORE; V = Vision overallScore at {" / ".join(map(str, sizes))} px;
fail = ZFAILURESCORE; cur = ZCURATIONSCORE. Scene labels at confidence ≥ {SCENE_CONFIDENCE}. Click a photo for its preview.</p>
<pre>{html.escape(chr(10).join(lines))}</pre>
''' + ''.join(sections)
open(os.path.join(out, 'index.html'), 'w').write(page)
print('wrote', os.path.join(out, 'index.html'))
