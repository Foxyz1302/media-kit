#!/usr/bin/env python3
"""One bench launch on the connected phone, with everything it produces.

Usage: run_launch.py <apk> <out-prefix> <clips-dir> [--timeout 900] [--sf] [--stop-app]

- serves <clips-dir> and collects the results into <out-prefix>.jsonl (bench_server.py over adb reverse);
- wakes the screen and refuses to start while the keyguard shows (it never unlocks anything);
- installs the APK over the previous one (`install -r`: the old app keeps the screen on until the new one
  starts, so the phone does not time out and lock between launches), launches it and records
  `adb logcat --pid=<bench pid>` to <out-prefix>-logcat.txt;
- with --sf, samples SurfaceFlinger frame stats of the bench app's own layers to <out-prefix>-sf.txt;
- waits for the done record, the app's exit or the timeout, then stops all of it and removes the reverse
  rule. The finished app stays in the foreground unless --stop-app.
"""
import argparse
import os
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sf_latency  # noqa: E402

PKG = sf_latency.PKG
PORT = 8787
SERVER = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'bench_server.py')


def adb(*a, check=True):
    return subprocess.run(['adb', *a], capture_output=True, text=True, check=check).stdout.strip()


def device_state():
    keyguard = adb('shell', 'dumpsys window | grep -E "isKeyguardShowing|mDreamingLockscreen"', check=False)
    battery = adb('shell', 'dumpsys battery | grep -E "^ *temperature:"', check=False)
    thermal = adb('shell', 'dumpsys thermalservice | grep -E "^Thermal Status"', check=False)
    return ' '.join(keyguard.split()), ' '.join(battery.split()), ' '.join(thermal.split())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('apk')
    ap.add_argument('prefix')
    ap.add_argument('clips')
    ap.add_argument('--timeout', type=float, default=900)
    ap.add_argument('--sf', action='store_true')
    ap.add_argument('--stop-app', action='store_true')
    args = ap.parse_args()
    res = args.prefix + '.jsonl'
    procs = []
    try:
        adb('shell', 'input', 'keyevent', 'KEYCODE_WAKEUP')
        time.sleep(1)
        keyguard, battery, thermal = device_state()
        print('before:', keyguard, '|', battery, '|', thermal, flush=True)
        if 'isKeyguardShowing=true' in keyguard or 'mDreamingLockscreen=true' in keyguard:
            sys.exit('keyguard is showing: not launching (never unlock)')
        srv_log = open(args.prefix + '-server.log', 'w')
        procs.append(subprocess.Popen(['python3', SERVER, args.clips, res, str(PORT)], stdout=srv_log, stderr=srv_log))
        adb('reverse', f'tcp:{PORT}', f'tcp:{PORT}')
        print('install:', adb('install', '-r', args.apk).splitlines()[-1], flush=True)
        adb('shell', 'am', 'start', '-n', f'{PKG}/.MainActivity')
        pid = ''
        for _ in range(80):
            pid = adb('shell', 'pidof', PKG, check=False)
            if pid:
                break
            time.sleep(0.25)
        if not pid:
            sys.exit('app did not start')
        print('pid', pid, flush=True)
        log = open(args.prefix + '-logcat.txt', 'w')
        procs.append(subprocess.Popen(['adb', 'logcat', '-v', 'epoch', f'--pid={pid}'], stdout=log, stderr=subprocess.DEVNULL))
        if args.sf:
            procs.append(sf_latency.start(args.prefix + '-sf.txt', max_seconds=int(args.timeout) + 60)[0])
        end = time.time() + args.timeout
        outcome = 'TIMEOUT'
        misses = 0
        while time.time() < end:
            if os.path.exists(res) and '"type": "done"' in open(res).read():
                outcome = 'DONE'
                break
            # Wireless adb drops a call now and then; an empty pidof alone is not an exit.
            misses = misses + 1 if adb('shell', 'pidof', PKG, check=False) != pid else 0
            if misses >= 3:
                outcome = 'APP EXITED'
                break
            threading.Event().wait(2)
        threading.Event().wait(1.5)
        print(outcome, flush=True)
        print('after:', ' | '.join(device_state()[1:]), flush=True)
    finally:
        for p in reversed(procs):
            p.terminate()
        for p in procs:
            try:
                p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                p.kill()
        if args.stop_app:
            adb('shell', 'am', 'force-stop', PKG, check=False)
        adb('reverse', '--remove', f'tcp:{PORT}', check=False)


if __name__ == '__main__':
    main()
