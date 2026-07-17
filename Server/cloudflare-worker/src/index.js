// PiPanel's server-side entitlement boundary. It owns the Creem API key, proxies every license
// action, delivers purchases, reacts to refunds, and records one non-renewable seven-day trial per
// installation. No Creem credential is shipped in the macOS app.
//
// Endpoint paths, request/response fields, webhook event names, and the webhook signing scheme
// below are confirmed against docs.creem.io (not guessed) — see
// Server/cloudflare-worker/README.md for the full source list. Two things remain genuinely
// unconfirmed without a live account, both handled defensively below:
//   - whether `license_keys` arrives directly on the `checkout.completed` webhook payload, or
//     only via a follow-up `GET /v1/checkouts/{id}` call (the docs' schema says the field exists
//     on the Checkout entity, but the one example webhook payload didn't show it populated)
//   - the exact existence/shape of that `GET /v1/checkouts/{id}` endpoint (inferred by REST
//     convention from the confirmed `POST /v1/checkouts`, not independently confirmed)
//
// Required environment variables (see README.md for full setup steps):
//   CREEM_API_KEY           - Creem seller API key (secret; used server-side for checkout
//                             creation and refund-driven deactivation)
//   CREEM_WEBHOOK_SECRET    - Creem webhook signing secret (Developers → Webhooks page)
//   CREEM_API_BASE_URL      - "https://api.creem.io" (prod) or "https://test-api.creem.io"
//                             (Creem's test mode) — defaults to prod if unset
//   RESEND_API_KEY          - for sending license/recovery emails
//   CREEM_PRODUCT_SINGLE / CREEM_PRODUCT_DUAL / CREEM_PRODUCT_MULTI
//                           - the three Creem Product IDs for the single/dual/multi-device tiers
//   CHECKOUT_SUCCESS_URL    - where Creem redirects after a successful payment
//   RESEND_FROM             - "PiPanel <support@pipanel.app>"-style from-address
//
// Required binding:
//   PIPANEL_LICENSES (KV namespace) — stores permanent trial records, short-lived claim/recovery
//   tokens, long-lived checkout/email license lookups, and license instance IDs used for refunds.

const TIER_PRODUCT_ENV = {
  single: 'CREEM_PRODUCT_SINGLE',
  dual: 'CREEM_PRODUCT_DUAL',
  multi: 'CREEM_PRODUCT_MULTI',
};

const CLAIM_TTL_SECONDS = 60 * 60; // 1 hour to complete a purchase and have the app claim it
const RECOVERY_TTL_SECONDS = 30 * 60; // 30 minutes for a recovery link to be used
const TRIAL_DURATION_MS = 7 * 24 * 60 * 60 * 1000;
const MAX_DEVICE_ID_LENGTH = 128;

function creemApiBase(env) {
  return env.CREEM_API_BASE_URL ?? 'https://api.creem.io';
}

// The marketing site (pipanel.app / lyle-xub.github.io/PiPanel) calls /create-checkout-session
// directly from browser JS to start a purchase, which makes this a cross-origin fetch — browsers
// send a preflight OPTIONS request first (application/json isn't a CORS-safelisted content type),
// and then require Access-Control-Allow-Origin on the actual response before JS can read it.
const ALLOWED_ORIGINS = new Set([
  'https://pipanel.app',
  'https://lyle-xub.github.io',
]);

function corsHeaders(origin) {
  if (!ALLOWED_ORIGINS.has(origin)) return {};
  return {
    'Access-Control-Allow-Origin': origin,
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
  };
}

