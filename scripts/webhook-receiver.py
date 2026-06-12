#!/usr/bin/env python
"""Tiny test webhook receiver: logs every request (headers + body) to webhook-received.log.
Used to verify the A2A connector delivers push notifications. Run: python webhook-receiver.py [port]"""
import sys, datetime
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = 'webhook-received.log'  # written to the current working directory (gitignored)
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9999

class H(BaseHTTPRequestHandler):
    def _handle(self):
        n = int(self.headers.get('content-length', 0) or 0)
        body = self.rfile.read(n).decode('utf-8', 'replace') if n else ''
        with open(LOG, 'a', encoding='utf-8') as f:
            f.write("=== %s %s %s ===\n" % (datetime.datetime.now().isoformat(), self.command, self.path))
            f.write("headers: %s\n" % dict(self.headers))
            f.write("body: %s\n\n" % body)
        self.send_response(200); self.send_header('content-type','application/json'); self.end_headers()
        self.wfile.write(b'{"ok":true}')
    do_POST = _handle
    do_GET = _handle
    def log_message(self, *a): pass

print("webhook receiver on http://127.0.0.1:%d -> %s" % (PORT, LOG))
HTTPServer(('127.0.0.1', PORT), H).serve_forever()
