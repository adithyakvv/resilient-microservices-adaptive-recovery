from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
from urllib.request import urlopen, Request
from urllib.error import HTTPError, URLError
import json
import os
from pathlib import Path
import re
import subprocess
import threading
import time
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parent.parent
REPORTS = ROOT / 'reports'
REPORTS.mkdir(exist_ok=True)
E1_SCRIPT = ROOT / 'scripts' / 'run-e1-inventory-cpu.ps1'
E2_SCRIPT = ROOT / 'scripts' / 'run-e2-inventory-memory.ps1'
E2_PREPARE_SCRIPT = ROOT / 'scripts' / 'prepare-e2-inventory.ps1'
E3_SCRIPT = ROOT / 'scripts' / 'run-e3-order-inventory-delay.ps1'
E4_SCRIPT = ROOT / 'scripts' / 'run-e4-order-http500.ps1'
E5_SCRIPT = ROOT / 'scripts' / 'run-e5-order-http500.ps1'
E6_SCRIPT = ROOT / 'scripts' / 'run-e6-product-pod-kill.ps1'
STATE_FILE = REPORTS / 'e1-gui-run-state.json'
E2_STATE_FILE = REPORTS / 'e2-gui-run-state.json'
E2_PREPARE_STATE_FILE = REPORTS / 'e2-preparation-launch.json'
E2_PREPARE_STATUS_FILE = REPORTS / 'e2-preparation-status.json'
E3_STATE_FILE = REPORTS / 'e3-gui-run-state.json'
E4_STATE_FILE = REPORTS / 'e4-gui-run-state.json'
E5_STATE_FILE = REPORTS / 'e5-gui-run-state.json'
E6_STATE_FILE = REPORTS / 'e6-gui-run-state.json'
SERVICE_APIS = {
    'product': ('http://127.0.0.1:18081', '/api/products'),
    'inventory': ('http://127.0.0.1:18082', '/api/inventory'),
    'order': ('http://127.0.0.1:18083', '/api/orders'),
}
_run_lock = threading.Lock()
_run_process = None
_e2_lock = threading.Lock()
_e2_process = None
_e2_prepare_process = None
_e2_prepare_lock = threading.Lock()
_e3_lock = threading.Lock()
_e3_process = None
_e4_lock = threading.Lock()
_e4_process = None
_e5_lock = threading.Lock()
_e5_process = None
_e6_lock = threading.Lock()
_e6_process = None
_e5_sim_lock = threading.Lock()
_e5_sim_enabled = False
_pid_command_line_cache = {}

# All experiment launchers use the same cross-experiment ownership check.  The
# state files survive a GUI restart, so a PID alone is not sufficient (Windows
# may reuse it for an unrelated process).  We only treat a state PID as active
# when its command line still names this project's runner.
_EXPERIMENTS = {
    'E1': (E1_SCRIPT, STATE_FILE),
    'E2': (E2_SCRIPT, E2_STATE_FILE),
    'E3': (E3_SCRIPT, E3_STATE_FILE),
    'E4': (E4_SCRIPT, E4_STATE_FILE),
    'E5': (E5_SCRIPT, E5_STATE_FILE),
    'E6': (E6_SCRIPT, E6_STATE_FILE),
}

def read_json(path):
    try:
        return json.loads(path.read_text(encoding='utf-8-sig'))
    except (OSError, ValueError):
        return None

def _is_check_only_report(report):
    """Normalize PowerShell JSON switch representations for report selection."""
    if not isinstance(report, dict):
        return False
    value = report.get('checkOnly')
    if isinstance(value, dict):
        value = value.get('IsPresent', False)
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    return str(value or '').strip().lower() in {'true', '1', 'yes', 'present'}

def latest_report():
    files = sorted(REPORTS.glob('e1-inventory-cpu-*.json'), key=lambda p: p.stat().st_mtime, reverse=True)
    for path in files:
        report = read_json(path)
        if report and not _is_check_only_report(report) and report.get('result') != 'CHECK_ONLY_PASS':
            return report
    return None

def latest_e2_report():
    files = sorted(REPORTS.glob('e2-inventory-memory-*.json'), key=lambda p: p.stat().st_mtime, reverse=True)
    for path in files:
        report = read_json(path)
        if report and report.get('result') != 'CHECK_ONLY_PASS':
            return report
    return None

def progress_report():
    return read_json(REPORTS / 'e1-progress.json')

