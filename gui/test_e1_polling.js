'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const html = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8');
const report = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'reports', 'e1-inventory-cpu-20260928-205421+0530.json'), 'utf8').replace(/^\uFEFF/, ''));
assert.equal(report.result, 'NOT_TRIGGERED');
assert.equal(report.cleanup.restoreVerify, true);
assert.ok(!html.includes('labelNotTriggeredOutcome'), 'E1 outcome must not have a separate append-on-poll timer');

function lastLine(prefix) {
  const start = html.lastIndexOf(prefix);
  assert.ok(start >= 0, `${prefix} must exist`);
  return html.slice(start, html.indexOf('\n', start));
}
const compact = html.slice(html.indexOf('function compactExperiment('), html.indexOf('\n', html.indexOf('function compactExperiment(')));
const source = [lastLine('function reportHtml(s){'), lastLine('async function e1Status(){'), compact].join('\n');

class FakeElement {
  constructor() { this.value = ''; this.details = null; this.disabled = false; }
  get innerHTML() { return this.value; }
  set innerHTML(value) { this.value = value; this.details = value.includes('data-report-details') ? { open: false } : null; }
  querySelector(selector) {
    if (selector === 'details[data-report-details]' || selector === 'details') return this.details;
    if (selector === '.e1-box') return this.value.includes('e1-box') ? {} : null;
    return null;
  }
}
const elements = Object.fromEntries(['e1-status', 'e1-report', 'e1-run'].map(id => [id, new FakeElement()]));
const document = {
  getElementById: id => elements[id],
  querySelector: selector => selector.startsWith('#e1-report ') ? elements['e1-report'].querySelector(selector.slice('#e1-report '.length)) : null,
};
const esc = value => String(value ?? '').replace(/[&<>"']/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[character]);
const context = vm.createContext({
  document, esc, get: async () => ({ report, running: false, state: 'NOT_TRIGGERED' }),
  val: (v, pending) => v == null || v === '' ? (pending ? 'Pending' : 'Unavailable') : esc(v),
  ist: v => v || 'Unavailable', resourceFields: () => '<div>resource snapshot</div>',
  quality: () => [], statusFor: () => 'Completed', experimentFor: () => 'Not triggered — CPU threshold was not sustained',
  evaluationHtml: () => '<div>Engine preview</div>', e1Starting: false, e1LaunchError: '',
});
vm.runInContext(source, context);

(async () => {
  for (let poll = 0; poll < 8; poll++) {
    await context.e1Status();
    const rendered = elements['e1-report'].innerHTML;
    assert.equal((rendered.match(/Experiment result:/g) || []).length, 1, `poll ${poll}: outcome must be replaced, not appended`);
    assert.equal((rendered.match(/Run summary:/g) || []).length, 1, `poll ${poll}: one summary`);
    assert.equal((rendered.match(/E1-20260928-205421\+0530/g) || []).length, 1, `poll ${poll}: same saved report`);
    assert.equal((rendered.match(/e1-outcome/g) || []).length, 0, `poll ${poll}: no legacy appended outcome`);
    assert.equal((rendered.match(/Full E1 report/g) || []).length, 1, `poll ${poll}: one disclosure`);
  }
  const response = await fetch('http://127.0.0.1:18080/');
  assert.equal(response.status, 200, 'running GUI must serve the page');
  const served = await response.text();
  assert.equal(served, html, 'running GUI must serve the updated E1 renderer');
  assert.ok(served.includes('id="e1-panel"'), 'served page must retain E1');
  console.log('E1_REPEATED_POLL_RENDER=PASS');
})().catch(error => { console.error(error); process.exitCode = 1; });
