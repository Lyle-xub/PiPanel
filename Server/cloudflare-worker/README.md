# PiPanel license server (Cloudflare Worker)

PiPanel's server-side entitlement service. It owns every Creem credential, proxies license
activation/validation/deactivation, delivers purchases, handles recovery and refunds, and records
one non-renewable seven-day Pro trial per installation. The macOS app contains no Creem API key.

## What this covers, mapped to the requirements

- **7 天 Pro 试用** — `POST /trial/start` creates an idempotent, permanent KV record keyed by a
  SHA-256 digest of the Keychain installation id; `POST /trial/status` only checks an existing
  record; `POST /trial/cancel` irreversibly stamps `cancelledAt` onto that same record and ends the
  entitlement immediately. Trial records have no TTL, so expiry or cancellation never resets
  eligibility.
- **许可证密钥不落客户端** — `/license/activate`, `/license/validate`, and
  `/license/deactivate` proxy Creem's License API. Only the Worker reads `CREEM_API_KEY`.
- **允许用户自行解绑** — the app calls the Worker's `/license/deactivate` proxy.
- **每 72 小时后台验证一次 / 最长离线使用 14 天** — handled entirely client-side in
  `MembershipManager.revalidate()`, no worker involvement needed.
- **购买（App → Worker → Checkout Session → 浏览器付款）** — `POST /create-checkout-session`.
- **交付（Webhook → Worker → App 自动领取 + 邮件）** — `POST /webhook/creem` (fulfillment),
  `GET /claim` (the app polls this after opening checkout), plus an email sent from the webhook
  handler as a fallback if auto-claim doesn't complete (e.g. checkout finished on a different
  device, or the app wasn't running to poll).
- **恢复（购买邮箱 + 一次性邮件链接）** — `POST /recover/request` + `GET /recover/confirm`, tied
  together by a `pipanel://recover?token=...` deep link that the app's `AppDelegate` handles.
- **退款（全额退款自动暂停）** — `/license/activate` records the activated Creem instance, and the
  refund webhook deactivates every recorded instance. `/report-activation` remains only as a
  validation-protected compatibility endpoint for older app builds.

## What's confirmed vs. still worth verifying with a real test purchase

Endpoint paths, request/response field names, the webhook event catalog, and the webhook signing
scheme were checked directly against docs.creem.io (`/features/addons/licenses`,
`/api-reference/endpoint/create-checkout`, `/code/webhooks`) — these are no longer guesses:

- `POST /v1/checkouts` (checkout creation), `POST /v1/licenses/{activate,validate,deactivate}`,
  all confirmed with real request/response shapes. The latter are never called by the app
  directly.
- Webhook events: `checkout.completed`, `refund.created` (plus a full `subscription.*` catalog we
  don't use for a one-time-purchase product) — confirmed as the complete event list.
- Webhook signing: `creem-signature` header, HMAC-SHA256 hex digest over the raw body, using the
  webhook secret from the Creem dashboard's Developers → Webhooks page.

Two things remain genuinely unconfirmed — Creem's own docs disagree with themselves or don't show
a populated example — and are handled defensively in code rather than guessed at:

1. **Whether the license key arrives directly on the `checkout.completed` payload.**
   `license_keys` is documented as a field on the Checkout entity schema, but the one example
   webhook payload in the docs didn't show it populated. `resolveLicenseKey()` in `src/index.js`
   tries `object.license_keys[0].key` first, and falls back to a `GET /v1/checkouts/{id}` call if
   that's empty. **That fallback endpoint's existence is inferred by REST convention from the
   confirmed `POST /v1/checkouts`, not independently confirmed** — verify with one real purchase.
2. **Whether `instance` in a license response is always an array or sometimes a single nullable
   object** (one doc page shows each, for the same endpoint) — `CreemClient.swift` decodes either
   shape defensively, no worker-side impact.

The easiest way to close both gaps: trigger one real test-mode purchase (see the `CREEM_API_BASE_URL`
toggle in `wrangler.toml`), inspect the actual webhook payload Cloudflare logs, and confirm whether
`resolveLicenseKey()` ever needs the fallback GET or if the inline path always works.

## One-time setup

1. **Creem dashboard**:
   - Create three Products for PiPanel (single/dual/multi device), matching the prices on the
     pricing page. On each, enable "License Key Management" and set `activation_limit` to 1, 2,
     and however many "3 台及以上" should mean in practice (e.g. 5) respectively — this is what
     Creem itself enforces the per-device-tier limit against (`CreemClient.activate` surfaces the
     403 "limit reached" response as `.activationLimitReached`).
   - Note each Product ID → `CREEM_PRODUCT_SINGLE` / `_DUAL` / `_MULTI` in `wrangler.toml`.
   - Get your seller API key (Developers → API Keys). It is stored only as the Worker secret
     `CREEM_API_KEY`; never add it to Swift source, `wrangler.toml`, logs, or GitHub Actions output.
   - Register a webhook pointing at `https://<your-worker-subdomain>.workers.dev/webhook/creem`;
     if Creem gives you a signing secret, put it in `CREEM_WEBHOOK_SECRET`.

2. **Cloudflare**:
   - `wrangler login`
   - `wrangler kv namespace create PIPANEL_LICENSES`, then paste the returned id into
     `wrangler.toml`'s `kv_namespaces` entry.
   - `wrangler secret put CREEM_API_KEY`
   - `wrangler secret put CREEM_WEBHOOK_SECRET` (if Creem provides one)
   - `wrangler secret put RESEND_API_KEY`
   - Fill in the non-secret values in `wrangler.toml` (`[vars]`).
   - `npm install && wrangler deploy`

3. **App**: update `LicenseServerClient.swift`'s `baseURL` to the deployed worker URL.

## Existing-key migration

An earlier PiPanel build embedded the Creem API key in `CreemClient.swift`. Before shipping this
build, revoke that key in Creem, create a replacement, and run `wrangler secret put CREEM_API_KEY`
with the replacement. Removing the string from the current source is not enough because it remains
available in Git history and already-distributed binaries.

The Worker must be deployed before distributing the new app; otherwise new builds cannot start a
trial or activate/validate licenses.

## Custom URL scheme (required for the recovery deep link)

The recovery email links to `pipanel://recover?token=...`. This only opens PiPanel if the
`CFBundleURLTypes` entry is present in `Info.plist` (already added — scheme `pipanel`) and
`AppDelegate.application(_:open:)` is wired up (already added). Nothing further to do here beyond
making sure a build with these changes is what you're actually distributing.
