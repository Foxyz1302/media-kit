#!/usr/bin/env python3
"""Range-capable clip server + result sink for the media_kit Android benchmark.

Usage: bench-server.py <clips_dir> <results.jsonl> <port>
"""
import http.server
import json
import os
import re
import sys
import time

CLIPS, OUT, PORT = sys.argv[1], sys.argv[2], int(sys.argv[3])


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, fmt, *args):
        sys.stderr.write('%s %s\n' % (time.strftime('%H:%M:%S'), fmt % args))

    def do_HEAD(self):
        self._serve(head=True)

    def do_GET(self):
        self._serve(head=False)

    def _serve(self, head):
        path = self.path.split('?', 1)[0]
        if not path.startswith('/clips/'):
            self.send_error(404)
            return
        name = os.path.basename(path)
        file_path = os.path.join(CLIPS, name)
        if not os.path.isfile(file_path):
            self.send_error(404)
            return
        size = os.path.getsize(file_path)
        ctype = 'video/webm' if name.endswith('.webm') else 'video/mp4'
        start, end, status = 0, size - 1, 200
        rng = self.headers.get('Range')
        if rng:
            m = re.match(r'bytes=(\d*)-(\d*)', rng.strip())
            if m:
                s, e = m.group(1), m.group(2)
                if s == '' and e != '':
                    start = max(0, size - int(e))
                else:
                    start = int(s or 0)
                    end = int(e) if e else size - 1
                end = min(end, size - 1)
                if start >= size or start > end:
                    self.send_response(416)
                    self.send_header('Content-Range', f'bytes */{size}')
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
                status = 206
        length = end - start + 1
        self.send_response(status)
        self.send_header('Content-Type', ctype)
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(length))
        if status == 206:
            self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        self.end_headers()
        if head:
            return
        with open(file_path, 'rb') as f:
            f.seek(start)
            remaining = length
            try:
                while remaining > 0:
                    chunk = f.read(min(1 << 20, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
            except (BrokenPipeError, ConnectionResetError):
                pass

    def do_POST(self):
        if self.path != '/result':
            self.send_error(404)
            return
        if 'chunked' in (self.headers.get('Transfer-Encoding') or '').lower():
            body = b''
            while True:
                size = int(self.rfile.readline().split(b';', 1)[0].strip() or b'0', 16)
                if size == 0:
                    while self.rfile.readline() not in (b'\r\n', b'\n', b''):
                        pass
                    break
                body += self.rfile.read(size)
                self.rfile.readline()
        else:
            body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        try:
            obj = json.loads(body)
        except ValueError:
            obj = {'raw': body.decode('utf-8', 'replace')}
        obj['_receivedEpochMs'] = int(time.time() * 1000)
        with open(OUT, 'a') as f:
            f.write(json.dumps(obj) + '\n')
        self.send_response(204)
        self.send_header('Content-Length', '0')
        self.end_headers()


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True


if __name__ == '__main__':
    srv = Server(('127.0.0.1', PORT), Handler)
    print(f'serving {CLIPS} on 127.0.0.1:{PORT}', flush=True)
    srv.serve_forever()
