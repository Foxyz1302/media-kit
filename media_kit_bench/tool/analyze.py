import json, sys, collections

def load(p):
    return [json.loads(l) for l in open(p)]

def codecs(p):
    out = []
    for line in open(p):
        parts = line.split()
        try:
            out.append((float(parts[0]) * 1000, parts[-1]))
        except (ValueError, IndexError):
            pass
    return out

def dec_for(run, cl):
    a, b = run.get('runStartEpochMs', 0), run.get('runEndEpochMs', 0) + 1500
    names = sorted({n for t, n in cl if a <= t <= b})
    short = [n.replace('c2.qti.', 'qti.').replace('c2.android.', 'sw:').replace('.decoder', '') for n in names]
    return ','.join(short) or '-'

def delta(c, key, a, b):
    try:
        return int(float(c[b][key])) - int(float(c[a][key]))
    except (KeyError, ValueError, TypeError):
        return None

def row(r, cl):
    c = r.get('counters') or {}
    p, o = r.get('plain') or {}, r.get('overlay') or {}
    info = r.get('info') or {}
    hw = info.get('hwdec-current', '') if r['config'] != 'native' else 'exoplayer'
    drops = lambda k: (delta(c, k, 'start', 'plainEnd'), delta(c, k, 'plainEnd', 'overlayEnd')) if c else (None, None)
    fd, dd, vd = drops('frame-drop-count'), drops('decoder-frame-drop-count'), drops('vo-delayed-frame-count')
    jank = lambda w: f"{100 * w.get('over16ms', 0) / max(1, w.get('flutterFrames', 0)):.0f}%" if w else '-'
    est = (c.get('overlayEnd') or {}).get('estimated-vf-fps', '') if c else ''
    return {
        'clip': r['clip'].replace('_1440p60', '').replace('.mp4', '').replace('.webm', '').replace('h264_1080p60', 'h264-1080'),
        'cfg': r['config'], 'ok': r.get('ok'), 'err': r.get('error'),
        'ttff': r.get('ttffMs'), 'motion': r.get('timeToMotionMs'), 'stall': r.get('startStallMs'),
        'hw': hw, 'dec': dec_for(r, cl),
        'rateP': p.get('playbackRate'), 'rateO': o.get('playbackRate'),
        'drop': fd, 'decdrop': dd, 'vodel': vd, 'est': est.split('.')[0] if est else '',
        'fpsP': p.get('flutterFps'), 'fpsO': o.get('flutterFps'),
        'rP': (p.get('rasterP90Ms'), p.get('rasterP99Ms')), 'rO': (o.get('rasterP90Ms'), o.get('rasterP99Ms')),
        'jP': jank(p), 'jO': jank(o), 'rebuf': r.get('rebuffers'), 'pos': r.get('positionsMs'),
    }

def table(rows, title):
    print(f"\n### {title}")
    print(f"{'clip':<9}{'config':<16}{'ttff':>5}{'motion':>7}{'stall':>6} {'hwdec/decoder':<34}{'rate P/O':<12}{'mpv drop P/O':<13}{'vo-del P/O':<11}{'est':>4} {'flutFps P/O':<12}{'raster p90/p99 P':<17}{'raster p90/p99 O':<17}{'jank P/O':<9}")
    for x in rows:
        if not x['ok']:
            print(f"{x['clip']:<9}{x['cfg']:<16}  FAILED: {x['err']}  ttff={x['ttff']} hw={x['hw']} dec={x['dec']}")
            continue
        f2 = lambda t: '/'.join('-' if v is None else str(v) for v in t)
        print(f"{x['clip']:<9}{x['cfg']:<16}{str(x['ttff']):>5}{str(x['motion'] or ''):>7}{str(x['stall'] or ''):>6} {(x['hw'] + ' ' + x['dec'])[:33]:<34}{f2((x['rateP'], x['rateO'])):<12}{f2(x['drop']):<13}{f2(x['vodel']):<11}{x['est']:>4} {f2((x['fpsP'], x['fpsO'])):<12}{f2(x['rP']):<17}{f2(x['rO']):<17}{x['jP'] + '/' + x['jO']:<9}")

v1 = [r for r in load(sys.argv[1]) if r.get('type') == 'run']
v2 = [r for r in load(sys.argv[2]) if r.get('type') == 'run']
c1, c2 = codecs(sys.argv[3]), codecs(sys.argv[4])
for pass_ in ('portrait', 'landscape'):
    rs = [r for r in v2 if r.get('pass') == pass_]
    table([row(r, c2) for r in rs], f"v2 {pass_} ({rs[0]['viewSize'] if rs else '?'})")
table([row(r, c1) for r in v1], 'v1 portrait (window confounded by start stalls; ttff/decoder valid)')
bad = [(r['pass'], r['clip'], r['config'], r.get('mpvLog')) for r in v2 if r['config'] != 'native' and any('Invalid video timestamp' in s for s in (r.get('mpvLog') or []))]
print(f"\nv2 media_kit runs with 'Invalid video timestamp' warnings: {len(bad)} of {sum(1 for r in v2 if r['config'] != 'native')}")
