'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const html = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8');
assert.match(html, /id="e2-prepare"[^>]*>Prepare E2</);
assert.match(html, /id="e2-run"[^>]*>Run E2</);
const code = html.match(/<script>([\s\S]*?)<\/script>/i)?.[1];
assert.ok(code);
new vm.Script(code, {filename: 'gui/index.html'});
const fn = code.slice(code.indexOf('function e2PreparationHtml('), code.indexOf('async function e2PrepareStatus('));
const context = vm.createContext({esc: value => String(value ?? ''), ist: value => String(value ?? 'Unavailable') + ' IST'});
vm.runInContext(fn, context);
const base = {running: false, preparation: {state: 'Ready', reason: 'three fresh readings below guard', willRestart: 'No', baseline: {before: [
  {sourceTimestamp: '2026-09-29T02:00:00Z', window: '15s', memoryRatio: .48, podUid: 'pod-a'},
  {sourceTimestamp: '2026-09-29T02:00:15Z', window: '15s', memoryRatio: .49, podUid: 'pod-a'},
  {sourceTimestamp: '2026-09-29T02:00:30Z', window: '15s', memoryRatio: .50, podUid: 'pod-a'},
]}, restart: {attempted: false}}};
assert.match(context.e2PreparationHtml(base), /Preparation: Ready/);
assert.match(context.e2PreparationHtml(base), /Inventory restart: No/);
assert.match(context.e2PreparationHtml(base), /Fresh baseline readings \(3\/3\)/);
const blocked = {running: false, preparation: {...base.preparation, state: 'Blocked', reason: 'baseline remains above guard', willRestart: 'Yes — one Inventory pod replacement', restart: {attempted: true, count: 1, oldUid: 'old', newUid: 'new', verified: true}}};
assert.match(context.e2PreparationHtml(blocked), /Preparation: Blocked/);
assert.match(context.e2PreparationHtml(blocked), /Restart count: 1/);
assert.match(code, /if\(!confirm\('Prepare E2\?/);
assert.match(code, /fetch\('\/api\/e2\/prepare',\{method:'POST'\}\)/);
assert.doesNotMatch(fn, /\/api\/e2\/run/);
console.log('E2_PREPARE_GUI_MOCKS=PASS');
