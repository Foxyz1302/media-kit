import sys
sys.path.insert(0, '../../tool')
import hcpp_report as h
print('| HCPP | clip | config | intervals | 1 vsync | 2 (ideal) | 3+ | not 2 | drops P | sequence (first 80) |')
print('|---|---|---|---|---|---|---|---|---|---|')
for label in sys.argv[1:]:
    recs = h.load_jsonl(label + '.jsonl')
    layers, periods = h.load_sf(label + '-sf.txt')
    kinds = h.classify(layers)
    for r in recs:
        if r.get('type') != 'run' or not r.get('ok'): continue
        b = h.window_bounds(r, 'plain')
        best = None
        for kind in ('flutter', 'window'):
            for n in [n for n, k in kinds.items() if k == kind]:
                w = [t for t in layers[n]['presents'] if b[0] <= t < b[1]]
                if best is None or len(w) > len(best): best = w
        iv = [(y - x) / 1e6 for x, y in zip(best, best[1:])]
        one = sum(1 for x in iv if x <= 12.5); two = sum(1 for x in iv if 12.5 < x <= 20.8); three = sum(1 for x in iv if x > 20.8)
        n = len(iv) or 1
        c = r.get('counters') or {}
        try: dp = int(c['plainEnd']['frame-drop-count']) - int(c['start']['frame-drop-count'])
        except Exception: dp = '-'
        seq = ''.join(str(min(9, round(x / 8.333))) for x in iv[:80])
        print(f"| {label} | {r['clip'].split('.')[0]} | {r['config']} | {len(iv)} | {100*one/n:.0f}% | {100*two/n:.0f}% | {100*three/n:.0f}% | {100*(one+three)/n:.0f}% | {dp} | {seq} |")
