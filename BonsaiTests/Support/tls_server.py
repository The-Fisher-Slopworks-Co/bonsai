import http.server
import ssl
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'{"id": 1, "username": "tls", "name": "TLS", "avatar_url": null}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


cert, key, portfile = sys.argv[1:4]
server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
server.socket = ctx.wrap_socket(server.socket, server_side=True)
with open(portfile, "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
