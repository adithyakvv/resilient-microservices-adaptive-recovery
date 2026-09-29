const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '..');
const html = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8');
const reportPath = path.join(root, 'reports', 'e3-order-inventory-delay-20260928-113950+0530.json');
const report = JSON.parse(fs.readFileSync(reportPath, 'utf8').replace(/^\uFEFF/, ''));

// Validate the served page's JavaScript syntax without evaluating unrelated
// GUI startup code or making network requests.
const scriptMatch = html.match(/<script>([\s\S]*?)<\/script>/i);
assert.ok(scriptMatch, 'GUI inline script block must exist');
new vm.Script(scriptMatch[1], { filename: 'gui/index.html inline script' });

const start = html.indexOf('function e3Report(s){');
const end = html.indexOf('\nfunction e3ProbeDetails', start);
assert.ok(start >= 0 && end > start, 'E3 report renderer should be delimited for regression testing');
const renderer = html.slice(start, end);
const harness = `
const esc=x=>String(x??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function val(v,pending=false){return v===null||v===undefined||v===''?'<span class="muted">'+(pending?'Pending':'Unavailable')+'</span>':esc(v)}
function ist(v,pending=false){if(!v)return val(v,pending);const d=new Date(v);if(Number.isNaN(d.getTime()))return '<span class="bad">Invalid timestamp</span>';return esc(new Intl.DateTimeFormat('en-IN',{timeZone:'Asia/Kolkata',day:'2-digit',month:'short',year:'numeric',hour:'2-digit',minute:'2-digit',second:'2-digit',hour12:true}).format(d)+' IST')}
function e3Median(values){const a=values.map(Number).filter(Number.isFinite).sort((x,y)=>x-y);if(!a.length)return null;const mid=Math.floor(a.length/2);return a.length%2?a[mid]:Number(((a[mid-1]+a[mid])/2).toFixed(3))}
${renderer}
e3Report({report: ${JSON.stringify(report)}, running: false});`;
const rendered = vm.runInNewContext(harness, {}, { filename: 'E3 report-render regression' });

for (const sample of report.measurements) {
  assert.ok(rendered.includes(String(sample.latencyMs)), `latency ${sample.latencyMs} should render`);
  assert.ok(rendered.includes(sample.phase), `${sample.phase} sample should render`);
}
assert.ok(rendered.includes('before median:</b> 22.944 ms'), 'before median must be computed from all saved readings');
assert.ok(rendered.includes('during median:</b> 1022.759 ms'), 'during median must be computed from all saved readings');
assert.ok(rendered.includes('after median:</b> 17.527 ms'), 'after median must be computed from all saved readings');
assert.equal(report.medians.before, 90.284, 'historical report must remain unchanged');
assert.ok(rendered.includes('OBSERVE_ONLY'), 'recorded experiment outcome must remain visible');
assert.ok(rendered.includes('>OBSERVE</b>') && rendered.includes('repeated dependency checks not yet stable'), 'actual Engine decision and reason must remain visible');
assert.ok(rendered.includes('Application-level Order→Inventory delay'), 'application-level fault mechanism must be identified');
assert.ok(rendered.includes('Not applicable — no Chaos resource used'), 'unused Chaos identity must be explicitly not applicable');
assert.ok(!rendered.includes('Name: <span class="muted">Unavailable</span>') && !rendered.includes('UID: <span class="muted">Unavailable</span>'), 'unused Chaos identity must not be mislabeled as missing evidence');

for (const marker of ['T0','T1','T2','T3','T4','T5']) {
  assert.match(rendered, new RegExp(`<b>${marker}<\\/b>: <span class="muted">Unavailable<\\/span>`), `${marker} must remain unavailable when absent from the saved JSON`);
}
assert.ok(rendered.includes('Time to stable state:</b> <span class="muted">Unavailable</span>'), 'duration must not be inferred from sample timestamps');
assert.match(rendered, /Readiness: before true, after true/, 'recorded readiness values should render');
assert.match(rendered, /Order health: <span class="muted">Unavailable<\/span>/, 'unrecorded Order health must remain unavailable');
assert.match(rendered, /Inventory health: <span class="muted">Unavailable<\/span>/, 'unrecorded Inventory health must remain unavailable');

