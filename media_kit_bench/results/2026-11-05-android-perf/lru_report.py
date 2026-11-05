import json, re, sys
pre=sys.argv[1]
probe=[]
for line in open(pre+'-logcat.txt', errors='replace'):
    m=re.match(r'\s*([\d.]+)\s+\d+\s+\d+ I bufprobe: f (\S+) (\d+) (\d+) (-?\d+)', line)
    if m: probe.append((float(m[1]), m[2], int(m[5])))
for l in open(pre+'.jsonl'):
    r=json.loads(l)
    if 'plain' not in r: continue
    print(r.get('clip'), r.get('config'), r.get('pass'))
    for w in ('plain','overlay','animated'):
        st=r.get(w)
        if not st: continue
        # epoch windows: approximate from runStartEpochMs is coarse; use counts of ids per 1s over whole run instead
        print(f"  {w}: raster p90 {st.get('rasterP90Ms')} p99 {st.get('rasterP99Ms')} fps {st.get('flutterFps')}")
    a,b=r['runStartEpochMs']/1000, r['runEndEpochMs']/1000
    fp=[p for p in probe if a<=p[0]<=b]
    win=[]
    t=a
    while t<b:
        ids={p[2] for p in fp if t<=p[0]<t+1}
        win.append(len(ids)); t+=1
    print('  distinct buffer ids per 1 s:', win, 'readers', len({p[1] for p in fp}))
