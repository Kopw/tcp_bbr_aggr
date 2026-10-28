# 临时 A/B 测速端：GET /?cc=<拥塞算法>&n=<字节数>，按请求给这条连接设置拥塞控制后发送随机数据
import http.server, socketserver, os, socket, urllib.parse

BLK = os.urandom(1 << 20)


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        cc = q.get('cc', ['bbr'])[0]
        n = int(q.get('n', ['104857600'])[0])
        try:
            self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_CONGESTION, cc.encode())
        except OSError as e:
            self.send_error(400, str(e))
            return
        self.send_response(200)
        self.send_header('Content-Length', str(n))
        self.end_headers()
        try:
            while n > 0:
                k = min(n, len(BLK))
                self.wfile.write(BLK[:k])
                n -= k
        except Exception:
            pass

    def log_message(self, *a):
        pass


socketserver.ThreadingTCPServer.allow_reuse_address = True
socketserver.ThreadingTCPServer(('0.0.0.0', 18090), H).serve_forever()
