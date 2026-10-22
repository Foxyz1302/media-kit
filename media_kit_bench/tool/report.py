#!/usr/bin/env python3
"""Markdown report for a v3 results file, optionally compared with a v2 baseline.

Usage: report.py <results.jsonl> [--codecs <codecs.log>] [--baseline <results-v2.jsonl>]
"""
import argparse
import json


def load(path):
    return [json.loads(line) for line in open(path)]


def codec_lines(path):
    out = []
    for line in open(path):
        parts = line.split()
        try:
            out.append((float(parts[0]) * 1000, parts[-1]))
        except (ValueError, IndexError):
            pass
    return out


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
    native = run['config'] == 'native'
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
    ap.add_argument('results')
    ap.add_argument('--codecs')
    ap.add_argument('--baseline')
    args = ap.parse_args()
    recs = load(args.results)
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
    totals = {k: sum(warn_counts(r)[k] for r in runs if r['config'] != 'native') for k in ('invalidTs', 'fileCache', 'osc')}
    mk = sum(1 for r in runs if r['config'] != 'native')
    back = sum(1 for r in runs for w in ('plain', 'overlay') if ((r.get(w) or {}).get('playbackRate') or 0) < 0)
    print(f"media_kit runs: {mk}; 'Invalid video timestamp': {totals['invalidTs']}; "
          f"'Failed to create file cache': {totals['fileCache']}; osc property errors: {totals['osc']}; "
          f"windows with a negative rate (backward jump): {back}\n")
    if args.baseline:
        base = [r for r in load(args.baseline) if r.get('type') == 'run' and r.get('pass') == 'portrait']
        print('### Before / after (portrait), baseline = stock upstream main\n')
        print('| clip | before: default (auto-safe → copy) rate P/O, invalid-ts | after: default (zero-copy) rate P/O, invalid-ts '
              '| after: copy rate P/O | native rate P/O |\n|---|---|---|---|---|')
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
            print(f"| {short_clip(clip)} | {rate(b)}, {warn_counts(b)['invalidTs'] if b else '–'} "
                  f"| {rate(d)}, {warn_counts(d)['invalidTs'] if d else '–'} | {rate(c)} | {rate(n)} |")


if __name__ == '__main__':
    main()
