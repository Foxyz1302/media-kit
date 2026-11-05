import json, re, sys
pre=sys.argv[1]; names=sys.argv[2:] or None
recs=[json.loads(l) for l in open(pre+'.jsonl')]
probe=[]
for line in open(pre+'-logcat.txt', errors='replace'):
    m=re.match(r'\s*([\d.]+)\s+\d+\s+\d+ I bufprobe: f (\S+) (\d+) (\d+) (-?\d+)', line)
    if m: probe.append((float(m[1]), int(m[3]), int(m[4]), int(m[5])))
for r in recs:
    if not r.get('name','').startswith('start4k'): continue
    if names and not any(n in r['name'] for n in names): continue
    o=r['openEpochMs']/1000
    fp=[p for p in probe if o<=p[0]<=o+3.2]
    if not fp: continue
    t0=fp[0][1]
    row=[]
    for b in range(0,2800,250):
        inb=[(a,b2) for a,b2 in zip(fp,fp[1:]) if b<= (b2[1]-t0)/1e6 < b+250]
        arr=[(y[1]-x[1])/1e6 for x,y in inb]; ts=[(y[2]-x[2])/1e6 for x,y in inb]
        row.append(f"{len(inb):2d}f a{sum(g>25 for g in arr)} t{sum(g>25 for g in ts)}")
    print(r['name'][8:], ' | '.join(row))