function withCors(response, cors) {
  const headers = new Headers(response.headers);
  for (const [key, value] of Object.entries(cors)) headers.set(key, value);
  return new Response(response.body, { status: response.status, headers });
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const cors = corsHeaders(request.headers.get('Origin') ?? '');

    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: cors });
    }

    try {
      if (request.method === 'POST' && url.pathname === '/create-checkout-session') {
        return withCors(await handleCreateCheckoutSession(request, env), cors);
      }
      if (request.method === 'POST' && url.pathname === '/webhook/creem') {
        return await handleCreemWebhook(request, env);
      }
      if (request.method === 'GET' && url.pathname === '/claim') {
        return withCors(await handleClaim(request, env), cors);
      }
      if (request.method === 'POST' && url.pathname === '/license/activate') {
        return await handleLicenseAction(request, env, 'activate');
      }
      if (request.method === 'POST' && url.pathname === '/license/validate') {
        return await handleLicenseAction(request, env, 'validate');
      }
      if (request.method === 'POST' && url.pathname === '/license/deactivate') {
        return await handleLicenseAction(request, env, 'deactivate');
      }
      if (request.method === 'POST' && url.pathname === '/trial/start') {
        return await handleTrialRequest(request, env, true);
      }
      if (request.method === 'POST' && url.pathname === '/trial/status') {
        return await handleTrialRequest(request, env, false);
      }
      if (request.method === 'POST' && url.pathname === '/trial/cancel') {
        return await handleTrialCancellation(request, env);
      }
      if (request.method === 'POST' && url.pathname === '/report-activation') {
        return await handleReportActivation(request, env);
      }
      if (request.method === 'POST' && url.pathname === '/recover/request') {
        return withCors(await handleRecoverRequest(request, env), cors);
      }
      if (request.method === 'GET' && url.pathname === '/recover/confirm') {
        return await handleRecoverConfirm(request, env);
      }
      return withCors(json({ error: 'not found' }, 404), cors);
    } catch (err) {
      console.error(err);
      return withCors(json({ error: 'internal error' }, 500), cors);
    }
  },
};

// ---------- purchase ----------

async function handleCreateCheckoutSession(request, env) {
  const { tier, claimToken } = await request.json();
  const productEnvKey = TIER_PRODUCT_ENV[tier];
  const productId = productEnvKey ? env[productEnvKey] : null;
  if (!productId) return json({ error: 'invalid tier' }, 400);
  if (!claimToken) return json({ error: 'missing claimToken' }, 400);

  // Confirmed shape: POST /v1/checkouts, x-api-key header, product_id required, metadata is a
  // real key-value field that gets echoed back on the checkout.completed webhook.
  const response = await fetch(`${creemApiBase(env)}/v1/checkouts`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': env.CREEM_API_KEY,
    },
    body: JSON.stringify({
      product_id: productId,
      request_id: claimToken,
      success_url: env.CHECKOUT_SUCCESS_URL,
      metadata: { claimToken, tier },
    }),
  });

  if (!response.ok) {
    console.error('Creem checkout creation failed', await response.text());
    return json({ error: 'checkout creation failed' }, 502);
  }

  const body = await response.json();
  if (!body.checkout_url) {
    console.error('Creem checkout response missing checkout_url', JSON.stringify(body));
    return json({ error: 'checkout creation failed' }, 502);
  }
  return json({ url: body.checkout_url });
}

// ---------- webhook ----------

async function handleCreemWebhook(request, env) {
  const rawBody = await request.text();

  if (!(await verifyCreemWebhook(request, rawBody, env))) {
    return new Response('invalid signature', { status: 400 });
  }

  const event = JSON.parse(rawBody);

  // Confirmed complete event catalog: checkout.completed, subscription.*, refund.created,
  // dispute.created. Only the first and refund.created matter for a one-time-purchase product.
  if (event.eventType === 'checkout.completed') {
    await fulfilCreemCheckout(event, env);
  } else if (event.eventType === 'refund.created') {
    await handleCreemRefund(event, env);
  }

  return json({ received: true });
}

async function verifyCreemWebhook(request, rawBody, env) {
  // Confirmed: HMAC-SHA256 over the raw body, hex digest, compared against the `creem-signature`
  // header, using the webhook secret from Developers → Webhooks in the Creem dashboard.
  if (!env.CREEM_WEBHOOK_SECRET) {
    console.error('CREEM_WEBHOOK_SECRET not set — accepting webhook unverified (dev only)');
    return true;
  }

  const signature = request.headers.get('creem-signature');
  if (!signature) return false;

  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(env.CREEM_WEBHOOK_SECRET),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(rawBody));
  const expected = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, '0')).join('');
  return timingSafeEqual(expected, signature);
}

function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return result === 0;
}