def _matching_e1_progress(state):
    progress = progress_report()
    if not progress or _is_check_only_report(progress):
        return None
    state_started = state.get('startedAt') if isinstance(state, dict) else None
    report_started = progress.get('startedAt')
    if state_started and report_started:
        try:
            from datetime import datetime
            if abs((datetime.fromisoformat(str(report_started)) -
                    datetime.fromisoformat(str(state_started))).total_seconds()) > 5:
                return None
        except (TypeError, ValueError):
            return None
    return progress

def process_running():
    return _run_process is not None and _run_process.poll() is None

def _pid_command_line(pid):
    key = int(pid)
    now = time.monotonic()
    cached = _pid_command_line_cache.get(key)
    if cached and now - cached[0] < 2:
        return cached[1]
    try:
        result = subprocess.run(
            ['powershell', '-NoProfile', '-Command',
             f"$p=Get-CimInstance Win32_Process -Filter 'ProcessId = {key}' -ErrorAction SilentlyContinue; if($p){{$p.CommandLine}}"],
            capture_output=True, text=True, timeout=1.5)
        value = result.stdout.strip()
    except Exception:
        value = ''
    _pid_command_line_cache[key] = (now, value)
    return value

def _pid_exists(pid):
    """Cheap negative check only; a positive PID is never sufficient proof of a runner."""
    try:
        os.kill(int(pid), 0)
        return True
    except PermissionError:
        return True
    except (OSError, ValueError, TypeError):
        return False

def _runner_active(name):
    script, state_path = _EXPERIMENTS[name]
    process = {'E1': _run_process, 'E2': _e2_process, 'E3': _e3_process,
               'E4': _e4_process, 'E5': _e5_process, 'E6': _e6_process}[name]
    if process is not None:
        # A Popen handle is authoritative for the process this server launched.
        # Do not mistake an exited child or a subsequently reused PID for a run.
        return process.poll() is None
    state = read_json(state_path) or {}
    pid = state.get('pid')
    if not pid or not _pid_exists(pid):
        return False
    command_line = _pid_command_line(pid)
    return bool(command_line and script.name.lower() in command_line.lower())

def _runner_handles():
    return {'E1': _run_process, 'E2': _e2_process, 'E3': _e3_process,
            'E4': _e4_process, 'E5': _e5_process, 'E6': _e6_process}

def _pid_command_lines(pids):
    """Check stale-state PIDs in one PowerShell query, matching command lines rather than PID alone."""
    ids = sorted({int(pid) for pid in pids if pid})
    if not ids:
        return {}
    now = time.monotonic()
    cache_key = tuple(ids)
    cached = _pid_command_line_cache.get(cache_key)
    if cached and now - cached[0] < 1:
        return cached[1]
    id_list = ','.join(str(pid) for pid in ids)
    script = (f'$ids=@({id_list});$rows=@(foreach($id in $ids){{'
              "$p=Get-CimInstance Win32_Process -Filter \"ProcessId = $id\" -ErrorAction SilentlyContinue;"
              'if($p){[pscustomobject]@{pid=[int]$p.ProcessId;commandLine=[string]$p.CommandLine}}});'
              'ConvertTo-Json -InputObject $rows -Compress')
    try:
        result = subprocess.run(['powershell', '-NoProfile', '-Command', script],
                                capture_output=True, text=True, timeout=2.5)
        parsed = json.loads(result.stdout) if result.stdout.strip() else []
        if isinstance(parsed, dict):
            parsed = [parsed]
        commands = {str(row['pid']): row.get('commandLine', '') for row in parsed if row.get('pid')}
    except Exception:
        commands = {}
    _pid_command_line_cache[cache_key] = (now, commands)
    return commands

