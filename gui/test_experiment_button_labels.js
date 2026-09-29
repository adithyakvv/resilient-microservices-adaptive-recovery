'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8');
const expected = ['Run E1', 'Run E2', 'Run E3', 'Run E4', 'Run E5', 'Run E6'];
function verifyButtons(html, label) {
  for (let n = 1; n <= 6; n++) {
    const re = new RegExp(`<button\\s+id="e${n}-run"\\s+onclick="runE${n}\\(\\)">([^<]+)</button>`);
    const match = html.match(re);
    assert(match, `${label}: E${n} button and existing handler should remain present`);
    assert.equal(match[1], expected[n - 1], `${label}: button text for E${n}`);
  }
  assert(!/#e3-run'\)\.textContent=/.test(html), `${label}: no script should replace the concise E3 label`);
  for (const [index, script] of [...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)].entries()) {
    if (script[1].trim()) new vm.Script(script[1], { filename: `${label}-inline-${index}.js` });
  }
}

verifyButtons(source, 'source');
fetch('http://127.0.0.1:18080/')
  .then(async response => {
    assert.equal(response.status, 200, 'served GUI should be reachable');
    verifyButtons(await response.text(), 'served page');
    console.log('EXPERIMENT_BUTTON_LABELS_TEST=PASS');
  })
  .catch(error => {
    console.error(`EXPERIMENT_BUTTON_LABELS_TEST=FAIL ${error.message}`);
    process.exitCode = 1;
  });
