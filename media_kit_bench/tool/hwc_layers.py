#!/usr/bin/env python3
"""Snapshots of how SurfaceFlinger composites the bench app's own layers (HWC overlay plane or GPU).

Usage: hwc_layers.py <out.txt> <seconds> [--every 1.5]

Each snapshot runs `dumpsys SurfaceFlinger` on the device and keeps, on the device, only the display
HAL's one-line-per-layer rows (`layer: <id> name: <name> z: .. composition: <requested>/<actual> ..`)
whose layer name is the bench app's window surface or one of its SurfaceViews. Nothing else from the
dump is printed. A full dump costs SurfaceFlinger some time, so this is a diagnostic to run apart from
measured launches.
"""
import argparse
import subprocess
import threading
import time

FILTER = r'''dumpsys SurfaceFlinger | grep -E '^layer: [0-9]+ name: ([0-9a-f]+ SurfaceView\[)?dev\.foxyz\.media_kit_bench/' | cut -c1-400'''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('out')
    ap.add_argument('seconds', type=float)
    ap.add_argument('--every', type=float, default=1.5)
    args = ap.parse_args()
    end = time.time() + args.seconds
    with open(args.out, 'w') as out:
        while time.time() < end:
            t0 = time.time()
            res = subprocess.run(['adb', 'shell', FILTER], capture_output=True, text=True)
            out.write(f'@T {int(t0 * 1000)} {int(time.time() * 1000)}\n{res.stdout}')
            out.flush()
            threading.Event().wait(max(0.0, args.every - (time.time() - t0)))


if __name__ == '__main__':
    main()