def active_experiment():
    """Return the one live runner owner, or None for stale/terminal state."""
    if _e2_preparation_active():
        state = read_json(E2_PREPARE_STATE_FILE) or {}
        return {'name': 'E2 preparation', 'runId': None, 'pid': state.get('pid'),
                'script': E2_PREPARE_SCRIPT.name}
    handles = _runner_handles()
    candidates = []
    for name, (script, state_path) in _EXPERIMENTS.items():
        process = handles.get(name)
        if process is not None:
            if process.poll() is None:
                state = read_json(state_path) or {}
                progress = _matching_e1_progress(state) if name == 'E1' else (read_json(REPORTS / f'{name.lower()}-progress.json') or {})
                report = progress if name == 'E1' else progress or (
                    latest_report() if name == 'E1' else
                    latest_e2_report() if name == 'E2' else
                    latest_e3_report() if name == 'E3' else
                    latest_e4_report() if name == 'E4' else
                    latest_e5_report() if name == 'E5' else
                    latest_e6_report())
                return {'name': name, 'runId': report.get('runId') if report else None,
                        'pid': state.get('pid'), 'script': script.name}
            continue
        state = read_json(state_path) or {}
        pid = state.get('pid')
        if pid and _pid_exists(pid):
            candidates.append((name, script, state_path, state, pid))
    commands = _pid_command_lines(candidate[4] for candidate in candidates)
    for name, script, state_path, state, pid in candidates:
        command_line = commands.get(str(pid), '')
        if not command_line or script.name.lower() not in command_line.lower():
            continue
        progress = _matching_e1_progress(state) if name == 'E1' else (read_json(REPORTS / f'{name.lower()}-progress.json') or {})
        report = progress if name == 'E1' else progress or (
            latest_report() if name == 'E1' else
            latest_e2_report() if name == 'E2' else
            latest_e3_report() if name == 'E3' else
            latest_e4_report() if name == 'E4' else
            latest_e5_report() if name == 'E5' else
            latest_e6_report())
        return {'name': name, 'runId': report.get('runId') if report else None,
                'pid': state.get('pid'), 'script': script.name}
    return None

def _e2_preparation_active():
    if _e2_prepare_process is not None:
        return _e2_prepare_process.poll() is None
    state = read_json(E2_PREPARE_STATE_FILE) or {}
    pid = state.get('pid')
    return bool(pid and _pid_exists(pid) and
                E2_PREPARE_SCRIPT.name.lower() in _pid_command_line(pid).lower())

def e2_prepare_status():
    running = _e2_preparation_active()
    saved = read_json(E2_PREPARE_STATUS_FILE)
    if not saved:
        saved = {'state': 'Preparing' if running else 'Blocked',
                 'reason': 'Click Prepare E2 to check three fresh baseline readings; Inventory may be restarted once only if the guard blocks it.'}
    else:
        saved = dict(saved)
        if not running and saved.get('running'):
            saved['state'] = 'Blocked'
            saved['reason'] = 'E2 preparation process exited before writing a terminal result.'
        if not running and saved.get('state') == 'Ready':
            baseline = saved.get('baseline') or {}
            samples = baseline.get('after') if (saved.get('restart') or {}).get('attempted') else baseline.get('before')
            try:
                times = [datetime.fromisoformat(s['sourceTimestamp']).astimezone(timezone.utc) for s in samples]
                uids = {s['podUid'] for s in samples}
                ratios = [float(s['memoryRatio']) for s in samples]
                fresh = (len(samples) == 3 and len(set(times)) == 3 and len(uids) == 1 and
                         all(r < 0.55 for r in ratios) and
                         0 <= (datetime.now(timezone.utc) - max(times)).total_seconds() <= 120)
            except (TypeError, ValueError, KeyError):
                fresh = False
            if not fresh:
                saved['state'] = 'Blocked'
                saved['reason'] = 'E2 preparation readings are no longer fresh or complete; click Prepare E2 again.'
    return {'running': running, 'preparation': saved,
            'activeExperiment': active_experiment()}

def e1_status():
    state = read_json(STATE_FILE) or {}
    owner = active_experiment()
    running = bool(owner and owner.get('name') == 'E1')
    progress = _matching_e1_progress(state) if running else None
    if running:
        report = progress if progress and not _is_check_only_report(progress) else None
    else:
        report = latest_report()
    stale = None
    if not running and state.get('pid'):
        stale = {'pid': state.get('pid'), 'startedAt': state.get('startedAt'),
                 'reason': 'Recorded runner process is no longer active; PID alone is not treated as a running experiment.'}
    launch_error = state.get('launchError') if not running else None
    return {'running': running, 'state': 'Running' if running else (report.get('result') if report else 'Ready'),
            'startedAt': state.get('startedAt') if running else None,
            'pid': state.get('pid') if running else None, 'log': state.get('log'),
            'staleState': stale, 'launchError': launch_error, 'report': report,
            'activeExperiment': owner}

def e2_status():
    state = read_json(E2_STATE_FILE) or {}
    running = _runner_active('E2')
    report = read_json(REPORTS / 'e2-progress.json') if running else latest_e2_report()
    return {'running': running, 'state': 'Running' if running else (report.get('result') if report else 'Ready'),
            'startedAt': state.get('startedAt'), 'pid': state.get('pid'), 'log': state.get('log'), 'report': report,
            'activeExperiment': active_experiment()}

