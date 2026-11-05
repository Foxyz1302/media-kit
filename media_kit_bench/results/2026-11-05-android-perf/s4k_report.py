#!/usr/bin/env python3
"""s4k_report.py <prefix>: the first 3 s of each 4K start (start4k checks) + the bufprobe frames."""
import json, re, sys
from collections import defaultdict
pre = sys.argv[1]
recs = [json.loads(l) for l in open(pre + '.jsonl')]
probe = []  # (epoch s, reader, arrival ns, image ts ns, id)
for line in open(pre + '-logcat.txt', errors='replace'):
    m = re.match(r'\s*([\d.]+)\s+\d+\s+\d+ I bufprobe: f (\S+) (\d+) (\d+) (-?\d+)', line)
    if m:
        probe.append((float(m[1]), m[2], int(m[3]), int(m[4]), int(m[5])))
def at(samples, cols, key, ms):
    i = cols.index(key)
    v = [s[i] for s in samples if s[0] <= ms]
    return v[-1] if v else None
for r in recs:
    if r.get('type') != 'check' or not r['name'].startswith('start4k'):
        continue
    cols, S = r.get('columns'), r.get('samples')
    if not S:
        print(r['name'], 'ERROR', r.get('error')); continue
    o = r['openEpochMs'] / 1000
    drops = [at(S, cols, 'frame-drop-count', ms) for ms in (500, 1000, 1500, 2000, 3000)]
    ddrops = at(S, cols, 'decoder-frame-drop-count', 3000)
    delayed = at(S, cols, 'vo-delayed-frame-count', 3000)
    fr = [f for f in r['flutter'] if f[0] <= 2000]
    slow = [f for f in fr if f[2] > 8.33]
    fp = [p for p in probe if o <= p[0] <= o + 3.0]
    gaps = [(b[2] - a[2]) / 1e6 for a, b in zip(fp, fp[1:])]
    first = fp[0][0] - o if fp else None
    big = [g for g in gaps if g > 25]
    # gaps in the first 1 s of frames vs after
    f1 = [g for (p, g) in zip(fp[1:], gaps) if p[0] - fp[0][0] < 1.0]
    ids = {p[4] for p in fp}
    print(f"{r['name']:<44} hw={r['info'].get('hwdec-current')} ttff={r.get('ttffMs')} firstProbe={first and round(first*1000)}ms "
          f"drops@.5/1/1.5/2/3s={drops} decDrops={ddrops} delayed={delayed} | probe frames={len(fp)} gaps>25ms={len(big)} "
          f"(first 1s: {sum(1 for g in f1 if g > 25)}, max {max(f1) if f1 else 0:.0f}ms) ids={len(ids)} | flutter 0-2s: {len(fr)} frames, raster>8.3ms {len(slow)}, max {max([f[2] for f in fr] or [0]):.1f}")
