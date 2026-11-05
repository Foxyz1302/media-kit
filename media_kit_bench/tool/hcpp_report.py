#!/usr/bin/env python3
"""HCPP A/B tables: Flutter FrameTiming per window plus SurfaceFlinger presentation of the app's layers.

Usage: hcpp_report.py <label>=<prefix>... [--summary] [--json <out.json>]

--summary prints one merged row per run and the means per config / HCPP / window instead of the two
full tables. Labels "on#2" and "off#2" count as repeats of on / off in the means.

Each <prefix> is one run_launch.py launch: <prefix>.jsonl (results), <prefix>-sf.txt (sf_latency.py)
and <prefix>-logcat.txt (`logcat --pid` of the bench app), each optionally .xz or .gz compressed.
<label> names the build, e.g. off, on, on#2.

Layers, all from the bench package only:
- video: the SurfaceView BLAST layer a platform-view run creates (ExoPlayer renders into it directly);
- flutter: the FlutterSurfaceView's BLAST layer, present from app start (KHR swapchain only; with HCPP
  Flutter draws into an unnamed child SurfaceControl, so this layer stays empty);
- window: the activity's window surface (HWUI). Hybrid composition draws Flutter through it while a
  platform view shows, and HCPP applies its frame transactions with the window's draws.
"UI" is whichever of flutter / window presented more frames in the window: what SurfaceFlinger actually
put on screen of the Flutter UI.

While a SurfaceView moves and resizes, its BLAST layer also records extra entries between the decoder's
frames. ExoPlayer releases every decoded frame with an explicit timestamp on an exact 16.667 ms cadence,
so the decoder's frames form chains of entries 1-4 source frames (+-20 us) apart (about 30 entries long:
ExoPlayer re-anchors its release times every ~0.5 s); an entry counts as a new video frame when its
chain has at least 5 entries. The extras, whose timestamps follow the window's draws, are singletons or
pairs, and are counted apart as "re-presents".

A run's SurfaceView layer is gone soon after its animated window, and its last frames after the last
dump are lost (dumps come every ~0.45 s), so video stats stop at the layer's last captured present
("video s").

Video jank: a present-to-present interval over 20.8 ms, i.e. a 60 fps frame held for 3+ vsyncs at 120 Hz
(25 ms) or 2 at 60 Hz (33 ms) instead of 16.7 ms. "short": an interval under 12.5 ms (a frame shown for a
single 120 Hz vsync; a late frame makes one short and one janky interval). UI gaps: intervals of 3+
120 Hz vsyncs (> 20.8 ms), the same threshold. Texture configs have no video layer: in their plain
window Flutter draws only when a video frame arrives, so the UI intervals there are the video cadence.

The refresh rate per window comes from the vsync period each --latency dump reports, mapped from host
time to CLOCK_MONOTONIC by the dumps' newest presents.
"""
import argparse
import bisect
import gzip
import json
import lzma
import os
import re
import statistics

INT64_MAX = (1 << 63) - 1
SOURCE_FPS = 60.0
WINDOWS = ('plain', 'overlay', 'animated')
PKG = 'dev.foxyz.media_kit_bench'


def text(path):
    """Opens path, path.xz or path.gz as text."""
    for suffix, opener in (('', open), ('.xz', lzma.open), ('.gz', gzip.open)):
        if os.path.exists(path + suffix):
            return opener(path + suffix, 'rt', errors='replace')
    raise FileNotFoundError(path)


def load_jsonl(path):
    return [json.loads(line) for line in text(path)]