def latest_e3_report():
    files = sorted(REPORTS.glob('e3-order-inventory-delay-*.json'), key=lambda p: p.stat().st_mtime, reverse=True)
    for path in files:
        report = read_json(path)
        if report and report.get('result') != 'CHECK_ONLY_PASS' and (report.get('chaos', {}).get('created') or report.get('measurements') or report.get('engineEvaluations')):
            return report
    return None

def e3_status():
    state = read_json(E3_STATE_FILE) or {}
    running = _runner_active('E3')
    report = read_json(REPORTS / 'e3-progress.json') if running else latest_e3_report()
    return {'running': running, 'state': 'Running' if running else (report.get('result') if report else 'Ready'),
            'startedAt': state.get('startedAt'), 'pid': state.get('pid'), 'log': state.get('log'), 'report': report,
            'activeExperiment': active_experiment()}

def latest_e4_report():
    files = sorted(REPORTS.glob('e4-order-http500-*.json'), key=lambda p: p.stat().st_mtime, reverse=True)
    for path in files:
        report = read_json(path)
        # The newest non-CheckOnly report is authoritative, including a
        # preflight-blocked run with no measurements.  Dropping such reports
        # makes the GUI fall back to an older experiment and hides the actual
        # launch result.
        if report and report.get('result') != 'CHECK_ONLY_PASS':
            return report
    return None

def e4_status():
    state = read_json(E4_STATE_FILE) or {}
    running = _runner_active('E4')
    report = read_json(REPORTS / 'e4-progress.json') if running else latest_e4_report()
    return {'running': running, 'state': 'Running' if running else (report.get('result') if report else 'Prepared — not run'),
            'startedAt': state.get('startedAt'), 'pid': state.get('pid'), 'log': state.get('log'), 'report': report,
            'activeExperiment': active_experiment()}

def latest_e5_report():
    files = sorted(REPORTS.glob('e5-order-http500-*.json'), key=lambda p: p.stat().st_mtime, reverse=True)
    for path in files:
        report = read_json(path)
        # Preparation/check-only records are never live experiment evidence.
        # The explicit marker handles new records; the outcome marker keeps
        # older preparation records from replacing the Prepared state.
        check_only = report.get('checkOnly') if report else False
        # PowerShell serializes a [switch] as an object in some versions;
        # normalize that shape so a false check-only record remains live evidence.
        if isinstance(check_only, dict):
            check_only = bool(check_only.get('IsPresent', False))
        if report and not check_only and not str(report.get('experimentOutcome') or '').startswith('Not applicable') and report.get('result') != 'CHECK_ONLY_PASS':
            return report
    return None

def e5_runtime_preflight():
    """Read-only check for the fixed local simulation endpoint.

    E5 fallback deliberately does not depend on the deployed Order image.
    """
    route = 'http://127.0.0.1:18080/api/e5/sim-probe'
    try:
        with urlopen(route, timeout=3) as response:
            status = int(response.status)
            if status == 200:
                return {'status': 'READY', 'routeStatus': status, 'healthStatus': status,
                        'simulationOnly': True, 'reason': 'E5 local fallback; no Order image required'}
            return {'status': 'BLOCKED', 'routeStatus': status, 'healthStatus': status,
                    'simulationOnly': True, 'reason': f'Local E5 fallback returned HTTP {status}'}
    except HTTPError as exc:
        return {'status': 'BLOCKED', 'routeStatus': exc.code, 'healthStatus': exc.code,
                'simulationOnly': True, 'reason': f'Local E5 fallback returned HTTP {exc.code}'}
    except (URLError, OSError) as exc:
        return {'status': 'UNAVAILABLE', 'routeStatus': None, 'healthStatus': None,
                'simulationOnly': True, 'reason': f'Local E5 fallback unavailable: {exc.reason if hasattr(exc, "reason") else exc}'}

