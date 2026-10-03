"""Stand-in application for the networking labs.

Usage: app.py NAME PORT [UPSTREAM_URL]

Answers every GET with one line of JSON naming the service, the port, the host
that answered and the client address the server saw. If UPSTREAM_URL is given
it is fetched on every request and embedded in the answer, so one request
exercises every hop behind this service.
"""

import http.server
import json
import socket
import sys
import urllib.request

name, port = sys.argv[1], int(sys.argv[2])
upstream = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        info = {
            "service": name,
            "port": port,
            "host": socket.gethostname(),
            "client_seen": self.client_address[0],
            "path": self.path,
        }
        # Set by a load balancer: the real client, which client_seen no longer is.
        if self.headers.get("X-Forwarded-For"):
            info["forwarded_for"] = self.headers["X-Forwarded-For"]
        if self.headers.get("Host"):
            info["host_header"] = self.headers["Host"]
        if upstream:
            try:
                with urllib.request.urlopen(upstream, timeout=3) as reply:
                    info["upstream"] = json.loads(reply.read())
            except Exception as error:
                info["upstream_error"] = f"{upstream}: {error}"
        body = (json.dumps(info) + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
