---
name: zibal-ipg
description: Integrates the Zibal (زیبال) internet payment gateway (IPG, درگاه پرداخت) into a project in any stack, including Node.js/Express, Next.js, Laravel/PHP, Django and FastAPI/Python. Implements the full flow correctly, covering payment request, redirect to the gateway, callback route, server-side verify, inquiry, lazy mode and revenue sharing (تسهیم), with an idempotent mark-paid step, amount checks in Rials and result/status code handling. Use this skill whenever the user wants to add, fix, debug, test or review online payments with Zibal, or mentions Iranian payment gateways, Shaparak (شاپرک), an Iranian checkout, ZIBAL_MERCHANT, trackId, callbackUrl, a failed payment verify, or Zibal result codes such as 102, 201 or 202.
---

# Zibal IPG integration

Docs snapshot: 2026-11-02

This repository covers only the Zibal payment gateway and holds everything needed to integrate it. Do not invent endpoints, fields or codes: if a detail is not in `references/`, it is not documented, so say so to the user instead of guessing.

## The flow

```
Your server                         Zibal                           Payer's browser
POST /v1/request  ───────────────►  returns trackId
save trackId + amount
redirect  ──────────────────────────────────────────────────────►   GET /start/{trackId}
                                                                    pays on the gateway
callback route  ◄─────────────────  GET callbackUrl?trackId=...
POST /v1/verify  ────────────────►  returns result, status, amount
check, mark paid once
```

Lazy mode has the same shape but different endpoints, a `POST` JSON callback, and a 20-minute limit to verify before the money returns to the payer. Use it only if the user asks for it or needs to accept or decline after payment. Otherwise use the standard flow.

## Workflow

1. **Detect the stack.** Check `package.json`, `composer.json`, `requirements.txt`, `pyproject.toml` and existing routes.
2. **Load the matching example** from the table below and follow it. For another stack, adapt the closest one, keeping the logic of `settle` intact.
3. **Configure env.** Add `ZIBAL_MERCHANT` and the app's public base URL to the env config and its example file. Use `zibal`, the documented test account, for development. Never commit a real value.
4. **Add storage.** One row per payment attempt: unique `order_id`, unique `track_id`, `amount` as 64-bit integer in Rials, `mode`, `status`. Fit this to the project's existing order model rather than duplicating it.
5. **Implement the payment request.** Compute the amount on the server, convert to Rials once, call the request endpoint, and on `result` `100` save `trackId` before redirecting.
6. **Redirect** the payer to `https://gateway.zibal.ir/start/{trackId}` from your own site, so that the required `Referer` header is sent.
7. **Add the callback route.** Treat it as a trigger only. Look up the payment by `trackId`.
8. **Verify server-side,** following the algorithm in [references/callback.md](references/callback.md).
9. **Mark paid idempotently** with one conditional update, and fulfil only if it changed a row.
10. **Handle errors** using [references/result-codes.md](references/result-codes.md). Show payers a generic message and log the code for developers.
11. **Test.** Run [scripts/sandbox-test.sh](scripts/sandbox-test.sh) to confirm the API is reachable. Then run the app with `ZIBAL_MERCHANT=zibal`, and also hit the callback by hand with a forged `success=1` on an unpaid session and confirm the order does not become paid. Fire the same callback twice at once and confirm fulfilment runs once.
12. **Review** against [references/security-checklist.md](references/security-checklist.md) before calling the work done.

## Examples

| Stack | File |
| --- | --- |
| Node.js + Express | [examples/node-express.md](examples/node-express.md) |
| Next.js App Router | [examples/nextjs-app-router.md](examples/nextjs-app-router.md) |
| PHP + Laravel | [examples/laravel.md](examples/laravel.md) |
| Python + Django | [examples/django.md](examples/django.md) |
| Python + FastAPI | [examples/fastapi.md](examples/fastapi.md) |

Each one covers the standard flow and lazy mode with the same logic, so load only the one you need.

## Non-negotiable rules

1. **Never trust callback parameters.** The docs define no signature on callbacks, so `success=1` proves nothing. `success=0` proves nothing either, so do not branch on it.
2. **Always verify server-side.** Only the verify response decides whether a payment succeeded. A payment session is not finished until it is verified.
3. **Compare the amount.** After verify `100`, require `status` to be `1` and `amount` to equal the stored amount. On a mismatch, flag for manual review and do not fulfil.
4. **Handle `201` properly.** Verify `201` means already verified, which happens on double callbacks or after a crash. It is not an error. Confirm it with `POST /v1/inquiry` and apply rule 3.
5. **Make mark-paid idempotent.** Use `UPDATE ... WHERE track_id = ? AND status <> 'paid'` and fulfil only if a row changed. Do not use read-then-write.
6. **Keep `failed` recoverable.** A verify `202` can follow a forged callback sent while the payer is still paying. A later verify `100` must still be able to mark the payment paid.
7. **Use Rials.** `amount` is an integer in Rials, from 1,000 to 4,000,000,000. If the app works in Toman, multiply by 10 exactly once, in one place. Use 64-bit columns for `amount` and `trackId`.
8. **Use the right `trackId` type.** It is an integer in API bodies but a string in callbacks. In JavaScript, confirm it is a safe integer, and store it as a string.
9. **Use the right endpoints.** Standard verify is `/v1/verify`, lazy verify is `/verify`. Choose by the mode stored on the payment.
10. **Set timeouts and retries.** Use a timeout on every call. Retry verify and inquiry on network errors and HTTP 5xx; a repeated verify safely returns `201`. Do not auto-retry the payment request. If verify still fails, keep the payment `pending`, never report it as failed, and verify again from a background job.
11. **Protect secrets.** Keep `merchant` on the server only. Never log it, or whole request bodies containing `mobile` or `nationalCode`.
12. **Read `result`, not the HTTP code.** Only HTTP 200 is documented, and failures are reported in the body.

## References

Read these only when needed.

| File | Read it when |
| --- | --- |
| [references/api.md](references/api.md) | You need an endpoint, field, type, or request/response sample, or the user asks about lazy mode, revenue sharing (`multiplexingInfos`), `feeMode`, `allowedCards`, `nationalCode`, the `Referer` header, or the trust badge. |
| [references/callback.md](references/callback.md) | You are writing or debugging the callback route. It has both callback formats and the full handling algorithm. |
| [references/result-codes.md](references/result-codes.md) | You see a `result` or `status` number, or are writing error handling. It has every code with an action to take. |
| [references/security-checklist.md](references/security-checklist.md) | You are finishing or reviewing an integration. |

## Common problems

- **Payer does not reach the gateway:** the `Referer` header is missing or its domain does not match the gateway's registered website. Check the `Referrer-Policy` header: `no-referrer` and `same-origin` both remove it, and they are the defaults in `helmet` and Django. Mobile apps and bots must set the header manually.
- **Result `105` or `113`:** the amount is out of range, usually a Toman/Rial mistake.
- **Result `106`:** the `callbackUrl` domain is not related to the registered website.
- **Result `115`:** the server's IP is not registered in the Zibal panel.
- **Result `202` on verify:** the payment was not completed. Read `status` from `POST /v1/inquiry` for the reason.
- **Paid but not marked paid:** verify failed or never ran. Run the background job, or call verify again.
