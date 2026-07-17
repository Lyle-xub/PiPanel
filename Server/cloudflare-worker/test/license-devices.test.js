import assert from 'node:assert/strict';
import test from 'node:test';

import worker from '../src/index.js';

const licenseKey = 'license-for-tests';

function license(instance, activation = 2) {
  return {
    id: 'lic_test',
    object: 'license',
    product_id: 'prod_test',
    status: 'active',
    key: licenseKey,
    activation,
    activation_limit: 2,
    instance,
  };
}

function instance(id, name) {
  return { id, object: 'license-instance', name, status: 'active' };
}

function makeEnv(initialIds = []) {
  const values = new Map([[`instances:${licenseKey}`, JSON.stringify(initialIds)]]);
  return {
    CREEM_API_KEY: 'test-api-key',
    CREEM_API_BASE_URL: 'https://creem.test',
    PIPANEL_LICENSES: {
      async get(key) { return values.get(key) ?? null; },
      async put(key, value) { values.set(key, value); },
      async delete(key) { values.delete(key); },
      values,
    },
  };
}

function validationRequest(instanceId) {
  return new Request('https://worker.test/license/validate', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ key: licenseKey, instance_id: instanceId }),
  });
}

test('validation expands the current Creem instance into every tracked device', async (t) => {
  const current = instance('inst_current', 'Current Mac');
  const other = instance('inst_other', 'Other Mac');
  const env = makeEnv([current.id, other.id]);
  const originalFetch = globalThis.fetch;
  t.after(() => { globalThis.fetch = originalFetch; });

  globalThis.fetch = async (_url, options) => {
    const payload = JSON.parse(options.body);
    return Response.json(license(payload.instance_id === current.id ? current : other));
  };

  const response = await worker.fetch(validationRequest(current.id), env, {});
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.deepEqual(body.instance.map((item) => item.id), [current.id, other.id]);
  assert.equal(body.activation, 2);
});

test('validation remembers an older current device and keeps existing tracked devices', async (t) => {
  const current = instance('inst_current', 'Current Mac');
  const other = instance('inst_other', 'Other Mac');
  const env = makeEnv([other.id]);
  const originalFetch = globalThis.fetch;
  t.after(() => { globalThis.fetch = originalFetch; });

  globalThis.fetch = async (_url, options) => {
    const payload = JSON.parse(options.body);
    return Response.json(license(payload.instance_id === current.id ? current : other));
  };

  const response = await worker.fetch(validationRequest(current.id), env, {});
  const body = await response.json();
  assert.deepEqual(body.instance.map((item) => item.id), [current.id, other.id]);
  assert.deepEqual(
    JSON.parse(env.PIPANEL_LICENSES.values.get(`instances:${licenseKey}`)),
    [other.id, current.id]
  );
});

test('definitively removed devices disappear from KV without breaking current validation', async (t) => {
  const current = instance('inst_current', 'Current Mac');
  const staleId = 'inst_removed';
  const env = makeEnv([current.id, staleId]);
  const originalFetch = globalThis.fetch;
  t.after(() => { globalThis.fetch = originalFetch; });

  globalThis.fetch = async (_url, options) => {
    const payload = JSON.parse(options.body);
    if (payload.instance_id === staleId) return new Response('{}', { status: 404 });
    return Response.json(license(current, 1));
  };

  const response = await worker.fetch(validationRequest(current.id), env, {});
  const body = await response.json();
  assert.deepEqual(body.instance.map((item) => item.id), [current.id]);
  assert.deepEqual(
    JSON.parse(env.PIPANEL_LICENSES.values.get(`instances:${licenseKey}`)),
    [current.id]
  );
});
