# Zibal callback handling

Zibal sends payment information to the order's `callbackUrl` when its state changes. The format depends on the flow.

To finish a payment session, you must verify it. The callback only tells you to go and check.

## Standard callback

Sent with `GET` as a query string.

| Parameter | Description |
| --- | --- |
| `success` | `1` if the transaction succeeded, otherwise `0`. |
| `trackId` | Payment session identifier. |
| `orderId` | The `orderId` sent in the payment request (if one was sent). |
| `status` | Payment status, see [result-codes.md](result-codes.md#payment-status). |

Example:

```
https://yourcallbackurl.com/callback?trackId=9900&success=1&status=2&orderId=1
```

## Lazy callback

Sent with `POST` as a JSON body.

| Field | Description |
| --- | --- |
| `success` | `1` if the transaction succeeded, otherwise `0`. |
| `trackId` | Payment session identifier. |
| `orderId` | The `orderId` sent in the payment request (if one was sent). |
| `status` | The merchant decides the order's state; the order has no status until verified. |
| `cardNumber` | Payer's card number (masked). |
| `hashedCardNumber` | Payer's card number (hashed). |

Sample body. Note that `success` and `trackId` are strings here, while `trackId` is an integer in API calls:

```json
{
  "success": "1",
  "trackId": "15966442233311",
  "orderId": "1234",
  "status": null,
  "cardNumber": "62741****44",
  "hashedCardNumber": "432DA439OSD345"
}
```

## Handling algorithm

The docs define no signature on callbacks, so treat every field as attacker-controlled. Anyone can call this URL with any values. This means both `success=1` and `success=0` prove nothing; only the verify response counts. The handler below therefore does not branch on `success`.

1. Read `trackId` from the query (standard) or JSON body (lazy). Reject it unless it is all digits and fits in a 64-bit integer.
2. Find the stored payment **by `trackId`**. If there is none, respond 404 and stop.
3. If the stored payment is already `paid`, skip to step 8. Never verify again just to redo fulfilment.
4. Call verify, choosing the path from the mode **stored on the payment**, not from the route that was hit. Send `trackId` as an integer.
5. Branch on `result`:
   - `100`: use this response.
   - `201`: already verified, for example by a concurrent callback or an earlier attempt that crashed. Call `POST /v1/inquiry` and use that response. If inquiry does not return `100`, set `needs_review`.
   - `202`: not paid. Change `pending` to `failed` and go to step 8. Keep `failed` eligible for a later successful verify, because a forged `success=0` can arrive before the real callback.
   - `-1` (lazy only): another request is processing this transaction. Change nothing and tell the payer the result is pending.
   - Anything else (`102`, `103`, `104`, `115`, `203`, unknown): change nothing, log the code, alert the developer.
   - Network failure after retries: change nothing and tell the payer the result is pending. Verify later from a background job.
6. Check `response.status == 1` **and** `response.amount == stored amount`. If either fails, set `needs_review`, do not fulfil, and flag it for a human.
7. Mark paid with one conditional update (`... WHERE track_id = ? AND status <> 'paid'`). Run fulfilment **only if that update changed a row**. This is what makes a concurrent double callback safe.
8. Respond. In the standard flow, redirect the payer to a result page that reads the outcome from your database, not from the callback parameters.

The callback's `status` may be used only to word a failure message, for example "cancelled by the user" for `3`.

## Choosing not to accept a lazy payment

In lazy mode, not sending verify is how you decline: 20 minutes after payment the amount goes back to the paying card. Run business checks such as stock availability before step 4, and skip verify if they fail.

The same 20-minute limit makes verify failures urgent in lazy mode. A background job must retry pending lazy payments well inside that window.

## Not documented

The docs do not define the following. Do not assume an answer, and do not tell the user one exists:

- What HTTP response Zibal expects from the callback, or whether it retries on failure.
- Whether the lazy `POST` comes from the payer's browser or from Zibal's servers, and how the payer returns to your site after a lazy payment.
- Any callback signature or source IP list.
- Whether `POST /v1/inquiry` covers lazy sessions. It is documented only for the standard flow, so if it does not return `100` after a lazy `201`, the algorithm above sets `needs_review`.
- The fields returned with verify `201`. This is why the algorithm reads them from inquiry.
- How long a standard payment can wait for verify. The 20-minute limit is documented only for lazy mode.
- The timezone of `paidAt`, `verifiedAt` and `createdAt`. Store them as received.
