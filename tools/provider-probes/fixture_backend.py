"""Local HTTP contract fixture, NOT a live slskd/Soulseek backend."""
import contextlib
import http.server
import json
from pathlib import Path
import threading
import uuid


class State:
    def __init__(self, root):
        self.root = Path(root)
        self.search_id = None
        self.polls = 0
        self.batch = None
        self.transfer_id = str(uuid.uuid4())
        self.complete = True
        self.cancelled = False
        self.deleted = False
        self.requests = []
        self.key = "fixture-key"
        self.error = None


@contextlib.contextmanager
def backend(root):
    state = State(root)

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def handle_request(self):
            state.requests.append((self.command, self.path))
            if self.headers.get("X-API-Key") != state.key:
                self.send(401, {"message": "do-not-persist-response"})
                return
            if state.error:
                self.send(state.error, {"message": "credential-response-must-not-leak"})
                return
            path = self.path.removeprefix("/api/v0/")
            body = None
            if self.command == "POST":
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
            if path == "application/version":
                self.send(200, "0.26.2-fixture")
            elif path == "server":
                self.send(200, {"isConnected": True})
            elif self.command == "POST" and path == "searches":
                state.search_id = body["id"]
                self.send(200, {"id": state.search_id, "responseCount": 0})
            elif path == f"searches/{state.search_id}/responses":
                state.polls += 1
                self.send(200, [{"username": "fixture-peer", "files": []}] * (state.polls - 1))
            elif self.command == "PUT" and path == f"searches/{state.search_id}":
                state.cancelled = True
                self.send(200, None)
            elif self.command == "DELETE" and path == f"searches/{state.search_id}":
                state.deleted = True
                self.send(204, None)
            elif self.command == "POST" and path == "transfers/downloads/batches":
                state.batch = body["id"]
                size = body["files"][0]["size"]
                if state.complete:
                    (state.root / "fixture.wav").write_bytes(b"D" * size)
                self.send(201, {"batch": {"id": state.batch, "transfers": [{"id": state.transfer_id}]}, "failures": []})
            elif self.command == "GET" and path == "transfers/downloads/fixture-peer":
                self.send(200, [])
            elif self.command == "GET" and path == f"transfers/downloads/fixture-peer/{state.transfer_id}":
                self.send(200, {"id": state.transfer_id, "batchId": state.batch, "filename": "peer\\fixture.wav", "size": 64,
                               "bytesTransferred": 64 if state.complete else 0,
                               "state": "Completed, Succeeded" if state.complete else "Queued"})
            elif self.command == "DELETE" and path == f"transfers/downloads/fixture-peer/{state.transfer_id}":
                state.cancelled = True
                self.send(204, None)
            else:
                self.send(404, {})

        def send(self, status, value):
            data = b"" if value is None else json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            if status == 429:
                self.send_header("Retry-After", "12")
            self.end_headers()
            self.wfile.write(data)

        do_GET = do_POST = do_PUT = do_DELETE = handle_request

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}", state
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
