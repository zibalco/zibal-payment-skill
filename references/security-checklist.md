# Zibal integration security checklist

Run through this before calling an integration done. **[docs]** items come from the Zibal docs. **[practice]** items are engineering practice applied to them; the docs do not specify them, so adjust values to the project.

## Credentials

- [ ] [practice] `merchant` comes from the server-side environment (`ZIBAL_MERCHANT`). It is never in source code, client bundles or `NEXT_PUBLIC_*` variables.
- [ ] [practice] `merchant` is never logged. Do not log whole request bodies: they also hold `mobile`, `nationalCode` and `allowedCards`.
- [ ] [docs] `merchant: zibal` is used only for testing and production has a real gateway's value. Fail at startup if production is running with `zibal`.
- [ ] [docs] If the gateway is limited to specific IPs, every server calling Zibal is on the list (otherwise result `115`).

## Amount

- [ ] [docs] `amount` is in **Rials**. If the app stores Toman, multiply by 10 exactly once, at the boundary, in one function.
- [ ] [docs] `amount` is at least 1,000 Rials (result `105`) and at most 4,000,000,000 Rials, or lower if the gateway has a lower ceiling (result `113`).
- [ ] [practice] `amount` is computed on the server from the order. It is never taken from the client.
- [ ] [practice] The amount column is 64-bit (`BIGINT`). The ceiling is above the signed 32-bit limit, and `trackId` is int64.
- [ ] [practice] The stored amount is saved before redirecting and compared with the verified amount.

## Callback and verify

- [ ] [docs] Verify runs server-side on every callback. The docs require it to finish a payment session.
- [ ] [practice] No code path marks a payment paid from callback parameters. The callback is unauthenticated, so anyone can forge `success=1`.
- [ ] [practice] `failed` is not terminal. A forged `success=0` must not block a later genuine payment.
- [ ] [practice] The payment is looked up by the stored `trackId`. The callback's `orderId` is not used to choose which order to mark paid.
- [ ] [docs] Verify result `100` is followed by a check that `status` is `1` (paid and verified) and `amount` equals the stored amount.
- [ ] [docs] Verify result `201` (already verified) is handled, not treated as a failure. Confirm it with inquiry.
- [ ] [practice] Mark-paid is a single conditional update, and fulfilment runs only when it changed a row. Test by firing two callbacks at once.
- [ ] [practice] An amount mismatch goes to manual review. Never fulfil it.
- [ ] [practice] The result page reads the outcome from the database and takes no state from the URL.

## Redirect

- [ ] [docs] The payer reaches `/start/{trackId}` from a page on the gateway's registered website, so the `Referer` header matches.
- [ ] [practice] Nothing on that path sets `Referrer-Policy: no-referrer` or `same-origin`, or `rel="noreferrer"`, which remove the `Referer` the docs require. Framework defaults do this: Django's `SECURE_REFERRER_POLICY` defaults to `same-origin`, and `helmet` defaults to `no-referrer`.
- [ ] [docs] Mobile apps and bots set `Referer` manually.
- [ ] [docs] The `callbackUrl` domain is related to the registered website (otherwise result `106`).

## Network

- [ ] [docs] All calls use `https://gateway.zibal.ir`.
- [ ] [practice] Every call has a timeout. Suggested default: 15 seconds.
- [ ] [practice] Verify and inquiry retry on network errors and HTTP 5xx with backoff. Suggested default: 2 retries. Verify is safe to retry, since a repeat returns `201`.
- [ ] [practice] The payment request is not retried automatically. The docs define no idempotency for it, and a duplicate creates a second session.
- [ ] [practice] A verify that still fails leaves the payment `pending`, shows the payer "still checking", and never shows failure.

## Recovery

- [ ] [practice] A background job picks up `pending` payments older than a few minutes and calls verify. This covers the payer who closed the browser before the callback.
- [ ] [docs] For lazy payments that job runs well inside the 20-minute limit, or the money returns to the payer.
- [ ] [practice] Someone receives `needs_review` alerts.

## Data

- [ ] [practice] Store `refNumber`, `paidAt` and the masked `cardNumber` only if needed. Never ask for or store full card numbers.
- [ ] [practice] `orderId` is unique per payment attempt. The docs call it your unique order identifier and do not say what happens if it is reused.
