"""WDA adapter session reuse/recreation against a fake WebDriverAgent (Python 3)."""

import json
import os
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import wda_adapter  # noqa: E402


class FakeWDA(BaseHTTPRequestHandler):
    sessions = set()
    created = 0

    def log_message(self, *args):
        pass

    def _send(self, status, payload):
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):  # noqa: N802
        if self.path == "/status":
            return self._send(200, {"value": {"ready": True, "message": "ok"}, "sessionId": None})
        parts = self.path.strip("/").split("/")
        if parts[0] == "session" and len(parts) >= 2:
            if parts[1] not in FakeWDA.sessions:
                return self._send(404, {"value": {"error": "invalid session id", "message": "gone"}})
            if len(parts) == 2:
                return self._send(200, {"value": {}, "sessionId": parts[1]})
            if parts[2] == "source":
                return self._send(200, {"value": '<App name="Settings"><Cell name="Wi-Fi"/></App>'})
        return self._send(404, {"value": {"error": "unknown command"}})

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length:
            self.rfile.read(length)
        if self.path == "/session":
            FakeWDA.created += 1
            sid = "S%d" % FakeWDA.created
            FakeWDA.sessions.add(sid)
            return self._send(200, {"value": {"sessionId": sid}, "sessionId": sid})
        return self._send(404, {"value": {"error": "unknown command"}})


class AdapterSessionTests(unittest.TestCase):
    def setUp(self):
        FakeWDA.sessions = set()
        FakeWDA.created = 0
        self.server = HTTPServer(("127.0.0.1", 0), FakeWDA)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.state = wda_adapter.AdapterState("", "http://127.0.0.1:%d" % self.server.server_address[1])

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def test_creates_then_reuses_session(self):
        self.assertEqual(self.state.ensure_session(), (True, "session created"))
        self.assertEqual(self.state.session_id, "S1")
        self.assertEqual(self.state.ensure_session(), (True, "session reused"))
        self.assertEqual(FakeWDA.created, 1)

    def test_recreates_expired_session_on_request(self):
        self.state.ensure_session()
        FakeWDA.sessions.clear()  # WDA restarted / session expired
        result = self.state.observe("look")
        self.assertEqual(result["status"], "completed")
        self.assertEqual(self.state.session_id, "S2")
        labels = [c["label"] for c in result["observation"]["controls"]]
        self.assertEqual(labels, ["Settings", "Wi-Fi"])

    def test_unreachable_wda(self):
        state = wda_adapter.AdapterState("", "http://127.0.0.1:1")
        ok, message = state.ensure_session()
        self.assertFalse(ok)
        self.assertIn("not reachable", message)


if __name__ == "__main__":
    unittest.main()