def load_sf(path):
    """({layer: {'frames': {desired: actual}, 'first': host ms}}, [(host ms, period ns, newest present ns)])"""
    layers, blocks, cur, block = {}, [], None, None
    for line in text(path):
        ms, _, rest = line.rstrip('\n').partition(' ')
        if rest.startswith('@L '):
            cur = layers.setdefault(rest[3:], {'frames': {}, 'first': int(ms)})
            block = [int(ms), None, 0]
            blocks.append(block)
            continue
        if rest.startswith('@') or cur is None:
            cur = None
            continue
        parts = rest.split()
        if len(parts) == 1 and parts[0].isdigit():
            block[1] = int(parts[0])
        elif len(parts) == 3:
            d, a, _r = (int(p) for p in parts)
            if 0 < a < INT64_MAX:
                cur['frames'][d] = a
                block[2] = max(block[2], a)
    for layer in layers.values():
        layer['presents'] = sorted(set(layer['frames'].values()))
    offs = sorted(b[0] * 1e6 - b[2] for b in blocks if b[2])
    offset = offs[len(offs) // 20] if offs else None
    periods = [(b[0] * 1e6 - offset, b[1]) for b in blocks if b[1] and offset is not None]
    return layers, periods


def classify(layers):
    """Persistent layers exist from app start (first listing); everything else belongs to a run."""
    first = min((l['first'] for l in layers.values()), default=0)
    out = {}
    for name, l in layers.items():
        persistent = l['first'] - first < 3000
        if name.startswith(PKG + '/'):
            kind = 'window'
        elif 'SurfaceView' in name and '(BLAST)' in name:
            kind = 'flutter' if persistent else 'surfaceview'
        else:
            kind = 'other'
        out[name] = kind
    return out


def pct(sorted_vals, p):
    return sorted_vals[min(len(sorted_vals) - 1, int(round((len(sorted_vals) - 1) * p)))] if sorted_vals else None


def present_stats(presents, from_ns, to_ns, frames=None):
    w = [t for t in presents if from_ns <= t < to_ns]
    seconds = (to_ns - from_ns) / 1e9
    iv = [(b - a) / 1e6 for a, b in zip(w, w[1:])]
    out = {
        'frames': len(w),
        'fps': round(len(w) / seconds, 2) if seconds > 0 else None,
        'janky': sum(1 for x in iv if x > 20.8),
        'short': sum(1 for x in iv if x < 12.5),
        'over50ms': sum(1 for x in iv if x > 50),
        'maxIntervalMs': round(max(iv), 1) if iv else None,
        'vsyncs': [sum(1 for x in iv if x <= 12.5), sum(1 for x in iv if 12.5 < x <= 20.8), sum(1 for x in iv if x > 20.8)],
    }
    if frames is not None:
        late = sorted((a - d) / 1e6 for d, a in frames.items() if from_ns <= a < to_ns)
        out['latenessP50Ms'] = round(pct(late, .5), 2) if late else None
        out['latenessP99Ms'] = round(pct(late, .99), 2) if late else None
    return out


def cadence_frames(frames, tol_ns=20_000, min_chain=5):
    """Desired-present times that belong to a chain of >= min_chain entries spaced 1-4 source frames."""
    ds = sorted(frames)
    parent = list(range(len(ds)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i, d in enumerate(ds):
        for k in (1, 2, 3, 4):
            target = d + k * 1e9 / SOURCE_FPS
            j = bisect.bisect_left(ds, target - tol_ns)
            if j < len(ds) and abs(ds[j] - target) <= tol_ns:
                parent[find(i)] = find(j)
    size = {}
    for i in range(len(ds)):
        size[find(i)] = size.get(find(i), 0) + 1
    return {d for i, d in enumerate(ds) if size[find(i)] >= min_chain}


def video_stats(frames, from_ns, to_ns, real=None):
    """present_stats over new video frames only; the other entries are counted apart."""
    real = cadence_frames(frames) if real is None else real
    if frames:
        to_ns = min(to_ns, max(frames.values()) + 1)
    new, extra = {}, 0
    for d, a in frames.items():
        if from_ns <= a < to_ns:
            if d in real:
                new[d] = a
            else:
                extra += 1
    out = present_stats(sorted(new.values()), from_ns, to_ns, new)
    out['seconds'] = round((to_ns - from_ns) / 1e9, 2)
    out['rePresentsPerS'] = round(extra / ((to_ns - from_ns) / 1e9), 1)
    return out


def window_bounds(run, name):
    w = run.get(name) or {}
    if 'fromUs' not in w:
        return None
    return w['fromUs'] * 1000, w['toUs'] * 1000


def pick_video_layer(run, layers, kinds):
    b = [x for x in (window_bounds(run, n) for n in WINDOWS) if x]
    if not b:
        return None
    lo, hi = min(x[0] for x in b), max(x[1] for x in b)
    best, best_n = None, 0
    for name, kind in kinds.items():
        if kind == 'surfaceview':
            n = sum(1 for t in layers[name]['presents'] if lo <= t < hi)
            if n > best_n:
                best, best_n = name, n
    return best


def logcat_facts(path):
    facts = {'backend': None, 'hcppCheck': None, 'errors': {}, 'crash': 0}
    try:
        lines = text(path).read().splitlines()
    except FileNotFoundError:
        return facts
    for line in lines:
        if 'Using the Impeller rendering backend' in line:
            facts['backend'] = line.split('Using the Impeller rendering backend', 1)[1].strip(' .')
        m = re.search(r'checkIfSupported\(\) = (\S+)', line)
        if m:
            facts['hcppCheck'] = m.group(1)
        if re.search(r'Fatal signal|SIGABRT|SIGSEGV|FATAL EXCEPTION', line):
            facts['crash'] += 1
        m = re.match(r'^\s*\S+\s+\d+\s+\d+\s+E (.*)$', line)
        if m:
            key = re.sub(r'\d+', 'N', m.group(1).strip())[:160]
            facts['errors'][key] = facts['errors'].get(key, 0) + 1
    return facts


def analyze(label, prefix):
    recs = load_jsonl(prefix + '.jsonl')
    hello = next((r for r in recs if r.get('type') == 'hello'), {})
    try:
        layers, periods = load_sf(prefix + '-sf.txt')
    except FileNotFoundError:
        layers, periods = {}, []
    kinds = classify(layers)
    out = []
    for r in (r for r in recs if r.get('type') == 'run'):
        row = {'build': label, 'clip': r['clip'], 'config': r['config'], 'ok': r.get('ok'), 'error': r.get('error'),
               'ttffMs': r.get('ttffMs')}
        video = pick_video_layer(r, layers, kinds) if r['config'] == 'native' else None
        row['videoLayer'] = video
        for wname in WINDOWS:
            w, b = r.get(wname), window_bounds(r, wname)
            if not w or not b:
                continue
            cell = {k: w.get(k) for k in ('seconds', 'flutterFrames', 'flutterFps', 'rasterP90Ms', 'rasterP99Ms',
                                          'buildP99Ms', 'over8ms', 'over16ms', 'playbackRate')}
            ps = [p for t, p in periods if b[0] <= t < b[1]]
            cell['share120Hz'] = round(sum(1 for p in ps if p < 12_000_000) / len(ps), 2) if ps else None
            if video:
                if 'real' not in layers[video]:
                    layers[video]['real'] = cadence_frames(layers[video]['frames'])
                cell['video'] = video_stats(layers[video]['frames'], *b, layers[video]['real'])
            best = None
            for kind in ('flutter', 'window'):
                names = [n for n, k in kinds.items() if k == kind]
                if names:
                    n = max(names, key=lambda x: sum(1 for t in layers[x]['presents'] if b[0] <= t < b[1]))
                    cell[kind] = present_stats(layers[n]['presents'], *b)
                    if best is None or cell[kind]['frames'] > cell[best]['frames']:
                        best = kind
            if best:
                cell['ui'] = dict(cell[best], layer=best)
            row[wname] = cell
        out.append(row)
    return {'label': label, 'prefix': prefix, 'hello': hello,
            'layers': {n: {'kind': kinds[n], 'frames': len(l['presents'])} for n, l in layers.items()},
            'logcat': logcat_facts(prefix + '-logcat.txt'), 'runs': out}


def f(v):
    return '–' if v is None else str(v)


def print_tables(results):
    for res in results:
        lc = res['logcat']
        print(f"- `{res['label']}` ({res['prefix'].rsplit('/', 1)[-1]}): hcppActive={res['hello'].get('hcppActive')}, "
              f"logcat: backend {lc['backend']}, checkIfSupported() = {lc['hcppCheck']}, crash lines {lc['crash']}, "
              f"E lines {sum(lc['errors'].values())}")
    rows = sorted((row for res in results for row in res['runs']), key=lambda x: (x['clip'], x['config'], x['build']))
    print('\n### Flutter FrameTiming (plain / overlay / animated)\n')
    print('| clip | config | HCPP | fps | raster p90 ms | raster p99 ms | frames > 8.3 ms | frames > 16.7 ms |')
    print('|' + '---|' * 8)
    for row in rows:
        cells = [row.get(w) or {} for w in WINDOWS]
        if not row['ok']:
            print(f"| {row['clip'].rsplit('.', 1)[0]} | {row['config']} | {row['build']} | FAILED: {row['error']} ||||")
            continue
        j = lambda k: ' / '.join(f(c.get(k)) for c in cells)
        print(f"| {row['clip'].rsplit('.', 1)[0]} | {row['config']} | {row['build']} | {j('flutterFps')} | {j('rasterP90Ms')} "
              f"| {j('rasterP99Ms')} | {j('over8ms')} | {j('over16ms')} |")
    print('\n### SurfaceFlinger presentation (plain / overlay / animated)\n')
    print('| clip | config | HCPP | video fps | video janky (>20.8 ms) | video short (<12.5 ms) | video s '
          '| video re-presents/s | UI presented fps | UI gaps of 3+ vsyncs | 120 Hz share |')
    print('|' + '---|' * 11)
    for row in rows:
        if not row['ok']:
            continue
        cells = [row.get(w) or {} for w in WINDOWS]
        v = lambda k: ' / '.join(f((c.get('video') or {}).get(k)) for c in cells)
        ui_fps = ' / '.join(f((c.get('ui') or {}).get('fps')) for c in cells)
        ui_gaps = ' / '.join(f(((c.get('ui') or {}).get('vsyncs') or [None] * 3)[2]) for c in cells)
        hz = ' / '.join(f(c.get('share120Hz')) for c in cells)
        print(f"| {row['clip'].rsplit('.', 1)[0]} | {row['config']} | {row['build']} | {v('fps')} | {v('janky')} | {v('short')} "
              f"| {v('seconds')} | {v('rePresentsPerS')} | {ui_fps} | {ui_gaps} | {hz} |")


def print_summary(results):
    rows = sorted((row for res in results for row in res['runs'] if row['ok']),
                  key=lambda x: (x['clip'], x['config'], x['build']))
    print('| clip | config | HCPP | Flutter fps | raster p90 ms | raster p99 ms | frames >8.3 / >16.7 ms '
          '| video fps | video janky | UI presented fps |')
    print('|' + '---|' * 10)
    for row in rows:
        cells = [row.get(w) or {} for w in WINDOWS]
        j = lambda get: ' / '.join(f(get(c)) for c in cells)
        slow = lambda c: f"{c.get('over8ms')}/{c.get('over16ms')}" if c else None
        print(f"| {row['clip'].rsplit('.', 1)[0]} | {row['config']} | {row['build']} | {j(lambda c: c.get('flutterFps'))} "
              f"| {j(lambda c: c.get('rasterP90Ms'))} | {j(lambda c: c.get('rasterP99Ms'))} "
              f"| {j(slow)} "
              f"| {j(lambda c: (c.get('video') or {}).get('fps'))} | {j(lambda c: (c.get('video') or {}).get('janky'))} "
              f"| {j(lambda c: (c.get('ui') or {}).get('fps'))} |")
    print('\n| config | HCPP | window | runs | Flutter fps | raster p90 / p99 ms | frames >8.3 / >16.7 ms | video fps '
          '| video janky per window (range; per s) | UI presented fps | UI 3+ vsync gaps (range) |')
    print('|' + '---|' * 11)
    mean = lambda xs: statistics.mean(xs) if xs else None
    for cfg in sorted({r['config'] for r in rows}, key=lambda c: ('native', 'nativeTexture', 'mkDefault', 'mkCopy').index(c)
                      if c in ('native', 'nativeTexture', 'mkDefault', 'mkCopy') else 9):
        for build in ('off', 'on'):
            for w in WINDOWS:
                cs = [r[w] for r in rows if r['config'] == cfg and r['build'].split('#')[0] == build and r.get(w)]
                if not cs:
                    continue
                m = lambda k: mean([c[k] for c in cs if c.get(k) is not None])
                vids = [c['video'] for c in cs if c.get('video')]
                uis = [c['ui'] for c in cs if c.get('ui')]
                vf = f"{mean([v['fps'] for v in vids]):.1f}" if vids else '–'
                vj = (f"{mean([v['janky'] for v in vids]):.1f} ({min(v['janky'] for v in vids)}–{max(v['janky'] for v in vids)}; "
                      f"{mean([v['janky'] / v['seconds'] for v in vids]):.1f}/s)") if vids else '–'
                uf = f"{mean([u['fps'] for u in uis]):.1f}" if uis else '–'
                ug = (f"{mean([u['vsyncs'][2] for u in uis]):.1f} ({min(u['vsyncs'][2] for u in uis)}–"
                      f"{max(u['vsyncs'][2] for u in uis)})") if uis else '–'
                print(f"| {cfg} | {build} | {w} | {len(cs)} | {m('flutterFps'):.1f} | {m('rasterP90Ms'):.2f} / {m('rasterP99Ms'):.2f} "
                      f"| {m('over8ms'):.0f} / {m('over16ms'):.1f} | {vf} | {vj} | {uf} | {ug} |")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('launches', nargs='+')
    ap.add_argument('--summary', action='store_true')
    ap.add_argument('--json')
    args = ap.parse_args()
    results = [analyze(*spec.split('=', 1)) for spec in args.launches]
    (print_summary if args.summary else print_tables)(results)
    if args.json:
        with open(args.json, 'w') as fh:
            json.dump(results, fh, indent=1)


if __name__ == '__main__':
    main()
