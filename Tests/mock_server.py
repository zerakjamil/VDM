import http.server
import socketserver
import re
import sys

DATA = b"X" * (1024 * 1024 * 4)  # 4 MB payload

class RangeServer(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_HEAD(self):
        if "token=expired" in self.path:
            self.send_response(403)
            self.end_headers()
            return

        self.send_response(200)
        self.send_header("Content-Length", str(len(DATA)))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Disposition", 'attachment; filename="test_rom.bin"')
        self.end_headers()

    def do_GET(self):
        if "token=expired" in self.path:
            self.send_response(403)
            self.end_headers()
            return

        range_header = self.headers.get("Range")
        if range_header:
            m = re.match(r"bytes=(\d+)-(\d+)", range_header)
            if m:
                start = int(m.group(1))
                end = int(m.group(2))
                chunk = DATA[start:end+1]
                self.send_response(206)
                self.send_header("Content-Range", f"bytes {start}-{end}/{len(DATA)}")
                self.send_header("Content-Length", str(len(chunk)))
                self.send_header("Accept-Ranges", "bytes")
                self.end_headers()
                self.wfile.write(chunk)
                return

        self.send_response(200)
        self.send_header("Content-Length", str(len(DATA)))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        self.wfile.write(DATA)

port = int(sys.argv[1]) if len(sys.argv) > 1 else 18080
server = socketserver.TCPServer(("127.0.0.1", port), RangeServer)
server.serve_forever()