def e5_status():
    state = read_json(E5_STATE_FILE) or {}
    running = _runner_active('E5')
    report = read_json(REPORTS / 'e5-progress.json') if running else latest_e5_report()
    if running and report:
        samples = report.get('samples') or []
        last = samples[-1] if samples else {}
        fault_active = bool((report.get('fault') or {}).get('enabled'))
        status = last.get('status')
        if fault_active and status == 500:
            runtime = {'status': 'RUNNING_FAULT', 'routeStatus': 500, 'healthStatus': None,
                       'simulationOnly': True,
                       'reason': 'E5 probe: HTTP 500 (fault active)',
                       'faultActive': True}
        else:
            runtime = {'status': 'RUNNING', 'routeStatus': status, 'healthStatus': None,
                       'simulationOnly': True,
                       'reason': 'E5 run active; cleanup pending',
                       'faultActive': fault_active}
    else:
        runtime = e5_runtime_preflight()
    return {'running': running, 'state': 'Running' if running else (report.get('result') if report else 'Prepared — not run'),
            'startedAt': state.get('startedAt'), 'pid': state.get('pid'), 'log': state.get('log'), 'report': report,
            'runtime': runtime, 'activeExperiment': active_experiment()}

def latest_e6_report():
    files = sorted(REPORTS.glob('e6-product-pod-kill-*.json'), key=lambda p: p.stat().st_mtime, reverse=True)
    for path in files:
        report = read_json(path)
        if report and report.get('result') != 'CHECK_ONLY_PASS':
            return report
    return None

def e6_status():
    state = read_json(E6_STATE_FILE) or {}
    running = _runner_active('E6')
    report = read_json(REPORTS / 'e6-progress.json') if running else latest_e6_report()
    owner = active_experiment()
    # A completed preflight-blocked report is historical information, not a
    # held lock.  The card must return to Ready when no runner owns the lock.
    if running:
        state_name = 'Running'
    elif owner:
        state_name = 'Blocked'
    elif report and report.get('result') == 'BLOCKED':
        state_name = 'Ready'
    else:
        state_name = report.get('result') if report else 'Ready'
    return {'running': running, 'state': state_name,
            'startedAt': state.get('startedAt'), 'pid': state.get('pid'), 'log': state.get('log'), 'report': report,
            'activeExperiment': owner}

