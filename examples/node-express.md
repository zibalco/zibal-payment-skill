# Zibal with Node.js and Express

Node 18+, Express 5, the built-in `fetch`, and SQLite through `better-sqlite3`. Swap the database for the project's own; keep the conditional updates.

## Setup

```bash
npm install express better-sqlite3
```

**`.env`**

```bash
ZIBAL_MERCHANT=zibal            # zibal is the documented test account
APP_URL=http://localhost:3000   # public base URL; its domain must relate to the gateway's registered website
```

Run with `node --env-file=.env server.js`.

## Code

**`server.js`** (ES module: set `"type": "module"` in `package.json`)

```js
import { randomUUID } from 'node:crypto';
import Database from 'better-sqlite3';
import express from 'express';

const ZIBAL_BASE = 'https://gateway.zibal.ir';
const MERCHANT = process.env.ZIBAL_MERCHANT;
const APP_URL = process.env.APP_URL;
if (!MERCHANT || !APP_URL) throw new Error('ZIBAL_MERCHANT and APP_URL are required');

// Result codes for /v1/request and /request/lazy. Log these; never show them to payers.
const REQUEST_RESULTS = {
  102: 'merchant not found',
  103: 'merchant inactive or contract not signed',
  104: 'merchant invalid',
  105: 'amount must be at least 1,000 Rials',
  106: 'callbackUrl invalid or not related to the registered website',
  107: 'percentMode invalid',
  108: 'invalid beneficiary in multiplexingInfos',
  109: 'inactive beneficiary in multiplexingInfos',
  110: 'no wagePayer or self beneficiary with feeMode 0',
  111: 'amount does not equal the sum of multiplexingInfos shares',
  112: 'fee wallet balance insufficient',
  113: 'amount exceeds the allowed ceiling',
  114: 'national code invalid',
  115: 'server IP not registered in the Zibal panel',
  116: 'feeMode invalid',
  118: 'multiplexingInfos structure invalid',
  140: 'callbackUrl not sent',
  141: 'fee payer share is less than the fee',
};

// Result codes for /v1/verify and /verify that need a developer.
const VERIFY_RESULTS = {
  102: 'merchant not found',
  103: 'merchant inactive',
  104: 'merchant invalid',
  115: 'server IP not registered in the Zibal panel',
  203: 'trackId invalid',
};

// Prices live on the server. The amount never comes from the client.
const PRICES_RIAL = new Map([
  ['basic', 160000],
  ['pro', 490000],
]);

const db = new Database(process.env.DB_PATH ?? 'payments.db');
db.exec(`
  CREATE TABLE IF NOT EXISTS payments (
    id         INTEGER PRIMARY KEY,
    order_id   TEXT    NOT NULL UNIQUE,
    track_id   TEXT    UNIQUE,                    -- int64 from Zibal, kept as text in JS
    amount     INTEGER NOT NULL,                  -- Rials
    mode       TEXT    NOT NULL DEFAULT 'standard', -- standard | lazy
    status     TEXT    NOT NULL DEFAULT 'pending',  -- pending | paid | failed | needs_review
    ref_number TEXT,
    paid_at    TEXT,
    created_at TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP
  )
`);

async function zibalPost(path, body, { retries = 0 } = {}) {
  for (let attempt = 0; ; attempt += 1) {
    try {
      const response = await fetch(`${ZIBAL_BASE}${path}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(15_000),
      });
      if (response.status >= 500) throw new Error(`Zibal HTTP ${response.status}`);
      return await response.json();
    } catch (error) {
      if (attempt >= retries) throw error;
      await new Promise((resolve) => setTimeout(resolve, 500 * 2 ** attempt));
    }
  }
}

function fulfil(payment) {
  // Ship the order here. Runs once per payment.
  console.log(`fulfilling order ${payment.order_id}`);
}

function markPaid(payment, verified) {
  const update = db
    .prepare(
      `UPDATE payments SET status = 'paid', ref_number = ?, paid_at = ?
       WHERE id = ? AND status <> 'paid'`,
    )
    .run(String(verified.refNumber ?? ''), verified.paidAt ?? null, payment.id);
  if (update.changes === 1) fulfil(payment);
}

function setStatus(payment, status) {
  db.prepare(`UPDATE payments SET status = ? WHERE id = ? AND status IN ('pending', 'failed')`).run(
    status,
    payment.id,
  );
}

