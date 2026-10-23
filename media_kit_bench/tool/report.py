#!/usr/bin/env python3
"""Markdown report for a v3 results file, optionally compared with a v2 baseline.

Usage: report.py <results.jsonl>... [--codecs <logcat.txt>] [--baseline <results-v2.jsonl>]

--codecs takes `adb logcat -v epoch --pid=<bench pid>` lines filtered to codec component names and
VideoOutputManager.setSurfaceSize; the decoder per run and surface changes per window come from it.
"""
import argparse
import json
import re

NATIVE = ('native', 'nativeTexture')
CLIP_SECONDS = 20  # tool/encode_clips*.sh
CODEC = re.compile(r'(c2\.(?:qti|android|exynos|mtk)\.[a-z0-9.-]+?\.decoder|OMX\.[A-Za-z0-9.]+?\.decoder)')


def load(path):
    return [json.loads(line) for line in open(path)]


def codec_lines(path):
    out = []
    for line in open(path):
        parts = line.split()
        try:
            t = float(parts[0]) * 1000
        except (ValueError, IndexError):
            continue
        if 'setSurfaceSize' in line:
            out.append((t, 'setSurfaceSize'))
        for name in CODEC.findall(line):
            out.append((t, name))
    return out


def until_eof(samples):
    """Animated-window motion before the clip ends: the window can run into the end of the 20 s clip,
    where mpv holds the last position and the native plugin reports 0."""
    s = []
    for e in samples:
        if e[1] >= CLIP_SECONDS - 0.1 or (s and s[-1][1] > CLIP_SECONDS - 1 and e[1] < 0.5):
            break
        s.append(e)
    if len(s) < 2:
        s = samples
    back = sum(1 for p, q in zip(s, s[1:]) if q[1] - p[1] < -0.05)
    stall, last = 0, s[0][0]
    for p, q in zip(s, s[1:]):
        if q[1] - p[1] > 0.001:
            last = q[0]
        else:
            stall = max(stall, q[0] - last)
    span = (s[-1][0] - s[0][0]) / 1000
    rate = round((s[-1][1] - s[0][1]) / span, 2) if span > 0 else None
    return rate, back, int(stall), round(span, 1)


def surface_events(lines, a, b):
    return sum(1 for t, n in lines if n == 'setSurfaceSize' and a <= t <= b)


def decoders(run, lines):
    a, b = run.get('runStartEpochMs', 0), run.get('runEndEpochMs', 0) + 1500
    names = sorted({n for t, n in lines if a <= t <= b and n.startswith(('c2.', 'OMX.'))})
    return ','.join(n.replace('c2.qti.', 'qti.').replace('c2.android.', 'sw:').replace('.decoder', '') for n in names)


def delta(run, key, a, b):
    c = run.get('counters') or {}
    try:
        return int(float(c[b][key])) - int(float(c[a][key]))
    except (KeyError, ValueError, TypeError):
        return None


def warn_counts(run):
    logs = run.get('mpvLog') or []
    return {
        'invalidTs': sum('Invalid video timestamp' in s for s in logs),
        'fileCache': sum('Failed to create file cache' in s for s in logs),
        'osc': sum('_setProperty(osc' in s for s in logs),
    }


def fmt(*vals):
    return '/'.join('–' if v is None else str(v) for v in vals)


def short_clip(name):
    return name.rsplit('.', 1)[0]


def row(run, lines):
    p, o = run.get('plain') or {}, run.get('overlay') or {}
    info = run.get('info') or {}
    native = run['config'] in NATIVE
    dec = decoders(run, lines) if lines else ''
    hw = 'native' if native else info.get('hwdec-current') or 'no'
    w = warn_counts(run)
    jank = lambda win: f"{100 * win.get('over16ms', 0) / max(1, win.get('flutterFrames', 0)):.0f}%" if win else '–'
    if not run.get('ok'):
        return f"| {short_clip(run['clip'])} | {run['config']} | **FAILED**: {run.get('error')} | | | | | {hw} {dec} | | |"
    return (
        f"| {short_clip(run['clip'])} | {run['config']} | {run.get('ttffMs')} | {run.get('timeToMotionMs')} "
        f"| {fmt(p.get('playbackRate'), o.get('playbackRate'))} "
        f"| {'–' if native else fmt(delta(run, 'frame-drop-count', 'start', 'plainEnd'), delta(run, 'frame-drop-count', 'plainEnd', 'overlayEnd'))} "
        f"| {'–' if native else fmt(delta(run, 'decoder-frame-drop-count', 'start', 'overlayEnd'), delta(run, 'vo-delayed-frame-count', 'start', 'overlayEnd'))} "
        f"| {hw} {dec} | {fmt(p.get('rasterP90Ms'), p.get('rasterP99Ms'))} / {fmt(o.get('rasterP90Ms'), o.get('rasterP99Ms'))} "
        f"| {jank(p)}/{jank(o)} | {'–' if native else w['invalidTs']} |"
    )


