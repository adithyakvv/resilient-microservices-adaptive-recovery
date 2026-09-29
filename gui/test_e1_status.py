import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SERVER_PATH = Path(__file__).with_name('server.py')
SPEC = importlib.util.spec_from_file_location('project_gui_server_e1_test', SERVER_PATH)
server = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(server)


class E1StatusTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.old_reports = server.REPORTS
        self.old_state = server.STATE_FILE
        self.old_e1_script = server.E1_SCRIPT
        self.old_experiments = server._EXPERIMENTS
        self.old_e1_process = server._run_process
        server.REPORTS = self.root
        server.STATE_FILE = self.root / 'e1-gui-run-state.json'
        server._EXPERIMENTS = {
            'E1': (self.root / 'run-e1-inventory-cpu.ps1', server.STATE_FILE),
            **{name: (self.root / f'run-{name.lower()}.ps1', self.root / f'{name.lower()}-state.json')
               for name in ('E2', 'E3', 'E4', 'E5', 'E6')},
        }
        server._run_process = None

    def tearDown(self):
        server.REPORTS = self.old_reports
        server.STATE_FILE = self.old_state
        server.E1_SCRIPT = self.old_e1_script
        server._EXPERIMENTS = self.old_experiments
        server._run_process = self.old_e1_process
        self.temp.cleanup()

    def _report(self, name, data):
        path = self.root / name
        path.write_text(json.dumps(data), encoding='utf-8')
        return path

    def test_failed_checkonly_is_excluded_from_live_history(self):
        live = {'runId': 'E1-live-old', 'checkOnly': False, 'result': 'NOT_TRIGGERED'}
        older = self._report('e1-inventory-cpu-live.json', live)
        # Force ordering independently of filesystem timestamp resolution.
        import os
        os.utime(older, (100, 100))
        for index, marker in enumerate((True, 'true', {'IsPresent': True}), start=1):
            failed_check = self._report(f'e1-inventory-cpu-failed-check-{index}.json', {
                'runId': 'E1-20260928-165730+0530', 'checkOnly': marker,
                'runStatus': 'Failed', 'result': 'FAILED', 'cleanup': {'error': 'dry-run rejected'},
            })
            os.utime(failed_check, (200 + index, 200 + index))
        self.assertEqual(server.latest_report()['runId'], 'E1-live-old')

    def test_stale_state_pid_is_not_running_or_reported_as_current(self):
        server.STATE_FILE.write_text(json.dumps({'pid': 19776, 'startedAt': '2026-09-28T15:31:13+05:30'}), encoding='utf-8')
        with patch.object(server, '_pid_exists', return_value=False):
            status = server.e1_status()
        self.assertFalse(status['running'])
        self.assertIsNone(status['pid'])
        self.assertIsNone(status['startedAt'])
        self.assertEqual(status['staleState']['pid'], 19776)
        self.assertIn('PID alone is not treated as a running experiment', status['staleState']['reason'])

    def test_stale_or_checkonly_progress_is_not_attached_to_active_run(self):
        state = {'startedAt': '2026-09-28T17:20:00+05:30'}
        progress = {'runId': 'E1-old', 'startedAt': '2026-09-28T17:19:00+05:30', 'checkOnly': False}
        server.REPORTS.joinpath('e1-progress.json').write_text(json.dumps(progress), encoding='utf-8')
        self.assertIsNone(server._matching_e1_progress(state))
        progress['startedAt'] = state['startedAt']
        progress['checkOnly'] = True
        server.REPORTS.joinpath('e1-progress.json').write_text(json.dumps(progress), encoding='utf-8')
        self.assertIsNone(server._matching_e1_progress(state))

    def test_runner_launch_failure_is_persisted_and_returned(self):
        server.E1_SCRIPT = self.root / 'run-e1-inventory-cpu.ps1'
        server.E1_SCRIPT.write_text('# test stub', encoding='utf-8')
        with patch.object(server, 'active_experiment', return_value=None), \
             patch.object(server, 'process_running', return_value=False), \
             patch.object(server.subprocess, 'Popen', side_effect=PermissionError('access denied')):
            state, error = server.start_e1()
        self.assertIsNone(state)
        self.assertIn('PermissionError: access denied', error)
        saved = json.loads(server.STATE_FILE.read_text(encoding='utf-8'))
        self.assertIsNone(saved['pid'])
        self.assertEqual(saved['launchError'], error)
        self.assertFalse(server.e1_status()['running'])

    def test_progress_file_lock_does_not_affect_final_report_implementation(self):
        source = (SERVER_PATH.parent.parent / 'scripts' / 'run-e1-inventory-cpu.ps1').read_text(encoding='utf-8')
        save_run = source.split('function Save-Run {', 1)[1].split('\nfunction Add-Evidence', 1)[0]
        self.assertIn('catch { $run.progressWriteStatus=', save_run)
        self.assertIn('$runPath', save_run)
        self.assertIn('Progress snapshot unavailable; final run report will still be written', save_run)
        self.assertLess(save_run.index('catch { $run.progressWriteStatus='), save_run.rindex('$runPath'))

    def test_gui_clears_starting_on_status_and_launch_errors(self):
        html = (SERVER_PATH.parent / 'index.html').read_text(encoding='utf-8')
        self.assertIn("if(s.error){e1Starting=false", html)
        self.assertIn("s.launchError&&!s.running?'Launch failed'", html)
        self.assertIn('E1 start request timed out; checking runner status.', html)
        self.assertIn("button.disabled=false;return", html)


if __name__ == '__main__':
    unittest.main()