async function fulfilCreemCheckout(event, env) {
  // Confirmed field paths on checkout.completed: object.customer.email, object.metadata
  // (echoes back what create-checkout sent), object.id (the checkout id, needed below to
  // correlate a later refund back to this purchase).
  const checkout = event.object ?? {};
  const email = checkout.customer?.email ?? null;
  const claimToken = checkout.metadata?.claimToken ?? checkout.request_id;
  const checkoutId = checkout.id;

  const licenseKey = await resolveLicenseKey(checkout, checkoutId, env);
  if (!licenseKey) {
    console.error('Creem webhook: could not resolve a license key for checkout', checkoutId);
    return;
  }

  if (claimToken) {
    await env.PIPANEL_LICENSES.put(`claim:${claimToken}`, JSON.stringify({ licenseKey }), {
      expirationTtl: CLAIM_TTL_SECONDS,
    });
  }
  if (checkoutId) {
    // Long-lived (no TTL) — refunds arrive well after any claim token would have expired, and
    // this is the only confirmed-present correlation ID on the refund.created event.
    await env.PIPANEL_LICENSES.put(`checkout:${checkoutId}`, licenseKey);
  }
  if (email) {
    await env.PIPANEL_LICENSES.put(`email:${email.toLowerCase()}`, licenseKey);
    await sendLicenseEmail(env, { email, licenseKey });
  }
}

/// Unconfirmed whether `license_keys` is populated directly on the checkout.completed payload —
/// try that first, then fall back to fetching the checkout by id.
async function resolveLicenseKey(checkout, checkoutId, env) {
  const inline = checkout.license_keys?.[0]?.key;
  if (inline) return inline;

  if (!checkoutId) return null;
  const response = await fetch(`${creemApiBase(env)}/v1/checkouts/${checkoutId}`, {
    headers: { 'x-api-key': env.CREEM_API_KEY },
  });
  if (!response.ok) {
    console.error('Follow-up GET /v1/checkouts/{id} failed', checkoutId, await response.text());
    return null;
  }
  const body = await response.json();
  return body.license_keys?.[0]?.key ?? null;
}

async function handleCreemRefund(event, env) {
  // Confirmed field paths on refund.created: object.checkout (the checkout id — our correlation
  // key), object.refund_amount, and a nested object.transaction.amount_paid for the original
  // amount. No license key field is confirmed present on this event, hence the checkout-id
  // lookup instead of trying to read a license key directly off the refund payload.
  const refund = event.object ?? {};
  const checkoutId = refund.checkout;
  if (!checkoutId) {
    console.error('Creem refund webhook: no checkout id found', JSON.stringify(event));
    return;
  }

  const refundedAmount = refund.refund_amount;
  const totalAmount = refund.transaction?.amount_paid;
  // Only auto-suspend on a *full* refund — partial refunds shouldn't kill an activation. If the
  // amounts aren't present on the payload, err on the side of suspending (a refund event firing
  // at all is a strong enough signal for a one-time-purchase product).
  if (typeof refundedAmount === 'number' && typeof totalAmount === 'number' && refundedAmount < totalAmount) {
    return;
  }

  const licenseKey = await env.PIPANEL_LICENSES.get(`checkout:${checkoutId}`);
  if (!licenseKey) {
    console.error('Creem refund webhook: no license key on file for checkout', checkoutId);
    return;
  }

  const instanceIds = await readLicenseInstanceIds(env, licenseKey);
  for (const instanceId of instanceIds) {
    await deactivateCreemInstance(env, licenseKey, instanceId);
  }
  await env.PIPANEL_LICENSES.delete(`instances:${licenseKey}`);
}

// ---------- trial ----------

