#!/usr/bin/env python3
import http.server
import pathlib
import signal
import socketserver
import sys


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass


class LoopbackServer(http.server.ThreadingHTTPServer):
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address
        self.server_name = host
        self.server_port = port


root = pathlib.Path(sys.argv[1]).resolve()
port_file = pathlib.Path(sys.argv[2])
port = int(sys.argv[3])
handler = lambda *args, **kwargs: QuietHandler(*args, directory=str(root), **kwargs)
server = LoopbackServer(("127.0.0.1", port), handler)
port_file.write_text(str(server.server_port), encoding="utf-8")


def stop(_signal, _frame):
    server.server_close()
    raise SystemExit(0)


signal.signal(signal.SIGTERM, stop)
try:
    server.serve_forever()
finally:
    server.server_close()
