import json, sys
for path in sys.argv[1:]:
    print('##', path)
    print('| clip | view | ok | surface | osd | ttff | motion | drops P/O (frame/dec/vo-delayed) | rate P/O | raster p90/p99 P | raster p90/p99 O | mpv GPU avg/peakΣ ms (passes) |')
    for line in open(path):
        r = json.loads(line)
        if r.get('type') != 'run': continue
        c = r.get('counters') or {}
        def d(a, b, k):
            try: return int(c[b][k]) - int(c[a][k])
            except Exception: return '-'
        dp = f"{d('start','plainEnd','frame-drop-count')}/{d('start','plainEnd','decoder-frame-drop-count')}/{d('start','plainEnd','vo-delayed-frame-count')}"
        do = f"{d('plainEnd','overlayEnd','frame-drop-count')}/{d('plainEnd','overlayEnd','decoder-frame-drop-count')}/{d('plainEnd','overlayEnd','vo-delayed-frame-count')}"
        p, o = r.get('plain') or {}, r.get('overlay') or {}
        g = r.get('gpu') or {}
        info = r.get('info') or {}
        print(f"| {r['clip']} | {r.get('view')} | {r['ok']} | {info.get('android-surface-size')} | {info.get('osd-dimensions/w')}x{info.get('osd-dimensions/h')} | {r.get('ttffMs')} | {r.get('timeToMotionMs')} | {dp} · {do} | {p.get('playbackRate')}/{o.get('playbackRate')} | {p.get('rasterP90Ms')}/{p.get('rasterP99Ms')} | {o.get('rasterP90Ms')}/{o.get('rasterP99Ms')} | {g.get('freshAvgMs')}/{g.get('freshPeakSumMs')} ({g.get('passes')}) |")
