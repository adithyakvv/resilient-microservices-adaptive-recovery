'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '..');
const html = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8');
const start = html.indexOf('function e4Ist(v)');
const end = html.indexOf('let e4PollTimer=null,', start);
assert(start >= 0 && end > start);
const context = {
  esc: value => String(value ?? '').replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;'),
  val: value => value === null || value === undefined || value === '' ? 'Unavailable' : String(value)
};
vm.createContext(context);
vm.runInContext(`${html.slice(start, end)}; globalThis.renderE4=e4Report; globalThis.cleanupLabel=e4CleanupLabel;`, context);

const reportPath = path.join(root, 'reports', 'e4-order-http500-E4-20260929-002146+0530.json');
const original = fs.readFileSync(reportPath, 'utf8');
const report = JSON.parse(original.replace(/^\uFEFF/, ''));
assert.equal(report.result, 'PASSED');
assert.equal(report.cleanup.status, undefined, 'historical JSON has no cleanup.status');
assert.equal(report.cleanup.faultOff, true);
assert.equal(report.cleanup.ready, true);
assert.equal(report.cleanup.error, null);
assert.equal(context.cleanupLabel(report.cleanup), 'Passed');
assert.equal(context.cleanupLabel({ faultOff: true, ready: null, error: null }), 'Unavailable', 'T5 or result alone must not imply cleanup');
assert.equal(context.cleanupLabel({ faultOff: false, ready: true, error: null }), 'Failed');
assert.equal(context.cleanupLabel({ faultOff: true, ready: true, error: 'reset failed' }), 'Failed');
const rendered = context.renderE4({ report, running: false });
assert.match(rendered, /Cleanup: Passed/);
assert.match(rendered, /48\.193 ms/);
assert.match(rendered, /1028\.283 ms/);
assert.match(rendered, /27\.904 ms/);
assert.match(rendered, /Order to Inventory latency threshold sustained/);
assert.doesNotMatch(rendered, /Orderâ/);
assert.equal(fs.readFileSync(reportPath, 'utf8'), original, 'historical report must remain byte-for-byte unchanged');

const dashboard = JSON.parse(fs.readFileSync(path.join(root, 'infrastructure/monitoring/prometheus/grafana-dashboard.json'), 'utf8'));
const panel = dashboard.panels.find(p => p.id === 104);
assert.deepEqual(panel.targets.map(t => t.expr), [
  'adaptive_recovery_e4_order_inventory_latency_ms',
  'adaptive_recovery_e4_mitigation_verified',
  'vector(500)'
]);
assert.deepEqual(panel.targets.map(t => t.legendFormat), [
  'Order to Inventory safe-probe latency (ms)',
  'Engine mitigation verified (0/1)',
  '500 ms trigger threshold'
]);
assert.equal(panel.fieldConfig.defaults.unit, 'ms');
const override = label => panel.fieldConfig.overrides.find(o => o.matcher.options === label).properties;
assert(override('Order to Inventory safe-probe latency (ms)').some(p => p.id === 'color' && p.value.fixedColor === 'blue'));
assert(override('Engine mitigation verified (0/1)').some(p => p.id === 'custom.axisPlacement' && p.value === 'right'));
assert(override('Engine mitigation verified (0/1)').some(p => p.id === 'color' && p.value.fixedColor === 'orange'));
assert(override('500 ms trigger threshold').some(p => p.id === 'custom.lineStyle' && p.value.fill === 'dash'));
console.log('E4_EVIDENCE_GUI_DASHBOARD_TEST=PASS');