async function handleTrialRequest(request, env, createIfMissing) {
  const body = await readJson(request);
  const deviceId = typeof body.deviceId === 'string' ? body.deviceId.trim() : '';
  if (!isValidDeviceId(deviceId)) return json({ error: 'invalid deviceId' }, 400);

  // Store only a one-way digest. The record deliberately has no KV TTL: deleting it when the
  // trial expires would allow the same installation to start another trial immediately.
  const deviceHash = await sha256Hex(deviceId);
  const key = `trial:${deviceHash}`;
  let record = await env.PIPANEL_LICENSES.get(key, 'json');

  if (!record && createIfMissing) {
    const startedAt = new Date();
    record = {
      version: 1,
      startedAt: startedAt.toISOString(),
      expiresAt: new Date(startedAt.getTime() + TRIAL_DURATION_MS).toISOString(),
    };
    await env.PIPANEL_LICENSES.put(key, JSON.stringify(record));
  }

  const serverTime = new Date();
  if (!record) {
    return json({ status: 'not_started', serverTime: serverTime.toISOString() }, 404);
  }

  const status = trialStatus(record, serverTime);
  return json({
    status,
    startedAt: record.startedAt,
    expiresAt: record.expiresAt,
    cancelledAt: record.cancelledAt ?? null,
    serverTime: serverTime.toISOString(),
  });
}

/// Ends a live trial immediately without deleting its permanent eligibility record. Deleting the
/// KV entry would turn cancellation into a way to obtain another seven-day trial, so cancellation
/// is an irreversible timestamp on the existing record and the endpoint is idempotent.
async function handleTrialCancellation(request, env) {
  const body = await readJson(request);
  const deviceId = typeof body.deviceId === 'string' ? body.deviceId.trim() : '';
  if (!isValidDeviceId(deviceId)) return json({ error: 'invalid deviceId' }, 400);

  const deviceHash = await sha256Hex(deviceId);
  const key = `trial:${deviceHash}`;
  const record = await env.PIPANEL_LICENSES.get(key, 'json');
  if (!record) {
    return json({
      status: 'not_started',
      serverTime: new Date().toISOString(),
    }, 404);
  }

  const serverTime = new Date();
  if (!record.cancelledAt) {
    record.version = 2;
    record.cancelledAt = serverTime.toISOString();
    await env.PIPANEL_LICENSES.put(key, JSON.stringify(record));
  }

  return json({
    status: 'cancelled',
    startedAt: record.startedAt,
    expiresAt: record.expiresAt,
    cancelledAt: record.cancelledAt,
    serverTime: serverTime.toISOString(),
  });
}

function trialStatus(record, serverTime) {
  if (record.cancelledAt) return 'cancelled';
  const expiresAt = new Date(record.expiresAt);
  return expiresAt.getTime() > serverTime.getTime() ? 'trial' : 'expired';
}

function isValidDeviceId(value) {
  return value.length >= 16
    && value.length <= MAX_DEVICE_ID_LENGTH
    && /^[A-Za-z0-9._-]+$/.test(value);
}

async function sha256Hex(value) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

// ---------- Creem license proxy ----------

const LICENSE_FIELDS = {
  activate: ['key', 'instance_name'],
  validate: ['key', 'instance_id'],
  deactivate: ['key', 'instance_id'],
};