HEADER = ('| clip | config | TTFF ms | motion ms | rate P/O | mpv drops P/O | dec-drop/vo-delayed | hwdec / decoder '
          '| raster p90/p99 plain / overlay (ms) | jank P/O | invalid-ts |\n|' + '---|' * 11)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('results', nargs='+')
    ap.add_argument('--codecs')
    ap.add_argument('--baseline')
    args = ap.parse_args()
    recs = [r for path in args.results for r in load(path)]
    lines = codec_lines(args.codecs) if args.codecs else []
    runs = [r for r in recs if r.get('type') == 'run']
    for link in (r for r in recs if r.get('type') == 'link'):
        print(f"Link test: {link['clip']} {link['bytes'] / 1e6:.1f} MB in {link['ms']} ms = "
              f"**{link['MBps']} MB/s ({link['Mbps']} Mbit/s)**{' error: ' + link['error'] if link.get('error') else ''}\n")
    groups = [('1080p / 1440p', [r for r in runs if '2160p' not in r['clip']]),
              ('4K (2160p)', [r for r in runs if '2160p' in r['clip']])]
    for title, rs in groups:
        if not rs:
            continue
        print(f"### {title}, {rs[0].get('pass')} {rs[0].get('viewSize')}\n\n{HEADER}")
        for r in rs:
            print(row(r, lines))
        print()
    anim = [r for r in runs if r.get('animated')]
    if anim:
        print('### Animated window: video moving between full screen and a 30% mini-player, 1 transition/s\n')
        print('Rate, backward jumps and stalls count only the part of the window before the clip ends (s measured).\n')
        print('| clip | config | Flutter fps | raster p90/p99 (ms) | frames >8.3 / >16.7 ms | mpv drops | rate | backward jumps '
              '| longest stall ms | s measured | surface changes |\n|' + '---|' * 11)
        for r in anim:
            a = r['animated']
            drops = None if r['config'] in NATIVE else delta(r, 'frame-drop-count', 'overlayEnd', 'animatedEnd')
            rate, back, stall, span = until_eof(a['samples'])
            stall = f"{stall}" + (' (500 ms position steps)' if r['config'] in NATIVE else '')
            surf = surface_events(lines, a['startEpochMs'], a['endEpochMs']) if lines else '–'
            print(f"| {short_clip(r['clip'])} | {r['config']} | {a.get('flutterFps')} | {fmt(a.get('rasterP90Ms'), a.get('rasterP99Ms'))} "
                  f"| {a.get('over8ms')}/{a.get('over16ms')} | {'–' if drops is None else drops} | {rate} "
                  f"| {back} | {stall} | {span} | {'–' if r['config'] in NATIVE else surf} |")
        print()
    totals = {k: sum(warn_counts(r)[k] for r in runs if r['config'] not in NATIVE) for k in ('invalidTs', 'fileCache', 'osc')}
    mk = sum(1 for r in runs if r['config'] not in NATIVE)
    back = sum(1 for r in runs for w in ('plain', 'overlay') if ((r.get(w) or {}).get('playbackRate') or 0) < 0)
    print(f"media_kit runs: {mk}; 'Invalid video timestamp': {totals['invalidTs']}; "
          f"'Failed to create file cache': {totals['fileCache']}; osc property errors: {totals['osc']}; "
          f"windows with a negative rate (backward jump): {back}\n")
    if args.baseline:
        base = [r for r in load(args.baseline) if r.get('type') == 'run' and r.get('pass') == 'portrait']
        print('### Before / after (portrait), baseline = stock upstream main\n')
        print('| clip | before: default (auto-safe → copy) rate P/O, invalid-ts | after: default (zero-copy) rate P/O, invalid-ts '
              '| after: copy rate P/O | native rate P/O | nativeTexture rate P/O |\n|---|---|---|---|---|---|')
        for clip in sorted({r['clip'] for r in base}):
            def pick(rows, cfg):
                return next((r for r in rows if r['clip'] == clip and r['config'] == cfg), None)

            def rate(r):
                if not r:
                    return '–'
                if not r.get('ok'):
                    return 'FAILED'
                return fmt((r.get('plain') or {}).get('playbackRate'), (r.get('overlay') or {}).get('playbackRate'))
            b, d, c, n = pick(base, 'mkDefault'), pick(runs, 'mkDefault'), pick(runs, 'mkCopy'), pick(runs, 'native')
            nt = pick(runs, 'nativeTexture')
            print(f"| {short_clip(clip)} | {rate(b)}, {warn_counts(b)['invalidTs'] if b else '–'} "
                  f"| {rate(d)}, {warn_counts(d)['invalidTs'] if d else '–'} | {rate(c)} | {rate(n)} | {rate(nt)} |")


if __name__ == '__main__':
    main()