// Future reports should display event timestamps and their evidence verbatim;
// this synthetic in-memory fixture does not modify the saved report.
const future = JSON.parse(JSON.stringify(report));
future.timestamps = { T0: '2026-09-28T11:39:50.000+05:30', T1: null, T2: null, T3: null, T4: null, T5: null };
future.timestampEvidence = { T0: 'Delay endpoint confirmed enabled=true and delayMs=1000.' };
const futureHtml = vm.runInNewContext(harness.replace(JSON.stringify(report), JSON.stringify(future)), {}, { filename: 'E3 timestamp evidence rendering' });
assert.match(futureHtml, /28 Sep(?:t)? 2026/, 'observed date should render in IST');
assert.ok(futureHtml.includes('11:39:50'), 'observed time should render in IST');
assert.ok(futureHtml.includes('Evidence: Delay endpoint confirmed enabled=true and delayMs=1000.'), 'timestamp evidence source should render');

// The latest report selected by the GUI has the observed 11:57 timestamps.
// Its run ID is preserved as saved; the elapsed value is derived from T5-T0.
const timedReportPath = path.join(root, 'reports', 'e3-order-inventory-delay-20260928-115659+0530.json');
const timedReport = JSON.parse(fs.readFileSync(timedReportPath, 'utf8').replace(/^\uFEFF/, ''));
assert.equal(timedReport.experimentOutcome, 'OBSERVE_ONLY', 'duration rendering must not alter the decision outcome');
const durationStart = html.indexOf('function e3StableDuration(t){');
const durationEnd = html.indexOf('\nlet e3PollTimer=null;', durationStart);
assert.ok(durationStart >= 0 && durationEnd > durationStart, 'E3 stable-duration rendering helpers must exist');
const durationHelpers = html.slice(durationStart, durationEnd);
const durationHarness = `function val(v,pending=false){return v===null||v===undefined||v===''?'<span class="muted">'+(pending?'Pending':'Unavailable')+'</span>':String(v)}\n${durationHelpers}`;
const durationContext = vm.createContext({});
vm.runInContext(durationHarness, durationContext);
const exactSeconds = durationContext.e3StableDuration(timedReport.timestamps);
assert.equal(exactSeconds, '9.86 seconds', 'saved T5-T0 timestamps should retain their exact fractional duration');

function renderDuration(timestamps) {
  const row = { innerHTML: '', querySelector: () => ({ textContent: 'Time to stable state:' }) };
  const section = { querySelector: () => ({ textContent: 'Timestamps and durations (IST)' }), querySelectorAll: () => [row] };
  const host = { querySelectorAll: () => [section] };
  durationContext.applyE3StableDuration(host, { report: { timestamps }, running: false });
  return row.innerHTML;
}
assert.ok(renderDuration({T0:'2026-09-28T11:57:02+05:30',T5:'2026-09-28T11:57:11+05:30'}).includes('9 seconds'), 'whole-second displayed timestamps should produce the requested nine-second duration');
assert.ok(renderDuration({T0:'2026-09-28T11:57:02+05:30'}).includes('Unavailable'), 'missing T5 should render Unavailable');
assert.ok(renderDuration({T0:'not-a-time',T5:'2026-09-28T11:57:11+05:30'}).includes('Unavailable'), 'invalid timestamps should render Unavailable');
assert.ok(renderDuration({T0:'2026-09-28T11:57:12+05:30',T5:'2026-09-28T11:57:11+05:30'}).includes('Unavailable'), 'out-of-order timestamps should render Unavailable');
assert.ok(html.includes('applyE3StableDuration(host,s)'), 'E3 status refresh must apply the derived duration after rendering');

process.stdout.write('E3_SAVED_REPORT_RENDER_TESTS=PASS\n');
