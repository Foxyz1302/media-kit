#!/usr/bin/env python3
"""SurfaceFlinger frame stats of the bench app's own layers, sampled while the app runs.

Usage: sf_latency.py <out.txt> [--interval 0.3] [--relist 4] [--max-seconds 1800]
(or start() from another script)

One `adb shell` loop on the device lists the layers, keeps only the names that contain the bench
package (filtered on the device, so no other app's layer is ever printed) and that can hold buffers
(the window surface and BLAST layers), and dumps `dumpsys SurfaceFlinger --latency <name>` for each.
Android 16 lists a layer as `RequestedLayerState{<name> parentId=...}`; --latency wants the bare name.
Every output line is written as `<host epoch ms> <line>`; `@L <name>` starts a layer's block, whose
first number is the vsync period in ns, followed by `desiredPresent actualPresent frameReady` rows
(CLOCK_MONOTONIC ns). A layer keeps only its last 128 frames, so the interval must stay well under
128 / fps. The loop ends by itself once the app's process has been gone for ~3 s, or after
--max-seconds.
"""
import argparse
import signal
import subprocess
import sys
import threading
import time

PKG = 'dev.foxyz.media_kit_bench'

LOOP = r'''
P=%(pkg)s
end=$(( $(date +%%s) + %(max)d ))
i=0
miss=0
L=""
while [ "$(date +%%s)" -lt "$end" ]; do
  if ! pidof "$P" >/dev/null; then
    miss=$((miss + 1))
    [ "$miss" -ge 10 ] && break
    sleep 0.3
    continue
  fi
  miss=0
  if [ $((i %% %(relist)d)) -eq 0 ]; then
    L=$(dumpsys SurfaceFlinger --list | grep -F "$P" | sed -e 's/^RequestedLayerState{//' -e 's/ parentId=.*//' \
      | grep -E "\(BLAST\)|^$P/")
  fi
  printf '%%s\n' "$L" | while IFS= read -r l; do
    [ -n "$l" ] || continue
    echo "@L $l"
    dumpsys SurfaceFlinger --latency "$l" | grep -v '^0[[:space:]]'
  done
  i=$((i + 1))
  sleep %(interval)s
done
echo "@END"
'''


def start(out_path, interval='0.3', relist=4, max_seconds=1800):
    """Starts the device loop; returns (adb process, pump thread). Terminate the process to stop."""
    script = LOOP % {'pkg': PKG, 'max': max_seconds, 'relist': relist, 'interval': interval}
    proc = subprocess.Popen(['adb', 'shell', script], stdout=subprocess.PIPE, text=True)

    def pump():
        with open(out_path, 'w') as out:
            for line in proc.stdout:
                out.write(f'{int(time.time() * 1000)} {line}')
                out.flush()

    thread = threading.Thread(target=pump, daemon=True)
    thread.start()
    return proc, thread


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('out')
    ap.add_argument('--interval', default='0.3')
    ap.add_argument('--relist', type=int, default=4)
    ap.add_argument('--max-seconds', type=int, default=1800)
    args = ap.parse_args()
    proc, thread = start(args.out, args.interval, args.relist, args.max_seconds)
    signal.signal(signal.SIGTERM, lambda *_: proc.terminate())
    try:
        rc = proc.wait()
    except KeyboardInterrupt:
        proc.terminate()
        rc = proc.wait()
    thread.join(timeout=5)
    return rc


if __name__ == '__main__':
    sys.exit(main())
