'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const html = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8');
const start = html.indexOf('let e4PollTimer=null');
const end = html.indexOf('function e5Ist', start);
assert(start >= 0 && end > start, 'E4 polling code must be present');
const reportPath = path.join(__dirname, '..', 'reports', 'e4-order-http500-E4-20260929-004302+0530.json');
const original = fs.readFileSync(reportPath, 'utf8');
const report = JSON.parse(original.replace(/^\uFEFF/, ''));
const running = { running: true, state: 'Running', report, activeExperiment: { name: 'E4', runId: report.runId } };
const terminal = { running: false, state: 'PASSED', report, activeExperiment: null };

function makePage() {
  const status = { innerHTML: '' };
  const details = { open: false, querySelectorAll: () => [] };
  const body = { innerHTML: '', querySelector: () => details };
  const button = { disabled: false };
  const pending = [];
  const stopped = [];
  const context = {
    get: () => new Promise(resolve => pending.push(resolve)),
    document: { getElementById: id => ({ 'e4-status': status, 'e4-report': body, 'e4-run': button })[id] },
    e4Report: s => `Run ${s.report?.runId || 'none'}: ${s.report?.result || 'none'}`,
    e4CleanupLabel: c => c?.faultOff === true && c?.ready === true && !c.error ? 'Passed' : 'Unavailable',
    esc: value => String(value ?? ''),
    clearInterval: id => stopped.push(id),
    setInterval: () => 42,
    confirm: () => false
  };
  vm.createContext(context);
  vm.runInContext(`${html.slice(start, end)};globalThis.e4StatusTest=e4Status;globalThis.e4PollTest=e4PollOnce;globalThis.setTimerTest=()=>{e4PollTimer=42};`, context);
  return { context, status, body, details, button, pending, stopped };
}

(async () => {
  const page = makePage();
  const first = page.context.e4StatusTest();
  page.pending.shift()(running);
  await first;
  assert.match(page.status.innerHTML, /Running/);
  assert.equal(page.details.open, true);
  const second = page.context.e4StatusTest();
  page.pending.shift()(terminal);
  await second;
  assert.match(page.status.innerHTML, /PASSED/);
  assert.doesNotMatch(page.status.innerHTML, /Running/);
  assert.equal(page.details.open, false);
  assert(page.body.innerHTML.includes(report.runId));

  // A delayed older Running response must not repaint a terminal response.
  const stale = page.context.e4StatusTest();
  const fresh = page.context.e4StatusTest();
  page.pending[1](terminal);
  await fresh;
  page.pending[0](running);
  await stale;
  page.pending.length = 0;
  assert.match(page.status.innerHTML, /PASSED/);

  // A repeated poll and a fresh page both obtain the terminal API state.
  const repeated = page.context.e4StatusTest();
  page.pending.shift()(terminal);
  await repeated;
  assert.match(page.status.innerHTML, /PASSED/);
  const refreshed = makePage();
  const afterRefresh = refreshed.context.e4StatusTest();
  refreshed.pending.shift()(terminal);
  await afterRefresh;
  assert.match(refreshed.status.innerHTML, /PASSED/);
  assert.equal(refreshed.details.open, false);

  page.context.setTimerTest();
  const finalPoll = page.context.e4PollTest();
  page.pending.shift()(terminal);
  await finalPoll;
  assert.deepEqual(page.stopped, [42], 'terminal poll stops the timer only after rendering');
  assert.match(page.status.innerHTML, /PASSED/);
  assert.equal(fs.readFileSync(reportPath, 'utf8'), original, 'saved report remains unchanged');
  console.log('E4_TERMINAL_POLLING_TEST=PASS');
})().catch(error => { console.error(error); process.exitCode = 1; });
