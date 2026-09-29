(() => {
  const configs = {
    product: {
      title: 'Product Service',
      fields: [
        { name: 'sku', label: 'SKU', type: 'text', required: true },
        { name: 'name', label: 'Name', type: 'text', required: true },
        { name: 'price', label: 'Price', type: 'number', min: '0.01', step: '0.01', required: true },
        { name: 'active', label: 'Active', type: 'checkbox' }
      ]
    },
    inventory: {
      title: 'Inventory Service',
      fields: [
        { name: 'productId', label: 'Product ID', type: 'number', min: '1', step: '1', required: true },
        { name: 'quantity', label: 'Quantity', type: 'number', min: '0', step: '1', required: true }
      ],
      updateFields: ['quantity']
    },
    order: {
      title: 'Order Service',
      fields: [
        { name: 'productId', label: 'Product ID', type: 'number', min: '1', step: '1', required: true },
        { name: 'quantity', label: 'Quantity', type: 'number', min: '1', step: '1', required: true }
      ],
      displayFields: [
        { name: 'productId', label: 'Product ID' },
        { name: 'quantity', label: 'Quantity' },
        { name: 'status', label: 'Status' },
        { name: 'createdAt', label: 'Created' }
      ]
    }
  };
  const service = document.querySelector('[data-service]')?.dataset.service;
  const config = configs[service];
  if (!config) return;
  const api = `/api/services/${service}`;
  const escapeHtml = value => String(value ?? '').replace(/[&<>"']/g, ch => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  })[ch]);
  const status = document.getElementById('service-status');
  const health = document.getElementById('service-health');
  const records = document.getElementById('service-records');
  const form = document.getElementById('create-record');
  document.getElementById('service-title').textContent = config.title;
  document.title = `${config.title} — Adaptive Recovery Demo`;

  function fieldsMarkup(fields, row = null, edit = false) {
    return fields.map(field => {
      const value = row?.[field.name];
      const inputType = field.type === 'checkbox' ? 'checkbox' : field.type;
      const checked = field.type === 'checkbox' && value ? ' checked' : '';
      const disabled = !edit && row ? ' disabled' : '';
      const val = field.type === 'checkbox' ? '' : ` value="${escapeHtml(value ?? '')}"`;
      return `<label>${field.label}<input name="${field.name}" type="${inputType}"${val}${checked}${disabled}${field.min ? ` min="${field.min}"` : ''}${field.step ? ` step="${field.step}"` : ''}${field.required ? ' required' : ''}></label>`;
    }).join('');
  }

  function readFields(container, fields) {
    const value = {};
    for (const field of fields) {
      const input = container.elements.namedItem(field.name);
      value[field.name] = field.type === 'checkbox' ? input.checked : field.type === 'number' ? Number(input.value) : input.value.trim();
    }
    return value;
  }

  function rowHtml(row) {
    const id = row.id ?? row.productId;
    const cells = (config.displayFields || config.fields).map(field => `<td data-field="${field.name}">${escapeHtml(row[field.name])}</td>`).join('');
    return `<tr data-id="${escapeHtml(id)}"><td class="record-id">${escapeHtml(id)}</td>${cells}<td class="actions"><button type="button" data-action="edit">Edit</button><button type="button" data-action="delete" class="secondary">Delete</button></td></tr>`;
  }

  async function request(path, options = {}) {
    const response = await fetch(path, options);
    const text = await response.text();
    let body = null;
    try { body = text ? JSON.parse(text) : null; } catch { body = { message: text }; }
    if (!response.ok) throw new Error(body?.message || body?.error || `HTTP ${response.status}`);
    return body;
  }

  async function refresh() {
    document.getElementById('refresh-records').disabled = true;
    status.textContent = 'Refreshing…';
    try {
      const [healthResult, data] = await Promise.all([
        request(`${api}/health`), request(api)
      ]);
      const isUp = healthResult?.status === 'UP';
      health.textContent = isUp ? 'Health: UP' : `Health: ${healthResult?.status || 'Unavailable'}`;
      health.className = `badge ${isUp ? 'healthy' : 'unhealthy'}`;
      const rows = Array.isArray(data) ? data : Array.isArray(data?.content) ? data.content : [];
      records.innerHTML = rows.map(rowHtml).join('') || `<tr><td colspan="${config.fields.length + 2}" class="empty">No records</td></tr>`;
      status.textContent = `${rows.length} record${rows.length === 1 ? '' : 's'} loaded.`;
    } catch (error) {
      health.textContent = 'Health: unavailable';
      health.className = 'badge unhealthy';
      status.textContent = `Could not load ${config.title}: ${error.message}`;
    } finally {
      document.getElementById('refresh-records').disabled = false;
    }
  }

  form.innerHTML = fieldsMarkup(config.fields) + '<button type="submit">Create record</button>';
  form.addEventListener('submit', async event => {
    event.preventDefault();
    const button = form.querySelector('[type="submit"]');
    button.disabled = true;
    try {
      await request(api, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(readFields(form, config.fields)) });
      form.reset();
      status.textContent = 'Record created.';
      await refresh();
    } catch (error) {
      status.textContent = `Create failed: ${error.message}`;
    } finally { button.disabled = false; }
  });

  records.addEventListener('click', async event => {
    const button = event.target.closest('button[data-action]');
    if (!button) return;
    const row = button.closest('tr[data-id]');
    const id = row.dataset.id;
    if (button.dataset.action === 'delete') {
      if (!confirm(`Delete ${config.title} record ${id}?`)) return;
      button.disabled = true;
      try {
        await request(`${api}/${encodeURIComponent(id)}`, { method: 'DELETE' });
        status.textContent = `Record ${id} deleted.`;
        await refresh();
      } catch (error) { status.textContent = `Delete failed: ${error.message}`; button.disabled = false; }
      return;
    }
    if (button.dataset.action === 'edit') {
      const record = {};
      for (const field of (config.displayFields || config.fields)) {
        const cell = row.querySelector(`[data-field="${field.name}"]`);
        record[field.name] = cell.textContent;
      }
      // Inventory and Order identify their records by productId rather than an id property.
      record.id = id;
      const editable = (config.updateFields || config.fields.map(field => field.name)).filter(name => name !== 'id');
      row.innerHTML = `<td class="record-id">${escapeHtml(id)}</td>` + (config.displayFields || config.fields).map(column => {
        const field = config.fields.find(item => item.name === column.name);
        return `<td data-field="${column.name}">${field && editable.includes(field.name) ? fieldsMarkup([field], record, true) : escapeHtml(record[column.name])}</td>`;
      }).join('') + '<td class="actions"><button type="button" data-action="save">Save</button><button type="button" data-action="cancel" class="secondary">Cancel</button></td>';
      row.dataset.original = JSON.stringify(record);
      return;
    }
    if (button.dataset.action === 'cancel') { await refresh(); return; }
    if (button.dataset.action === 'save') {
      button.disabled = true;
      const payloadFields = config.updateFields || config.fields.map(field => field.name);
      try {
        const payload = {};
        for (const name of payloadFields) {
          const field = config.fields.find(item => item.name === name);
          const input = row.querySelector(`[name="${name}"]`);
          payload[name] = field.type === 'checkbox' ? input.checked : field.type === 'number' ? Number(input.value) : input.value.trim();
        }
        await request(`${api}/${encodeURIComponent(id)}`, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
        status.textContent = `Record ${id} updated.`;
        await refresh();
      } catch (error) { status.textContent = `Update failed: ${error.message}`; button.disabled = false; }
    }
  });

  document.getElementById('refresh-records').addEventListener('click', refresh);
  document.getElementById('back-dashboard').href = '/';
  refresh();
})();