async function handleLicenseAction(request, env, action) {
  if (!env.CREEM_API_KEY) return json({ error: 'license service unavailable' }, 503);

  const body = await readJson(request);
  const fields = LICENSE_FIELDS[action];
  const payload = {};
  for (const field of fields) {
    const value = typeof body[field] === 'string' ? body[field].trim() : '';
    if (!value || value.length > 256) return json({ error: `invalid ${field}` }, 400);
    payload[field] = value;
  }

  const response = await fetch(`${creemApiBase(env)}/v1/licenses/${action}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'x-api-key': env.CREEM_API_KEY,
    },
    body: JSON.stringify(payload),
  });
  let responseText = await response.text();

  if (response.ok) {
    const license = parseJson(responseText);
    if (action === 'activate') {
      const instances = normalizeInstances(license?.instance);
      const activated = instances.find((instance) => instance?.name === payload.instance_name)
        ?? instances.at(-1);
      if (activated?.id) await rememberLicenseInstance(env, payload.key, activated.id);
    } else if (action === 'validate') {
      // Creem returns only the instance named by instance_id even though `activation` is the
      // total number of active instances. Expand the validated response with every other instance
      // PiPanel has registered for this license so the count and device rows describe one snapshot.
      await rememberLicenseInstance(env, payload.key, payload.instance_id);
      const instances = await loadLicenseInstances(
        env,
        payload.key,
        payload.instance_id,
        license
      );
      if (license && instances.length > 0) {
        license.instance = instances;
        responseText = JSON.stringify(license);
      }
    } else if (action === 'deactivate') {
      await forgetLicenseInstance(env, payload.key, payload.instance_id);
    }
  } else {
    console.error(`Creem license ${action} failed`, response.status);
  }

  return new Response(responseText || '{}', {
    status: response.status,
    headers: { 'Content-Type': response.headers.get('Content-Type') ?? 'application/json' },
  });
}

function parseJson(value) {
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

function normalizeInstances(value) {
  if (Array.isArray(value)) return value;
  return value && typeof value === 'object' ? [value] : [];
}

async function loadLicenseInstances(env, licenseKey, currentInstanceId, currentLicense) {
  const currentInstances = normalizeInstances(currentLicense?.instance);
  const currentInstance = currentInstances.find((instance) => instance?.id === currentInstanceId)
    ?? currentInstances[0];
  const trackedIds = await readLicenseInstanceIds(env, licenseKey);
  const instanceIds = [...new Set([currentInstanceId, ...trackedIds])];
  const instances = [];
  const staleIds = [];

  for (const instanceId of instanceIds) {
    if (currentInstance?.id === instanceId) {
      instances.push(currentInstance);
      continue;
    }

    let response;
    try {
      response = await fetch(`${creemApiBase(env)}/v1/licenses/validate`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'x-api-key': env.CREEM_API_KEY,
        },
        body: JSON.stringify({ key: licenseKey, instance_id: instanceId }),
      });
    } catch (error) {
      // A temporary network failure must not erase a device that can reappear on the next refresh.
      console.error('Creem instance lookup failed', instanceId, error);
      continue;
    }

    if (!response.ok) {
      // These statuses definitively identify a dead instance. Keep rate-limited/server-error IDs
      // so a later refresh can recover them.
      if ([404, 409, 410].includes(response.status)) staleIds.push(instanceId);
      continue;
    }

    const license = parseJson(await response.text());
    const matchingInstances = normalizeInstances(license?.instance);
    const instance = matchingInstances.find((candidate) => candidate?.id === instanceId)
      ?? matchingInstances[0];
    if (instance?.id) instances.push(instance);
  }

  for (const staleId of staleIds) {
    await forgetLicenseInstance(env, licenseKey, staleId);
  }

  // A malformed upstream response should never create duplicate SwiftUI rows.
  return [...new Map(instances.map((instance) => [instance.id, instance])).values()];
}

function parseStoredInstanceIds(raw) {
  if (!raw) return [];
  try {
    const value = JSON.parse(raw);
    if (!Array.isArray(value)) return [];
    return [...new Set(value.filter((item) => typeof item === 'string' && item.length > 0))];
  } catch {
    return [];
  }
}

async function readLicenseInstanceIds(env, licenseKey) {
  const raw = await env.PIPANEL_LICENSES.get(`instances:${licenseKey}`);
  return parseStoredInstanceIds(raw);
}

async function rememberLicenseInstance(env, licenseKey, instanceId) {
  const storageKey = `instances:${licenseKey}`;
  const instanceIds = await readLicenseInstanceIds(env, licenseKey);
  if (!instanceIds.includes(instanceId)) {
    instanceIds.push(instanceId);
    await env.PIPANEL_LICENSES.put(storageKey, JSON.stringify(instanceIds));
  }
}

async function forgetLicenseInstance(env, licenseKey, instanceId) {
  const storageKey = `instances:${licenseKey}`;
  const instanceIds = (await readLicenseInstanceIds(env, licenseKey))
    .filter((id) => id !== instanceId);
  if (instanceIds.length === 0) {
    await env.PIPANEL_LICENSES.delete(storageKey);
  } else {
    await env.PIPANEL_LICENSES.put(storageKey, JSON.stringify(instanceIds));
  }
}

// ---------- claim / legacy report-activation ----------

async function handleClaim(request, env) {
  const url = new URL(request.url);
  const token = url.searchParams.get('token');
  if (!token) return json({ error: 'missing token' }, 400);

  const raw = await env.PIPANEL_LICENSES.get(`claim:${token}`);
  if (!raw) return json({ status: 'pending' }, 202);

  await env.PIPANEL_LICENSES.delete(`claim:${token}`); // single-use
  const { licenseKey } = JSON.parse(raw);
  return json({ status: 'ready', licenseKey });
}

async function handleReportActivation(request, env) {
  const { licenseKey, instanceId } = await readJson(request);
  if (!licenseKey || !instanceId) return json({ error: 'missing licenseKey/instanceId' }, 400);

  // Compatibility for older app builds. Verify the pair with Creem before accepting it; current
  // builds are recorded automatically by /license/activate and never call this endpoint.
  const response = await fetch(`${creemApiBase(env)}/v1/licenses/validate`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-api-key': env.CREEM_API_KEY },
    body: JSON.stringify({ key: licenseKey, instance_id: instanceId }),
  });
  if (!response.ok) return json({ error: 'invalid license instance' }, 403);
  await rememberLicenseInstance(env, licenseKey, instanceId);
  return json({ ok: true });
}

// ---------- recovery ----------

async function handleRecoverRequest(request, env) {
  const { email } = await request.json();
  if (!email) return json({ error: 'missing email' }, 400);

  const licenseKey = await env.PIPANEL_LICENSES.get(`email:${email.toLowerCase()}`);
  if (licenseKey) {
    const token = crypto.randomUUID();
    await env.PIPANEL_LICENSES.put(`recover:${token}`, licenseKey, { expirationTtl: RECOVERY_TTL_SECONDS });
    await sendRecoveryEmail(env, { email, token });
  }
  // Always respond the same way whether or not we found a license, so this endpoint can't be used
  // to probe which emails have purchased a license.
  return json({ status: 'ok' });
}

async function handleRecoverConfirm(request, env) {
  const url = new URL(request.url);
  const token = url.searchParams.get('token');
  if (!token) return json({ error: 'missing token' }, 400);

  const licenseKey = await env.PIPANEL_LICENSES.get(`recover:${token}`);
  if (!licenseKey) return json({ error: 'invalid or expired token' }, 404);

  await env.PIPANEL_LICENSES.delete(`recover:${token}`); // single-use
  return json({ licenseKey });
}

// ---------- Creem ----------

async function deactivateCreemInstance(env, licenseKey, instanceId) {
  const response = await fetch(`${creemApiBase(env)}/v1/licenses/deactivate`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': env.CREEM_API_KEY,
    },
    body: JSON.stringify({ key: licenseKey, instance_id: instanceId }),
  });
  if (!response.ok) {
    console.error('Creem deactivate failed during refund suspension', instanceId, response.status);
  }
}

// ---------- email (Resend) ----------

async function sendLicenseEmail(env, { email, licenseKey }) {
  await sendEmail(env, {
    to: email,
    subject: 'PiPanel 授权码',
    text: `感谢购买 PiPanel！\n\n你的授权码：${licenseKey}\n\n如果是在网页完成付款的，App 通常会在付款完成后自动为你激活；也可以打开 PiPanel「设置 → 会员」手动粘贴这个授权码激活。\n\n如果以后丢失了授权码，可以在 App 内用这次购买时的邮箱找回。`,
  });
}

async function sendRecoveryEmail(env, { email, token }) {
  const deepLink = `pipanel://recover?token=${encodeURIComponent(token)}`;
  await sendEmail(env, {
    to: email,
    subject: 'PiPanel 找回授权',
    text: `点击下面的链接，在这台 Mac 上打开 PiPanel 并自动恢复你的授权（链接 30 分钟内有效，只能使用一次）：\n\n${deepLink}\n\n如果点击没有反应，请确认是在安装了 PiPanel 的 Mac 上打开此邮件。`,
  });
}

async function sendEmail(env, { to, subject, text }) {
  if (!env.RESEND_API_KEY) {
    console.error('RESEND_API_KEY not set — skipping email to', to);
    return;
  }
  const response = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${env.RESEND_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      from: env.RESEND_FROM ?? 'PiPanel <support@pipanel.app>',
      to: [to],
      subject,
      text,
    }),
  });
  if (!response.ok) {
    console.error('Email send failed', await response.text());
  }
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

async function readJson(request) {
  try {
    return await request.json();
  } catch {
    return {};
  }
}