def start_e1():
    global _run_process
    with _run_lock:
        owner = active_experiment()
        if owner:
            return None, f"Another experiment is already running: {owner['name']} ({owner.get('runId') or 'run id unavailable'})"
        if process_running():
            return None, 'E1 is already running'
        if not E1_SCRIPT.exists():
            error = f'E1 runner is missing: {E1_SCRIPT}'
            _write_e1_launch_error(error)
            return None, error
        REPORTS.mkdir(exist_ok=True)
        log_path = REPORTS / 'e1-gui-run.log'
        cmd = ['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(E1_SCRIPT)]
        started_at = time.strftime('%Y-%m-%dT%H:%M:%S+05:30')
        try:
            with open(log_path, 'a', encoding='utf-8') as log:
                _run_process = subprocess.Popen(cmd, cwd=str(ROOT), stdout=log, stderr=subprocess.STDOUT,
                                                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        except Exception as exc:
            _run_process = None
            error = f'Failed to launch E1 runner ({cmd[0]}): {type(exc).__name__}: {exc}'
            _write_e1_launch_error(error, started_at, str(log_path))
            return None, error
        state = {'pid': _run_process.pid, 'startedAt': started_at, 'log': str(log_path), 'launchError': None}
        try:
            STATE_FILE.write_text(json.dumps(state), encoding='utf-8')
        except OSError as exc:
            # The child is already running; keep its in-memory handle and surface
            # the state-file problem without pretending the launch failed.
            state['statePersistenceError'] = f'{type(exc).__name__}: {exc}'
        return state, None

def _write_e1_launch_error(error, started_at=None, log_path=None):
    state = {'pid': None, 'startedAt': started_at, 'log': log_path,
             'launchError': error, 'launchFailedAt': time.strftime('%Y-%m-%dT%H:%M:%S+05:30')}
    try:
        STATE_FILE.write_text(json.dumps(state), encoding='utf-8')
    except OSError:
        pass

def start_e2():
    global _e2_process
    with _e2_lock:
        owner = active_experiment()
        if owner:
            return None, f"Another experiment is already running: {owner['name']} ({owner.get('runId') or 'run id unavailable'})"
        if _e2_process is not None and _e2_process.poll() is None:
            return None, 'E2 is already running'
        if not E2_SCRIPT.exists():
            return None, 'E2 runner is missing'
        try: (REPORTS / 'e2-progress.json').unlink()
        except FileNotFoundError: pass
        log_path = REPORTS / 'e2-gui-run.log'; log = open(log_path, 'a', encoding='utf-8')
        _e2_process = subprocess.Popen(['powershell','-NoProfile','-ExecutionPolicy','Bypass','-File',str(E2_SCRIPT)], cwd=str(ROOT), stdout=log, stderr=subprocess.STDOUT, creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        state={'pid':_e2_process.pid,'startedAt':time.strftime('%Y-%m-%dT%H:%M:%S+05:30'),'log':str(log_path)}; E2_STATE_FILE.write_text(json.dumps(state),encoding='utf-8'); return state,None

def start_e2_preparation():
    global _e2_prepare_process
    with _e2_prepare_lock:
        owner = active_experiment()
        if owner:
            return None, f"Cannot prepare E2 while {owner['name']} is active"
        if not E2_PREPARE_SCRIPT.exists():
            return None, 'E2 preparation script is missing'
        try:
            E2_PREPARE_STATUS_FILE.unlink()
        except FileNotFoundError:
            pass
        log_path = REPORTS / 'e2-preparation.log'
        try:
            with open(log_path, 'a', encoding='utf-8') as log:
                _e2_prepare_process = subprocess.Popen(
                    ['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                     '-File', str(E2_PREPARE_SCRIPT)], cwd=str(ROOT),
                    stdout=log, stderr=subprocess.STDOUT,
                    creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
            state = {'pid': _e2_prepare_process.pid,
                     'startedAt': time.strftime('%Y-%m-%dT%H:%M:%S+05:30'),
                     'log': str(log_path)}
            E2_PREPARE_STATE_FILE.write_text(json.dumps(state), encoding='utf-8')
            return state, None
        except (OSError, subprocess.SubprocessError) as exc:
            error = f'E2 preparation could not start: {exc}'
            E2_PREPARE_STATUS_FILE.write_text(json.dumps({'state': 'Blocked', 'reason': error}), encoding='utf-8')
            return None, error

def start_e3():
    global _e3_process
    with _e3_lock:
        owner = active_experiment()
        if owner:
            return None, f"Another experiment is already running: {owner['name']} ({owner.get('runId') or 'run id unavailable'})"
        if not E3_SCRIPT.exists(): return None, 'E3 runner is missing'
        try: (REPORTS / 'e3-progress.json').unlink()
        except FileNotFoundError: pass
        log_path=REPORTS/'e3-gui-run.log'; log=open(log_path,'a',encoding='utf-8')
        _e3_process=subprocess.Popen(['powershell','-NoProfile','-ExecutionPolicy','Bypass','-File',str(E3_SCRIPT)],cwd=str(ROOT),stdout=log,stderr=subprocess.STDOUT,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        state={'pid':_e3_process.pid,'startedAt':time.strftime('%Y-%m-%dT%H:%M:%S+05:30'),'log':str(log_path)};E3_STATE_FILE.write_text(json.dumps(state),encoding='utf-8');return state,None

def start_e4():
    global _e4_process
    with _e4_lock:
        owner = active_experiment()
        if owner:
            return None, f"Another experiment is already running: {owner['name']} ({owner.get('runId') or 'run id unavailable'})"
        if not E4_SCRIPT.exists(): return None, 'E4 runner is missing'
        try: (REPORTS / 'e4-progress.json').unlink()
        except FileNotFoundError: pass
        log_path=REPORTS/'e4-gui-run.log'; log=open(log_path,'a',encoding='utf-8')
        _e4_process=subprocess.Popen(['powershell','-NoProfile','-ExecutionPolicy','Bypass','-File',str(E4_SCRIPT)],cwd=str(ROOT),stdout=log,stderr=subprocess.STDOUT,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        state={'pid':_e4_process.pid,'startedAt':time.strftime('%Y-%m-%dT%H:%M:%S+05:30'),'log':str(log_path)};E4_STATE_FILE.write_text(json.dumps(state),encoding='utf-8');return state,None

def start_e5():
    global _e5_process
    with _e5_lock:
        owner = active_experiment()
        if owner:
            return None, f"Another experiment is already running: {owner['name']} ({owner.get('runId') or 'run id unavailable'})"
        if not E5_SCRIPT.exists(): return None, 'E5 runner is missing'
        try: (REPORTS / 'e5-progress.json').unlink()
        except FileNotFoundError: pass
        log_path=REPORTS/'e5-gui-run.log'; log=open(log_path,'a',encoding='utf-8')
        _e5_process=subprocess.Popen(['powershell','-NoProfile','-ExecutionPolicy','Bypass','-File',str(E5_SCRIPT)],cwd=str(ROOT),stdout=log,stderr=subprocess.STDOUT,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        state={'pid':_e5_process.pid,'startedAt':time.strftime('%Y-%m-%dT%H:%M:%S+05:30'),'log':str(log_path)};E5_STATE_FILE.write_text(json.dumps(state),encoding='utf-8');return state,None

def start_e6():
    global _e6_process
    with _e6_lock:
        owner = active_experiment()
        if owner:
            return None, f"Another experiment is already running: {owner['name']} ({owner.get('runId') or 'run id unavailable'})"
        if not E6_SCRIPT.exists(): return None, 'E6 runner is missing'
        try: (REPORTS / 'e6-progress.json').unlink()
        except FileNotFoundError: pass
        log_path=REPORTS/'e6-gui-run.log';log=open(log_path,'a',encoding='utf-8')
        _e6_process=subprocess.Popen(['powershell','-NoProfile','-ExecutionPolicy','Bypass','-File',str(E6_SCRIPT)],cwd=str(ROOT),stdout=log,stderr=subprocess.STDOUT,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        state={'pid':_e6_process.pid,'startedAt':time.strftime('%Y-%m-%dT%H:%M:%S+05:30'),'log':str(log_path)};E6_STATE_FILE.write_text(json.dumps(state),encoding='utf-8');return state,None

class Handler(SimpleHTTPRequestHandler):
    def _json(self, status, value):
        data = json.dumps(value).encode('utf-8')
        self.send_response(status); self.send_header('Content-Type', 'application/json'); self.end_headers(); self.wfile.write(data)

    def _service_api(self, method):
        """Proxy only the fixed Product, Inventory, and Order collection routes."""
        parsed = urlparse(self.path)
        match = re.fullmatch(r'/api/services/(product|inventory|order)(?:/(health|[1-9][0-9]*))?', parsed.path)
        if not match or parsed.query:
            self._json(404, {'error': 'unknown fixed service API route'}); return
        service, suffix = match.groups()
        _, collection = SERVICE_APIS[service]
        if suffix == 'health':
            if method != 'GET':
                self._json(405, {'error': 'health route supports GET only'}); return
            item_id = None
            endpoint = '/actuator/health'
        else:
            item_id = suffix
            endpoint = collection + (('/' + item_id) if item_id else '')
        if method in ('GET', 'POST') and item_id:
            self._json(405, {'error': 'method is not supported for an item route'}); return
        if method in ('PUT', 'DELETE') and not item_id:
            self._json(405, {'error': 'an item ID is required'}); return

        body = None
        if method in ('POST', 'PUT'):
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if length <= 0 or length > 16384:
                    raise ValueError('request body must be between 1 and 16384 bytes')
                body = json.loads(self.rfile.read(length).decode('utf-8'))
                if not isinstance(body, dict):
                    raise ValueError('request body must be a JSON object')
            except (ValueError, UnicodeDecodeError, json.JSONDecodeError) as exc:
                self._json(400, {'error': str(exc)}); return

        base, _ = SERVICE_APIS[service]
        target = base + endpoint
        data = json.dumps(body).encode('utf-8') if body is not None else None
        request = Request(target, data=data, method=method,
                          headers={'Content-Type': 'application/json', 'Accept': 'application/json'})
        try:
            with urlopen(request, timeout=5) as response:
                payload = response.read()
                status = response.status
                content_type = response.headers.get('Content-Type', 'application/json')
        except HTTPError as exc:
            payload = exc.read()
            status = exc.code
            content_type = exc.headers.get('Content-Type', 'application/json')
        except (URLError, TimeoutError, OSError) as exc:
            self._json(502, {'error': f'{service} service connection failed: {exc}'}); return
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.end_headers()
        if payload:
            self.wfile.write(payload)

    def do_POST(self):
        if self.path.startswith('/api/services/'):
            self._service_api('POST'); return
        if self.path == '/api/e5/sim-fault':
            if self.headers.get('X-E5-Runner') != 'local-fixed-e5':
                self._json(403, {'error': 'fixed E5 runner header required'}); return
            try:
                n = int(self.headers.get('Content-Length', '0'))
                body = json.loads(self.rfile.read(n).decode('utf-8'))
                enabled = body.get('enabled')
                if type(enabled) is not bool or set(body.keys()) != {'enabled'}:
                    raise ValueError('enabled must be the only boolean field')
            except Exception as exc:
                self._json(400, {'error': str(exc)}); return
            global _e5_sim_enabled
            with _e5_sim_lock:
                _e5_sim_enabled = enabled
            self._json(200, {'enabled': enabled, 'simulationOnly': True}); return
        if self.path == '/api/e1/run':
            state, error = start_e1()
            if error: self._json(409 if 'already running' in error else 500, {'error': error, 'status': {'running': False, 'launchError': error}})
            else: self._json(202, {'message': 'E1 runner process started', 'status': {'running': True, 'state': 'Running', **(state or {})}})
            return
        if self.path == '/api/e2/run':
            state, error = start_e2()
            if error: self._json(409 if 'already running' in error else 500, {'error': error, 'status': e2_status()})
            else: self._json(202, {'message': 'E2 started', 'status': e2_status()})
            return
        if self.path == '/api/e2/prepare':
            state, error = start_e2_preparation()
            if error: self._json(409 if 'active' in error else 500, {'error': error, 'status': e2_prepare_status()})
            else: self._json(202, {'message': 'E2 preparation started; E2 was not run', 'status': e2_prepare_status()})
            return
        if self.path == '/api/e3/run':
            state, error = start_e3()
            if error: self._json(409 if 'running' in error else 500, {'error': error, 'status': e3_status()})
            else: self._json(202, {'message': 'E3 started', 'status': e3_status()})
            return
        if self.path == '/api/e4/run':
            state, error = start_e4()
            if error: self._json(409 if 'running' in error else 500, {'error': error, 'status': e4_status()})
            else: self._json(202, {'message': 'E4 started', 'status': e4_status()})
            return
        if self.path == '/api/e5/run':
            state, error = start_e5()
            if error: self._json(409 if 'running' in error else 500, {'error': error, 'status': e5_status()})
            else: self._json(202, {'message': 'E5 started', 'status': e5_status()})
            return
        if self.path == '/api/e6/run':
            state, error = start_e6()
            if error: self._json(409 if 'running' in error else 500, {'error': error, 'status': e6_status()})
            else: self._json(202, {'message': 'E6 started', 'status': e6_status()})
            return
        if self.path.startswith('/proxy?'):
            target=parse_qs(urlparse(self.path).query).get('url',[''])[0]; n=int(self.headers.get('Content-Length','0')); body=self.rfile.read(n)
            try:
                req=Request(target,data=body,method='POST',headers={'Content-Type':self.headers.get('Content-Type','application/json')})
                with urlopen(req,timeout=5) as r: data=r.read(); self.send_response(r.status); self.send_header('Content-Type',r.headers.get('Content-Type','application/json')); self.end_headers(); self.wfile.write(data)
            except Exception as e:
                self.send_response(502); self.end_headers(); self.wfile.write(str(e).encode())
            return
        self.send_error(404)
    def do_GET(self):
        if self.path.startswith('/api/services/'):
            self._service_api('GET'); return
        if self.path == '/api/e5/sim-probe':
            with _e5_sim_lock:
                enabled = _e5_sim_enabled
            self._json(500 if enabled else 200,
                       {'status': 500 if enabled else 200,
                        'message': 'simulated HTTP 500' if enabled else 'healthy HTTP 200',
                        'simulationOnly': True}); return
        if self.path == '/api/e1/status':
            self._json(200, e1_status()); return
        if self.path == '/api/e2/status':
            self._json(200, e2_status()); return
        if self.path == '/api/e2/prepare/status':
            self._json(200, e2_prepare_status()); return
        if self.path == '/api/e3/status':
            self._json(200, e3_status()); return
        if self.path == '/api/e4/status':
            self._json(200, e4_status()); return
        if self.path == '/api/e5/status':
            self._json(200, e5_status()); return
        if self.path == '/api/e6/status':
            self._json(200, e6_status()); return
        if self.path.startswith('/proxy?'):
            target=parse_qs(urlparse(self.path).query).get('url',[''])[0]
            try:
                with urlopen(target, timeout=5) as r:
                    data=r.read(); self.send_response(r.status); self.send_header('Content-Type',r.headers.get('Content-Type','application/json')); self.end_headers(); self.wfile.write(data)
            except Exception as e:
                body=('{"error":"'+str(e).replace('"','\\"')+'"}').encode(); self.send_response(502); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(body)
            return
        return super().do_GET()

    def do_PUT(self):
        if self.path.startswith('/api/services/'):
            self._service_api('PUT'); return
        self.send_error(404)

    def do_DELETE(self):
        if self.path.startswith('/api/services/'):
            self._service_api('DELETE'); return
        self.send_error(404)

if __name__ == '__main__':
    os.chdir(os.path.dirname(__file__))
    ThreadingHTTPServer(('127.0.0.1',18080),Handler).serve_forever()
