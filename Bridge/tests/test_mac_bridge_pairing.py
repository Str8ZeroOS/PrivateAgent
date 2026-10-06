"""Tests for the bridge pairing handshake (python3 -m unittest discover Bridge/tests)."""

import json
import os
import shutil
import sys
import tempfile
import threading
import unittest

try:
    from urllib.request import Request, urlopen
    from urllib.error import HTTPError
except ImportError:  # Python 2
    from urllib2 import Request, urlopen, HTTPError

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import mac_bridge_helper as bridge  # noqa: E402


class FakeClock(object):
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


class PairingManagerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.path = os.path.join(self.tmp, "bridge_devices.json")
        self.lines = []
        self.clock = FakeClock()
        self.manager = bridge.PairingManager(
            enabled=True, state_path=self.path, ttl=300,
            printer=self.lines.append, clock=self.clock, advertise=("192.168.12.141", 8765),
        )

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_code_is_six_digits_and_printed_with_link(self):
        code = self.manager.code
        self.assertEqual(len(code), 6)
        self.assertTrue(code.isdigit())
        printed = "\n".join(self.lines)
        self.assertIn("%s %s" % (code[:3], code[3:]), printed)
        self.assertIn("privateagent://pair?host=192.168.12.141&port=8765&code=%s" % code, printed)

    def test_successful_pair_issues_token_and_stores_only_hash(self):
        code = self.manager.code
        status, payload = self.manager.attempt(code, "Jay's iPhone", remote="192.168.12.50")
        self.assertEqual(status, 200)
        token = payload["token"]
        self.assertGreaterEqual(len(token), 64)
        self.assertTrue(self.manager.is_authorized_token(token))
        self.assertFalse(self.manager.is_authorized_token(token + "x"))
        with open(self.path) as handle:
            stored = handle.read()
        self.assertNotIn(token, stored)
        self.assertIn(bridge.token_hash(token), stored)
        self.assertNotIn(token, "\n".join(self.lines))
        # code is single use and was rotated
        self.assertNotEqual(self.manager.code, code)
        status, _ = self.manager.attempt(code, "again")
        self.assertIn(status, (403,))

    def test_pairing_survives_restart(self):
        status, payload = self.manager.attempt(self.manager.code, "iPhone")
        self.assertEqual(status, 200)
        reloaded = bridge.PairingManager(enabled=True, state_path=self.path, printer=lambda _: None)
        self.assertTrue(reloaded.is_authorized_token(payload["token"]))
        reloaded.forget_all()
        again = bridge.PairingManager(enabled=True, state_path=self.path, printer=lambda _: None)
        self.assertFalse(again.is_authorized_token(payload["token"]))

    def test_wrong_code_counts_down_then_rotates(self):
        original = self.manager.code
        wrong = "000000" if original != "000000" else "111111"
        for remaining in (4, 3, 2, 1):
            status, payload = self.manager.attempt(wrong, "x")
            self.assertEqual(status, 403)
            self.assertEqual(payload["attemptsRemaining"], remaining)
        status, payload = self.manager.attempt(wrong, "x")
        self.assertEqual(payload["attemptsRemaining"], 0)
        self.assertNotEqual(self.manager.code, original)

    def test_locks_after_too_many_failures(self):
        for _ in range(bridge.MAX_TOTAL_PAIRING_FAILURES - 1):
            wrong = "000000" if self.manager.code != "000000" else "111111"
            status, _ = self.manager.attempt(wrong, "x")
            self.assertEqual(status, 403)
        wrong = "000000" if self.manager.code != "000000" else "111111"
        status, payload = self.manager.attempt(wrong, "x")
        self.assertEqual(status, 429)
        self.assertEqual(self.manager.status(), "locked")
        status, payload = self.manager.attempt(self.manager.code, "x")
        self.assertEqual((status, payload["error"]), (429, "pairing_locked"))

    def test_expired_code(self):
        code = self.manager.code
        self.clock.now += 301
        status, payload = self.manager.attempt(code, "x")
        self.assertEqual((status, payload["error"]), (410, "code_expired"))
        self.assertNotEqual(self.manager.code, code)

    def test_tick_rotates_on_expiry(self):
        code = self.manager.code
        self.manager.tick()
        self.assertEqual(self.manager.code, code)
        self.clock.now += 301
        self.manager.tick()
        self.assertNotEqual(self.manager.code, code)

    def test_malformed_and_disabled(self):
        self.assertEqual(self.manager.attempt("12345", "x")[0], 400)
        self.assertEqual(self.manager.attempt(None, "x")[0], 400)
        self.assertEqual(self.manager.attempt("12a456", "x")[0], 400)
        disabled = bridge.PairingManager(enabled=False, printer=lambda _: None)
        self.assertEqual(disabled.attempt("123456", "x"), (403, {"error": "pairing_disabled"}))
        self.assertEqual(disabled.status(), "disabled")


class HTTPPairingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.lines = []
        pairing = bridge.PairingManager(
            enabled=True, state_path=os.path.join(self.tmp, "d.json"), printer=self.lines.append,
        )
        self.server = bridge.ThreadingHTTPServer(("127.0.0.1", 0), bridge.Handler)
        self.server.state = bridge.BridgeState("legacy-static-token-123", pairing=pairing)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.daemon = True
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        shutil.rmtree(self.tmp)

    def call(self, method, path, body=None, token=None):
        data = None if body is None else json.dumps(body).encode("utf-8")
        request = Request("http://127.0.0.1:%d%s" % (self.port, path), data=data)
        request.get_method = lambda: method
        if data is not None:
            request.add_header("Content-Type", "application/json")
        if token is not None:
            request.add_header("Authorization", "Bearer %s" % token)
        try:
            response = urlopen(request, timeout=5)
            return response.getcode(), json.loads(response.read().decode("utf-8"))
        except HTTPError as exc:
            return exc.code, json.loads(exc.read().decode("utf-8"))

    def test_health_without_token_reports_unpaired(self):
        status, body = self.call("GET", "/health")
        self.assertEqual(status, 401)
        self.assertEqual(body["reason"], "missing_token")
        self.assertEqual(body["pairing"], "available")

    def test_health_with_bad_token_reports_invalid(self):
        status, body = self.call("GET", "/health", token="nope")
        self.assertEqual((status, body["reason"]), (401, "invalid_token"))

    def test_pair_then_health_and_action(self):
        code = self.server.state.pairing.code
        status, body = self.call("POST", "/pair", {"code": code, "deviceName": "Test iPhone"})
        self.assertEqual(status, 200)
        token = body["token"]
        status, health = self.call("GET", "/health", token=token)
        self.assertEqual(status, 200)
        self.assertEqual(health["status"], "ok")
        self.assertIn("pairing", health["capabilities"])
        status, _ = self.call("POST", "/action", {"action": {"wait": {"seconds": 0}}}, token=token)
        self.assertEqual(status, 200)
        self.assertNotIn(token, "\n".join(self.lines))

    def test_wrong_code_over_http(self):
        wrong = "000000" if self.server.state.pairing.code != "000000" else "111111"
        status, body = self.call("POST", "/pair", {"code": wrong})
        self.assertEqual((status, body["error"]), (403, "invalid_code"))

    def test_legacy_static_token_still_works(self):
        status, _ = self.call("GET", "/health", token="legacy-static-token-123")
        self.assertEqual(status, 200)

    def test_actions_require_auth(self):
        status, body = self.call("POST", "/action", {"action": {"wait": {"seconds": 0}}})
        self.assertEqual(status, 401)


if __name__ == "__main__":
    unittest.main()
