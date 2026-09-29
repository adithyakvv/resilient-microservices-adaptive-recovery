'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const html = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8');
const report = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'reports', 'e2-inventory-memory-20260928-214444+0530.json'), 'utf8').replace(/^\uFEFF/, ''));
assert.equal(report.result, 'PREFLIGHT_BLOCKED');
const script = html.match(/<script>([\s\S]*?)<\/script>/i);
assert.ok(script);
new vm.Script(script[1], {filename: 'gui/index.html'});
const start = html.indexOf('function e2PreflightLabel(');
const end = html.indexOf('async function e2Status(', start);
assert.ok(start >= 0 && end > start);
const source = html.slice(start, end);
const esc = v => String(v ?? '');
const context = vm.createContext({
  esc,
  e2Val: (v, pending) => v == null || v === '' ? (pending ? 'Pending' : 'Unavailable') : esc(v),
  ist: v => v || 'Unavailable',
  resourceFields: () => '<div>resources</div>',
});
vm.runInContext(source, context);
const label = context.e2PreflightLabel(report);
assert.equal(label, 'Blocked — baseline memory above 0.55 guard');
const rendered = context.e2Report({report, running: false});
assert.ok(rendered.includes('<b>Preflight outcome:</b> Blocked — baseline memory above 0.55 guard'));
assert.ok(rendered.includes('<b>Experiment outcome:</b> Not started — no Chaos or Engine action'));
assert.ok(rendered.includes('<b>Cleanup/restoration:</b> Passed — exact baseline verified'));
assert.ok(!rendered.includes('Completed · Action not verified'));
assert.ok(rendered.includes('E2-20260928-214444+0530'));
const missing = {...report, preflight: {...report.preflight, baselineMemoryRatio: null}};
assert.equal(context.e2PreflightLabel(missing), 'Blocked — distinct fresh baseline memory samples unavailable');

fetch('http://127.0.0.1:18080/').then(async response => {
  assert.equal(response.status, 200);
  assert.equal(await response.text(), html, 'running GUI must serve updated E2 mapping');
  console.log('E2_PREFLIGHT_GUI_TEST=PASS');
}).catch(error => { console.error(error); process.exitCode = 1; });
