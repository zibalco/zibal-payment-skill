# Zibal IPG result and status codes

Every API response carries `result` (the outcome of **the API call**). `status` is a separate field: the state of **the payment**. Do not mix the two: they use different number spaces, and the same number can mean different things in each.

Lookup by endpoint:

| Endpoint | Table |
| --- | --- |
| `POST /v1/request` | [Payment request results](#payment-request-results) |
| `POST /request/lazy` | [Payment request results](#payment-request-results) (identical table) |
| `POST /v1/verify` | [Verify results](#verify-results) |
| `POST /verify` (lazy) | [Lazy verify results](#lazy-verify-results) |
| `POST /v1/inquiry` | [Inquiry results](#inquiry-results) |
| `status` in verify, inquiry and the standard callback | [Payment status](#payment-status) |

Only the codes listed here are documented. Treat any other value as an unknown failure: log it and never treat it as success.

## Payment status

| Status | Meaning | Original (Persian) |
| --- | --- | --- |
| -1 | Awaiting payment | در انتظار پرداخت |
| -2 | Internal error | خطای داخلی |
| 1 | Paid – verified | پرداخت شده - تاییدشده |
| 2 | Paid – not verified | پرداخت شده - تاییدنشده |
| 3 | Cancelled by the user | لغوشده توسط کاربر |
| 4 | Invalid card number | شماره کارت نامعتبر می‌باشد. |
| 5 | Insufficient account balance | موجودی حساب کافی نمی‌باشد. |
| 6 | Incorrect password entered | رمز واردشده اشتباه می‌باشد. |
| 7 | Number of requests exceeds the allowed limit | تعداد درخواست‌ها بیش از حد مجاز می‌باشد. |
| 8 | Daily number of internet payments exceeds the allowed limit | تعداد پرداخت اینترنتی روزانه بیش از حد مجاز می‌باشد. |
| 9 | Daily internet payment amount exceeds the allowed limit | مبلغ پرداخت اینترنتی روزانه بیش از حد مجاز می‌باشد. |
| 10 | Invalid card issuer | صادرکننده‌ی کارت نامعتبر می‌باشد. |
| 11 | Switch error | خطای سوییچ |
| 12 | Card not accessible | کارت قابل دسترسی نمی‌باشد. |
| 15 | Transaction refunded | تراکنش استرداد شده |
| 16 | Transaction being refunded | تراکنش در حال استرداد |
| 18 | Transaction reversed | تراکنش ریورس شده |
| 21 | Invalid acceptor (merchant) | پذیرنده نامعتبر است |

## Payment request results

Applies to `POST /v1/request` and `POST /request/lazy`.

| Code | Meaning | Original (Persian) |
| --- | --- | --- |
| 100 | Completed successfully | با موفقیت انجام شد. |
| 102 | `merchant` not found | `merchant` یافت نشد. |
| 103 | `merchant` inactive / contract for this gateway not signed | `merchant` غیرفعال / عدم امضا قرارداد درگاه مربوطه |
| 104 | `merchant` invalid | `merchant` نامعتبر |
| 105 | `amount` must be at least 1,000 Rials | `amount` باید حداقل 1,000 ریال باشد. |
| 106 | `callbackUrl` invalid (must start with http or https, and its domain must be related to the website registered for the gateway) | `callbackUrl` نامعتبر می‌باشد. (باید با http یا https شروع شود و دامنه آن با وب‌سایت ثبت‌شده برای درگاه مرتبط باشد) |
| 107 | `percentMode` invalid (only 0 and 1 are accepted) | `percentMode` نامعتبر می‌باشد. (تنها 0 و 1 قابل قبول هستند) |
| 108 | One or more beneficiaries in `multiplexingInfos` are invalid | یک یا چند ذی‌نفع در `multiplexingInfos` نامعتبر می‌باشند. |
| 109 | One or more beneficiaries in `multiplexingInfos` are inactive | یک یا چند ذی‌نفع در `multiplexingInfos` غیرفعال می‌باشند. |
| 110 | With `feeMode: 0`, no item in `multiplexingInfos` is marked `wagePayer` and there is no `self` beneficiary either | در حالت `feeMode: 0`، هیچ آیتمی در `multiplexingInfos` به‌عنوان `wagePayer` مشخص نشده و ذی‌نفع `self` هم در آن وجود ندارد. |
| 111 | `amount` does not equal the sum of the shares in `multiplexingInfos` | `amount` با مجموع سهم‌ها در `multiplexingInfos` برابر نمی‌باشد. |
| 112 | Fee wallet balance is insufficient to deduct the fee | موجودی کیف پول کارمزد جهت کسر کارمزد کافی نیست. |
| 113 | `amount` exceeds the allowed ceiling (the overall ceiling is 4,000,000,000 Rials; your gateway may have a lower one) | `amount` مبلغ تراکنش از سقف مجاز بیشتر است. (سقف کلی 4,000,000,000 ریال است و ممکن است برای درگاه شما سقف کمتری تعیین شده باشد) |
| 114 | The submitted national code is invalid | کد ملی ارسالی نامعتبر است. |
| 115 | Your IP is not registered in the user panel | ip شما در پنل کاربری ثبت نشده است. |
| 116 | `feeMode` invalid (only integers are accepted) | `feeMode` نامعتبر می‌باشد. (تنها عدد صحیح قابل قبول است) |
| 118 | `multiplexingInfos` structure invalid (each item must have either `bankAccount` or `subMerchantId`) | ساختار `multiplexingInfos` نامعتبر است. (هر آیتم باید یکی از فیلدهای `bankAccount` یا `subMerchantId` را داشته باشد) |
| 140 | `callbackUrl` was not sent | `callbackUrl` ارسال نشده است. |
| 141 | The share of the beneficiary the fee is deducted from (`wagePayer` or `self`) is less than the fee amount | سهم ذی‌نفعی که کارمزد از آن کسر می‌شود ( `wagePayer` یا `self` ) از مبلغ کارمزد کمتر است. |

## Verify results

Applies to `POST /v1/verify`.

| Code | Meaning | Original (Persian) |
| --- | --- | --- |
| 100 | Verified successfully | با موفقیت تایید شد. |
| 102 | `merchant` not found | `merchant` یافت نشد. |
| 103 | `merchant` inactive | `merchant` غیرفعال |
| 104 | `merchant` invalid | `merchant` نامعتبر |
| 115 | Your IP is not registered in the user panel | ip شما در پنل کاربری ثبت نشده است. |
| 201 | Already verified | قبلا تایید شده |
| 202 | Order unpaid or failed (see the status table for details) | سفارش پرداخت نشده یا ناموفق بوده است. ( جهت اطلاعات بیشتر جدول وضعیت‌ها را مطالعه کنید) |
| 203 | `trackId` invalid | `trackId` نامعتبر می‌باشد. |

## Lazy verify results

Applies to `POST /verify`. Same as the verify table, plus `-1`.

| Code | Meaning | Original (Persian) |
| --- | --- | --- |
| -1 | Another request for this transaction is being processed | درخواست دیگری برای این تراکنش در حال پردازش است. |
| 100 | Verified successfully | با موفقیت تایید شد. |
| 102 | `merchant` not found | `merchant` یافت نشد. |
| 103 | `merchant` inactive | `merchant` غیرفعال |
| 104 | `merchant` invalid | `merchant` نامعتبر |
| 115 | Your IP is not registered in the user panel | ip شما در پنل کاربری ثبت نشده است. |
| 201 | Already verified | قبلا تایید شده |
| 202 | Order unpaid or failed (see the status table for details) | سفارش پرداخت نشده یا ناموفق بوده است. (به بخش جداول، جدول وضعیت‌ها مراجعه کنید) |
| 203 | `trackId` invalid | `trackId` نامعتبر می‌باشد. |

## Inquiry results

Applies to `POST /v1/inquiry`.

| Code | Meaning | Original (Persian) |
| --- | --- | --- |
| 100 | Report created successfully | با موفقیت گزارش ایجاد شد. |
| 102 | `merchant` not found | `merchant` یافت نشد. |
| 103 | `merchant` inactive | `merchant` غیرفعال |
| 104 | `merchant` invalid | `merchant` نامعتبر |
| 203 | `trackId` invalid | `trackId` نامعتبر می‌باشد. |

## How to act on each result

| Situation | Action |
| --- | --- |
| Request `100` | Save `trackId`, redirect the payer. |
| Request `102`, `103`, `104`, `115`, `140`, `106`, `107`, `108`, `109`, `110`, `111`, `112`, `116`, `118`, `141` | Configuration or integration problem. Log the code, show the payer a generic error, fix the integration. Do not retry. |
| Request `105`, `113` | Amount is out of range. Check the Rial conversion first, then the order total. |
| Request `114` | Ask the payer to correct the national code. |
| Verify `100` | Check `status` and `amount` against the stored order, then mark paid. |
| Verify `201` | The session is already verified. Do not assume it was for this order's full amount: read it with `POST /v1/inquiry`, run the same checks, then mark paid. |
| Verify `202` | Not paid. Mark the attempt failed, but keep it eligible for a later successful verify. |
| Verify `203` | Unknown `trackId` for this merchant. Do not mark paid. Log it. |
| Verify `102`, `103`, `104`, `115` | Configuration problem. Leave the order pending, alert the developer, verify again once fixed. |
| Lazy verify `-1` | Another request is handling this transaction. Do nothing now; check again shortly. |