// Decides the payment's outcome from the verify response only.
// Returns: paid | failed | pending | needs_review
async function settle(payment) {
  if (payment.status === 'paid' || payment.status === 'needs_review') return payment.status;

  const body = { merchant: MERCHANT, trackId: Number(payment.track_id) };
  const verifyPath = payment.mode === 'lazy' ? '/verify' : '/v1/verify';

  let verified;
  try {
    verified = await zibalPost(verifyPath, body, { retries: 2 });
    if (verified.result === 201) {
      // Already verified: confirm the session's real amount and status.
      verified = await zibalPost('/v1/inquiry', body, { retries: 2 });
      if (verified.result !== 100) {
        setStatus(payment, 'needs_review');
        return 'needs_review';
      }
    }
  } catch (error) {
    console.error(`verify unreachable for payment ${payment.id}: ${error.message}`);
    return 'pending'; // a background job must verify this later
  }

  if (verified.result === 202) {
    setStatus(payment, 'failed');
    return 'failed';
  }
  if (verified.result === -1) return 'pending'; // lazy: another request is processing it
  if (verified.result !== 100) {
    const reason = VERIFY_RESULTS[verified.result] ?? 'unknown result';
    console.error(`verify failed for payment ${payment.id}: ${verified.result} ${reason}`);
    return 'pending';
  }

  if (verified.status !== 1 || verified.amount !== payment.amount) {
    console.error(`verify mismatch for payment ${payment.id}: needs manual review`);
    setStatus(payment, 'needs_review');
    return 'needs_review';
  }

  markPaid(payment, verified);
  return 'paid';
}

async function createPayment(req, res, mode) {
  const amount = PRICES_RIAL.get(req.body?.product);
  if (!amount) return res.status(400).send('Unknown product');

  const orderId = randomUUID();
  const requestPath = mode === 'lazy' ? '/request/lazy' : '/v1/request';

  let response;
  try {
    response = await zibalPost(requestPath, {
      merchant: MERCHANT,
      amount,
      callbackUrl: `${APP_URL}/payment/callback`,
      description: `Order ${orderId}`,
      orderId,
    });
  } catch (error) {
    console.error(`payment request unreachable: ${error.message}`);
    return res.status(502).send('Payment service is unavailable. Please try again.');
  }

  if (response.result !== 100) {
    const reason = REQUEST_RESULTS[response.result] ?? 'unknown result';
    console.error(`payment request failed: ${response.result} ${reason}`);
    return res.status(502).send('Could not start the payment.');
  }
  if (!Number.isSafeInteger(response.trackId)) {
    console.error('trackId is outside the safe integer range');
    return res.status(502).send('Could not start the payment.');
  }

  db.prepare('INSERT INTO payments (order_id, track_id, amount, mode) VALUES (?, ?, ?, ?)').run(
    orderId,
    String(response.trackId),
    amount,
    mode,
  );

  // 303 from a form post keeps the browser on a same-site Referer, which Zibal requires.
  return res.redirect(303, `${ZIBAL_BASE}/start/${response.trackId}`);
}

function findByTrackId(trackId) {
  if (!/^\d+$/.test(String(trackId ?? ''))) return undefined;
  return db.prepare('SELECT * FROM payments WHERE track_id = ?').get(String(trackId));
}

const app = express();
app.use(express.urlencoded({ extended: false }));
app.use(express.json());

app.post('/pay', (req, res) => createPayment(req, res, 'standard'));
app.post('/pay/lazy', (req, res) => createPayment(req, res, 'lazy'));

// Standard callback: GET with a query string.
app.get('/payment/callback', async (req, res) => {
  const payment = findByTrackId(req.query.trackId);
  if (!payment) return res.status(404).send('Unknown payment');
  await settle(payment);
  return res.redirect(303, `/payment/result/${payment.order_id}`);
});

// Lazy callback: POST with a JSON body.
app.post('/payment/callback', async (req, res) => {
  const payment = findByTrackId(req.body?.trackId);
  if (!payment) return res.status(404).json({ error: 'unknown payment' });
  // To decline a lazy payment, return here without calling settle.
  // Zibal returns the money to the card 20 minutes after payment.
  return res.json({ status: await settle(payment) });
});

// The result page reads the database, never the callback parameters.
app.get('/payment/result/:orderId', (req, res) => {
  const payment = db.prepare('SELECT status FROM payments WHERE order_id = ?').get(req.params.orderId);
  if (!payment) return res.status(404).send('Unknown payment');
  const messages = {
    paid: 'Payment successful.',
    failed: 'Payment failed or was cancelled.',
    pending: 'We are still confirming your payment.',
    needs_review: 'Your payment is being reviewed. Please contact support.',
  };
  return res.send(messages[payment.status]);
});

app.listen(process.env.PORT ?? 3000);
```

## Checkout form

The payer must leave from a page on your site so the browser sends `Referer`:

```html
<form method="post" action="/pay">
  <input type="hidden" name="product" value="basic" />
  <button type="submit">Pay</button>
</form>
```

## Notes

- Delete the `/pay/lazy` route and the `POST` callback if you do not use lazy mode.
- If the app uses `helmet`, its default `Referrer-Policy: no-referrer` removes the `Referer` Zibal requires. Set `helmet({ referrerPolicy: { policy: 'strict-origin-when-cross-origin' } })`.
- For a single-page app, return `{ url }` as JSON from the pay route and set `window.location.href`.
- Add a job that calls `settle` on `pending` rows older than a few minutes. For lazy payments it must run well inside the 20-minute limit.
