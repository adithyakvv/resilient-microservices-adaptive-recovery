import importlib.util
import json
import tempfile
import unittest
import http.client
import threading
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('e2_prepare_server', Path(__file__).with_name('server.py'))
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


class E2PreparationGuiTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.saved = (server.REPORTS, server.E2_PREPARE_SCRIPT, server.E2_PREPARE_STATE_FILE,
                      server.E2_PREPARE_STATUS_FILE, server._e2_prepare_process)
        server.REPORTS = self.root
        server.E2_PREPARE_SCRIPT = self.root / 'prepare-e2-inventory.ps1'
        server.E2_PREPARE_SCRIPT.write_text('# mocked runner', encoding='utf-8')
        server.E2_PREPARE_STATE_FILE = self.root / 'launch.json'
        server.E2_PREPARE_STATUS_FILE = self.root / 'preparation.json'
        server._e2_prepare_process = None

    def tearDown(self):
        (server.REPORTS, server.E2_PREPARE_SCRIPT, server.E2_PREPARE_STATE_FILE,
         server.E2_PREPARE_STATUS_FILE, server._e2_prepare_process) = self.saved
        self.tmp.cleanup()

    def test_fixed_launcher_never_starts_e2_runner_and_rejects_active_experiment(self):
        with patch.object(server, 'active_experiment', return_value={'name': 'E4', 'runId': 'E4-test'}):
            state, error = server.start_e2_preparation()
        self.assertIsNone(state)
        self.assertIn('E4', error)
        class Child:
            pid = 9876
            def poll(self): return None
        with patch.object(server, 'active_experiment', return_value=None), \
             patch.object(server.subprocess, 'Popen', return_value=Child()) as popen:
            state, error = server.start_e2_preparation()
        self.assertIsNone(error)
        self.assertEqual(state['pid'], 9876)
        args = popen.call_args.args[0]
        self.assertEqual(args[-1], str(server.E2_PREPARE_SCRIPT))
        self.assertNotIn(str(server.E2_SCRIPT), args)
        self.assertNotIn('-CheckOnly', args)
        self.assertEqual(server.e2_prepare_status()['preparation']['state'], 'Preparing')

    def test_ready_requires_three_distinct_recent_below_guard_samples(self):
        from datetime import datetime, timezone, timedelta
        now = datetime.now(timezone.utc)
        samples = [{'sourceTimestamp': (now - timedelta(seconds=30 - n * 10)).isoformat(),
                    'podUid': 'same-ready-pod', 'memoryRatio': 0.49 + n * .01}
                   for n in range(3)]
        report = {'running': False, 'state': 'Ready', 'reason': 'baseline passed',
                  'baseline': {'before': samples}, 'restart': {'attempted': False}}
        server.E2_PREPARE_STATUS_FILE.write_text(json.dumps(report), encoding='utf-8')
        with patch.object(server, '_e2_preparation_active', return_value=False), \
             patch.object(server, 'active_experiment', return_value=None):
            self.assertEqual(server.e2_prepare_status()['preparation']['state'], 'Ready')
            report['baseline']['before'][2]['memoryRatio'] = .553
            server.E2_PREPARE_STATUS_FILE.write_text(json.dumps(report), encoding='utf-8')
            self.assertEqual(server.e2_prepare_status()['preparation']['state'], 'Blocked')
            report['baseline']['before'][2]['memoryRatio'] = .51
            report['baseline']['before'][2]['sourceTimestamp'] = samples[1]['sourceTimestamp']
            server.E2_PREPARE_STATUS_FILE.write_text(json.dumps(report), encoding='utf-8')
            self.assertEqual(server.e2_prepare_status()['preparation']['state'], 'Blocked')

    def test_exited_preparation_cannot_remain_preparing(self):
        server.E2_PREPARE_STATUS_FILE.write_text(json.dumps({'running': True, 'state': 'Preparing'}), encoding='utf-8')
        with patch.object(server, '_e2_preparation_active', return_value=False), \
             patch.object(server, 'active_experiment', return_value=None):
            result = server.e2_prepare_status()
        self.assertEqual(result['preparation']['state'], 'Blocked')

    def test_no_preparation_evidence_is_blocked_not_ready(self):
        with patch.object(server, '_e2_preparation_active', return_value=False), \
             patch.object(server, 'active_experiment', return_value=None):
            result = server.e2_prepare_status()
        self.assertEqual(result['preparation']['state'], 'Blocked')

    def test_fixed_http_route_and_duplicate_rejection_without_running_script(self):
        httpd = ThreadingHTTPServer(('127.0.0.1', 0), server.Handler)
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        try:
            with patch.object(server, 'start_e2_preparation', return_value=({'pid': 42}, None)) as launch, \
                 patch.object(server, 'e2_prepare_status', return_value={'running': True, 'preparation': {'state': 'Preparing'}}):
                conn = http.client.HTTPConnection('127.0.0.1', httpd.server_address[1], timeout=3)
                conn.request('POST', '/api/e2/prepare')
                response = conn.getresponse()
                body = json.loads(response.read())
                conn.close()
                self.assertEqual(response.status, 202)
                self.assertIn('E2 was not run', body['message'])
                launch.assert_called_once_with()
            with patch.object(server, 'start_e2_preparation', return_value=(None, 'Cannot prepare E2 while E4 is active')), \
                 patch.object(server, 'e2_prepare_status', return_value={'running': False, 'preparation': {'state': 'Blocked'}}):
                conn = http.client.HTTPConnection('127.0.0.1', httpd.server_address[1], timeout=3)
                conn.request('POST', '/api/e2/prepare')
                response = conn.getresponse()
                response.read()
                conn.close()
                self.assertEqual(response.status, 409)
        finally:
            httpd.shutdown()
            thread.join(timeout=3)
            httpd.server_close()


if __name__ == '__main__':
    unittest.main()
