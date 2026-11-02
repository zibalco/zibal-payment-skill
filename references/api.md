# Zibal IPG API reference

## Basics

- Base URL: `https://gateway.zibal.ir`
- The API is RESTful. Requests and responses are JSON.
- Zibal only answers requests sent over `https`.
- Every server-to-server call authenticates with the `merchant` body field. It is shown in the Zibal user panel after a gateway is created.
- A gateway can be restricted to specific IPs (see result code `115`).
- Test account: `merchant: zibal` exercises every feature before a real gateway is activated.
- The spec documents only HTTP `200` responses. Read `result` in the body to learn the outcome; never treat HTTP 200 alone as success.

## Endpoints

| Flow | Step | Method | Path |
| --- | --- | --- | --- |
| Standard | Payment request | `POST` | `/v1/request` |
| Both | Start payment (payer's browser) | `GET` | `/start/{trackId}` |
| Standard | Verify | `POST` | `/v1/verify` |
| Standard | Inquiry | `POST` | `/v1/inquiry` |
| Lazy | Payment request | `POST` | `/request/lazy` |
| Lazy | Verify | `POST` | `/verify` |

Lazy verify is `/verify` with no `/v1` prefix. Do not mix the two verify paths.

## POST /v1/request

Registers the order with Zibal and returns the `trackId`.

Request body:

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `merchant` | string | yes | Authentication. Use `zibal` for testing. |
| `amount` | integer (int64) | yes | Order total **in Rials**. |
| `callbackUrl` | string | yes | Merchant URL Zibal sends payment information to. Its domain must be related to the website registered for the gateway. |
| `description` | string | no | Order description, shown in reports. |
| `orderId` | string | no | Your unique order identifier, used in reports. |
| `mobile` | string | no | Payer's mobile number. The payer's saved cards appear for selection on the gateway. |
| `allowedCards` | array of string | no | List of 16-digit card numbers. The payer can pay only with these cards. |
| `nationalCode` | string | no | 10-digit national code. The card owner's national code is matched against it and the transaction is blocked on mismatch. |
| `checkMobileWithCard` | boolean | no | Match the card number with the submitted mobile. |
| `percentMode` | integer | no | Send `1` if revenue sharing is percentage-based. Default `0`. |
| `feeMode` | integer | no | `0`: fee deducted from the transaction. `1`: fee deducted from the wallet connected to the gateway (not supported for payment facilitators, "پرداختیاری"). |
| `multiplexingInfos` | array of object | no | Revenue-sharing items, see below. |

`multiplexingInfos` item:

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `bankAccount` | string | see note | Beneficiary IBAN (Sheba). |
| `subMerchantId` | string | see note | Beneficiary identifier. |
| `amount` | integer (int64) | not stated | Amount, or percentage in percent mode. |
| `wagePayer` | boolean | no | Take the fee from this item. Only effective with `feeMode: 0`. If not set, the fee is deducted from the main beneficiary, `subMerchantId: self`. |

Note: each item must have one of `bankAccount` or `subMerchantId` (result `118`).

Response:

| Field | Type | Description |
| --- | --- | --- |
| `trackId` | integer (int64) | Unique payment session identifier, used for inquiry and reports. |
| `result` | integer | Request result, see [result-codes.md](result-codes.md#payment-request-results). |
| `message` | string | Result message. |

Request sample:

```json
{
  "merchant": "zibal",
  "amount": 160000,
  "callbackUrl": "https://yourapiurl.com/callback.php",
  "description": "Hello World!",
  "orderId": "ZBL-7799",
  "mobile": "09123456789"
}
```

Revenue-sharing sample:

```json
{
  "merchant": "zibal",
  "amount": 3000,
  "callbackUrl": "https://zibal.ir/callback",
  "mobile": "09123456789",
  "description": "Hello World !",
  "orderId": "231",
  "feeMode": 0,
  "multiplexingInfos": [
    { "amount": 2000, "bankAccount": "IR540560004120002717448001" },
    { "amount": 1000, "subMerchantId": "x48mBx", "wagePayer": true }
  ]
}
```

Response sample:

```json
{ "trackId": 15966442233311, "result": 100, "message": "success" }
```

## GET /start/{trackId}

Redirect the payer's browser to this URL. It opens the Zibal payment page.

| Parameter | In | Type | Required | Description |
| --- | --- | --- | --- | --- |
| `trackId` | path | string | yes | The `trackId` from the request step. |
| `Referer` | header | string | yes | Its domain must match the website registered for the gateway. Otherwise the payer is not transferred to the gateway. |

The request has no body.

- Websites: when you send the payer here from inside your own site, the browser sends `Referer` automatically.
- Mobile apps and bots: `Referer` is not sent automatically and must be set manually. Sample value from the docs: `android-app://com.example.yourapp`. This is the only guidance available here for apps and bots, so tell the user to confirm the setup with Zibal.
- The header name is `Referer` with one `r`. Do not write `Referrer`.

## POST /v1/verify

Confirms a successful payment and closes the payment session. Call it after the callback.

Request body:

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `merchant` | string | yes | Authentication. Use `zibal` for testing. |
| `trackId` | integer (int64) | yes | The payment session to verify. |

Response:

| Field | Type | Description |
| --- | --- | --- |
| `paidAt` | string (date-time) | Payment date, ISODate (when payment succeeded). |
| `cardNumber` | string | Payer's card number (masked). |
| `status` | integer | Payment status, see [result-codes.md](result-codes.md#payment-status). |
| `amount` | integer (int64) | Order amount in Rials. |
| `refNumber` | integer | Transaction reference ID (when payment succeeded). |
| `description` | string | Transaction description (when payment succeeded). |
| `orderId` | string | Order identifier (when payment succeeded). |
| `result` | integer | Request result, see [result-codes.md](result-codes.md#verify-results). |
| `message` | string | Result message. |
| `multiplexingInfos` | array | Revenue-sharing information (when the transaction is shared). |

Request sample:

```json
{ "merchant": "zibal", "trackId": 15966442233311 }
```

Response sample:

```json
{
  "paidAt": "2018-03-25T23:43:01.053000",
  "amount": 1600,
  "result": 100,
  "status": 1,
  "refNumber": 12312,
  "description": "Hello World!",
  "cardNumber": "62741****44",
  "orderId": "2211",
  "message": "success"
}
```

With revenue sharing, the response also has:

```json
{
  "multiplexingInfos": [
    { "amount": 900, "bankAccount": "IR540560004120002717448001" },
    { "amount": 700, "bankAccount": "IR132000300120002722448001" }
  ]
}
```

## POST /v1/inquiry

Returns the full state of a payment session. Use it at any stage of the payment.

Request body:

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `merchant` | string | yes | Authentication. Use `zibal` for testing. |
| `trackId` | integer (int64) | yes | The payment session to report on. |

Response:

| Field | Type | Description |
| --- | --- | --- |
| `createdAt` | string (date-time) | Order creation date, ISODate (when payment succeeded). |
| `paidAt` | string (date-time) | Payment date, ISODate (when payment succeeded). |
| `verifiedAt` | string (date-time) | Verification date, ISODate (when payment succeeded). |
| `cardNumber` | string | Payer's card number (masked). |
| `status` | integer | Payment status, see [result-codes.md](result-codes.md#payment-status). |
| `amount` | integer (int64) | Order amount in Rials. |
| `refNumber` | integer | Transaction reference ID (when payment succeeded). |
| `description` | string | Transaction description. |
| `orderId` | string | Order identifier. |
| `wage` | integer | Transaction fee in Rials. |
| `result` | integer | Request result, see [result-codes.md](result-codes.md#inquiry-results). |
| `message` | string | Result message. |
| `multiplexingInfos` | array | Revenue-sharing information (when the transaction is shared). |

Response sample:

```json
{
  "message": "success",
  "result": 100,
  "refNumber": 12312,
  "paidAt": "2022-07-06T14:18:21.742000",
  "verifiedAt": "2022-07-06T14:18:21.742000",
  "status": 1,
  "amount": 10000,
  "orderId": "231",
  "description": "Hello World !",
  "cardNumber": "62741****44",
  "multiplexingInfos": [],
  "wage": 0,
  "createdAt": "2022-07-06T14:17:52.918000"
}
```

## Lazy method

In lazy mode the merchant decides whether to accept a paid transaction. If verification is not sent within **20 minutes** after the payment on the gateway, the amount is returned to the paying card.

Other differences from the standard flow are in the parameters sent and received:

| | Standard | Lazy |
| --- | --- | --- |
| Request | `POST /v1/request` | `POST /request/lazy` |
| Callback | `GET` with query string | `POST` with JSON body |
| Callback `status` | Payment status | No status until verified (`null` in the sample) |
| Callback extras | none | `cardNumber`, `hashedCardNumber` |
| Verify | `POST /v1/verify` | `POST /verify` |
| Extra verify result | none | `-1` (another request is being processed) |

The start step is the same `GET /start/{trackId}`. See [callback.md](callback.md) for both callback formats.

### POST /request/lazy

Request body, response fields and result codes are the same as [POST /v1/request](#post-v1request). One addition: using lazy together with `allowedCards` is not recommended.

### POST /verify

Request body and response fields are the same as [POST /v1/verify](#post-v1verify). Results are in [result-codes.md](result-codes.md#lazy-verify-results).

## Optional extras

**Trust badge.** Show payers that Zibal processes their payments by placing this in your site, for example the footer:

```html
<script src="https://zibal.ir/trust/scripts/zibal-trust-v4.js" type="text/javascript"></script>
```

For dark mode, add `?theme=dark` to the script URL. Without a script, replace `{SiteName}` with your domain, without `https://`:

```html
<div>
  <a href="https://gateway.zibal.ir/trustMe/{SiteName}" target="_blank" rel="noopener">
    <img style="max-width: 110px; height: auto;" src="https://zibal.ir/trust/assets/2.png" />
  </a>
</div>
```

In Next.js, load the script with `next/script` inside `<div id='zibal'>`. To resize the logo, set a `height` on `#zibal img` with `!important`.

**Transaction notifications.** The Telegram bot `ZibalBot` (https://t.me/ZibalBot) sends notices of successful transactions on all of an account's gateways once connected to the account.
