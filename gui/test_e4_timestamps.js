'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '..');
const html = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8');
const start = html.indexOf('function e4Ist(v)');
const end = html.indexOf('let e4PollTimer=null,', start);
assert(start >= 0 && end > start, 'E4 render block should be present in the served page');
const context = {
  esc: value => String(value ?? '').replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;'),
  val: value => value === null || value === undefined || value === '' ? '<span class="muted">Unavailable</span>' : String(value)
};
vm.createContext(context);
vm.runInContext(`${html.slice(start, end)}; globalThis.renderE4=e4Report; globalThis.stable=e4StableDuration;`, context);

const reportPath = path.join(root, 'reports', 'e4-order-http500-E4-20260928-115817+0530.json');
const raw = fs.readFileSync(reportPath, 'utf8');
const historical = JSON.parse(raw.replace(/^\uFEFF/, ''));
assert.equal(historical.result, 'PASSED');
assert.equal(historical.timestamps, undefined, 'historical lifecycle timestamps were never recorded');
assert.equal(historical.measurements.length, 6);
assert(historical.measurements.every(item => item.probe.at), 'all six probe timestamps are saved');
assert(historical.engineEvaluations.every(item => item.at), 'Engine evaluation timestamps are saved');
const rendered = context.renderE4({ report: historical, running: false });
assert.match(rendered, /E4 · Completed · PASSED/);
assert.match(rendered, /Unavailable/, 'missing lifecycle timestamps remain unavailable');
assert.match(rendered, /1086\.781 ms/);
assert.match(rendered, /997 IST/, 'per-probe timestamps are rendered with millisecond precision in IST');
assert.match(rendered, /OBSERVE/);

const definitions = {
  T0: 'Delay enabled: the Order delay endpoint response confirms enabled=true and delayMs=1000.',
  T5: 'Stable state restored: cleanup independently confirms delay disabled and Order Ready.'
};
const durationDefinition = 'Time to stable state = T5 - T0, where T0 is confirmed delay enable and T5 is confirmed delay off plus Order Ready.';
const timed = {
  runId: 'fixture', result: 'PASSED', timestamps: { T0: '2026-09-28T10:00:00+05:30', T5: '2026-09-28T10:00:09+05:30' },
  timestampDefinitions: definitions, timestampEvidence: {}, durationDefinitions: { timeToStableState: durationDefinition }, measurements: []
};
assert.equal(context.stable(timed), '9.000 s');
assert.match(context.renderE4({ report: timed }), /9\.000 s/);
assert.equal(context.stable({ ...timed, timestamps: { T0: timed.timestamps.T0 } }), null, 'missing T5 stays unavailable');
assert.equal(context.stable({ ...timed, timestamps: { T0: timed.timestamps.T0, T5: 'not-a-time' } }), null, 'invalid timestamp stays unavailable');
assert.equal(context.stable({ ...timed, timestamps: { T0: timed.timestamps.T5, T5: timed.timestamps.T0 } }), null, 'out-of-order timestamps do not produce duration');
assert.equal(context.stable({ ...timed, durationDefinitions: {} }), null, 'duration requires the documented E4 definition');

assert.equal(fs.readFileSync(reportPath, 'utf8'), raw, 'historical report must remain byte-for-byte unchanged');
console.log('E4_GUI_TIMESTAMPS_TEST=PASS');
