# Zibal with Laravel

Laravel 11+, PHP 8.2+, the `Http` client and Eloquent.

## Setup

**`.env`**

```bash
ZIBAL_MERCHANT=zibal             # zibal is the documented test account
APP_URL=http://localhost:8000    # public base URL; its domain must relate to the gateway's registered website
```

**`config/services.php`** (add this key)

```php
'zibal' => [
    'merchant' => env('ZIBAL_MERCHANT'),
],
```

**`bootstrap/app.php`**: the lazy callback is a `POST` from outside your site, so exclude it from CSRF.

```php
->withMiddleware(function (Middleware $middleware) {
    $middleware->validateCsrfTokens(except: ['payment/callback']);
})
```

## Data model

**`database/migrations/2026_01_01_000000_create_payments_table.php`**

```php
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('payments', function (Blueprint $table) {
            $table->id();
            $table->string('order_id')->unique();
            $table->unsignedBigInteger('track_id')->nullable()->unique();
            $table->unsignedBigInteger('amount'); // Rials
            $table->string('mode')->default('standard'); // standard | lazy
            $table->string('status')->default('pending'); // pending | paid | failed | needs_review
            $table->string('ref_number')->nullable();
            $table->string('paid_at')->nullable(); // verbatim from Zibal: the docs give no timezone
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('payments');
    }
};
```

**`app/Models/Payment.php`**

```php
<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class Payment extends Model
{
    protected $fillable = ['order_id', 'track_id', 'amount', 'mode', 'status', 'ref_number', 'paid_at'];

    protected $casts = ['track_id' => 'integer', 'amount' => 'integer'];
}
```

## Code

**`app/Services/ZibalGateway.php`**

```php
<?php

namespace App\Services;

use App\Models\Payment;
use Exception;
use Illuminate\Http\Client\ConnectionException;
use Illuminate\Http\Client\RequestException;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;
use RuntimeException;

class ZibalGateway
{
    public const BASE_URL = 'https://gateway.zibal.ir';

    // Result codes for /v1/request and /request/lazy. Log these; never show them to payers.
    public const REQUEST_RESULTS = [
        102 => 'merchant not found',
        103 => 'merchant inactive or contract not signed',
        104 => 'merchant invalid',
        105 => 'amount must be at least 1,000 Rials',
        106 => 'callbackUrl invalid or not related to the registered website',
        107 => 'percentMode invalid',
        108 => 'invalid beneficiary in multiplexingInfos',
        109 => 'inactive beneficiary in multiplexingInfos',
        110 => 'no wagePayer or self beneficiary with feeMode 0',
        111 => 'amount does not equal the sum of multiplexingInfos shares',
        112 => 'fee wallet balance insufficient',
        113 => 'amount exceeds the allowed ceiling',
        114 => 'national code invalid',
        115 => 'server IP not registered in the Zibal panel',
        116 => 'feeMode invalid',
        118 => 'multiplexingInfos structure invalid',
        140 => 'callbackUrl not sent',
        141 => 'fee payer share is less than the fee',
    ];

    // Result codes for /v1/verify and /verify that need a developer.
    private const VERIFY_RESULTS = [
        102 => 'merchant not found',
        103 => 'merchant inactive',
        104 => 'merchant invalid',
        115 => 'server IP not registered in the Zibal panel',
        203 => 'trackId invalid',
    ];

    public function post(string $path, array $body, int $retries = 0): array
    {
        $response = Http::baseUrl(self::BASE_URL)
            ->acceptJson()
            ->timeout(15)
            ->retry(
                $retries + 1,
                fn (int $attempt) => 500 * 2 ** ($attempt - 1),
                fn (Exception $e) => $e instanceof ConnectionException
                    || ($e instanceof RequestException && $e->response->serverError()),
                throw: false,
            )
            ->post($path, ['merchant' => config('services.zibal.merchant')] + $body);

        $json = $response->json();
        if ($response->serverError() || ! is_array($json)) {
            throw new RuntimeException("Zibal HTTP {$response->status()}");
        }

        return $json;
    }

    /**
     * Decides the payment's outcome from the verify response only.
     * Returns: paid | failed | pending | needs_review
     */
    public function settle(Payment $payment): string
    {
        if (in_array($payment->status, ['paid', 'needs_review'], true)) {
            return $payment->status;
        }

        $body = ['trackId' => $payment->track_id];
        $verifyPath = $payment->mode === 'lazy' ? '/verify' : '/v1/verify';

        try {
            $verified = $this->post($verifyPath, $body, retries: 2);
            if (($verified['result'] ?? null) === 201) {
                // Already verified: confirm the session's real amount and status.
                $verified = $this->post('/v1/inquiry', $body, retries: 2);
                if (($verified['result'] ?? null) !== 100) {
                    return $this->flagForReview($payment);
                }
            }
        } catch (ConnectionException|RuntimeException $e) {
            Log::error("verify unreachable for payment {$payment->id}: {$e->getMessage()}");

            return 'pending'; // a background job must verify this later
        }

        $result = $verified['result'] ?? null;

        if ($result === 202) {
            $this->setStatus($payment, 'failed');

            return 'failed';
        }
        if ($result === -1) {
            return 'pending'; // lazy: another request is processing it
        }
        if ($result !== 100) {
            $reason = self::VERIFY_RESULTS[$result] ?? 'unknown result';
            Log::error("verify failed for payment {$payment->id}: {$result} {$reason}");

            return 'pending';
        }

        if (($verified['status'] ?? null) !== 1 || ($verified['amount'] ?? null) !== $payment->amount) {
            return $this->flagForReview($payment);
        }

        $this->markPaid($payment, $verified);

        return 'paid';
    }

    private function markPaid(Payment $payment, array $verified): void
    {
        $changed = Payment::whereKey($payment->id)
            ->where('status', '!=', 'paid')
            ->update([
                'status' => 'paid',
                'ref_number' => $verified['refNumber'] ?? null,
                'paid_at' => $verified['paidAt'] ?? null,
            ]);

        if ($changed === 1) {
            $this->fulfil($payment);
        }
    }

    private function setStatus(Payment $payment, string $status): void
    {
        Payment::whereKey($payment->id)
            ->whereIn('status', ['pending', 'failed'])
            ->update(['status' => $status]);
    }

    private function flagForReview(Payment $payment): string
    {
        Log::error("verify mismatch for payment {$payment->id}: needs manual review");
        $this->setStatus($payment, 'needs_review');

        return 'needs_review';
    }

    private function fulfil(Payment $payment): void
    {
        // Ship the order here. Runs once per payment.
        Log::info("fulfilling order {$payment->order_id}");
    }
}
```

**`app/Http/Controllers/PaymentController.php`**

```php
<?php

namespace App\Http\Controllers;

use App\Models\Payment;
use App\Services\ZibalGateway;
use Illuminate\Http\Client\ConnectionException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Str;
use RuntimeException;

class PaymentController extends Controller
{
    // Prices live on the server. The amount never comes from the client.
    private const PRICES_RIAL = ['basic' => 160000, 'pro' => 490000];

    public function __construct(private ZibalGateway $zibal) {}

    public function pay(Request $request)
    {
        return $this->createPayment($request, 'standard');
    }

    public function payLazy(Request $request)
    {
        return $this->createPayment($request, 'lazy');
    }

    // Standard callback: GET with a query string.
    public function callback(Request $request)
    {
        $payment = $this->findByTrackId($request->query('trackId'));
        abort_if($payment === null, 404);

        $this->zibal->settle($payment);

        return redirect()->route('payment.result', $payment->order_id, 303);
    }

    // Lazy callback: POST with a JSON body.
    public function lazyCallback(Request $request)
    {
        $payment = $this->findByTrackId($request->json('trackId'));
        abort_if($payment === null, 404);

        // To decline a lazy payment, return here without calling settle.
        // Zibal returns the money to the card 20 minutes after payment.
        return response()->json(['status' => $this->zibal->settle($payment)]);
    }

    // The result page reads the database, never the callback parameters.
    public function result(string $orderId)
    {
        $payment = Payment::where('order_id', $orderId)->firstOrFail();

        return response(match ($payment->status) {
            'paid' => 'Payment successful.',
            'failed' => 'Payment failed or was cancelled.',
            'pending' => 'We are still confirming your payment.',
            'needs_review' => 'Your payment is being reviewed. Please contact support.',
        });
    }

    private function createPayment(Request $request, string $mode)
    {
        $product = $request->input('product');
        $amount = is_string($product) ? (self::PRICES_RIAL[$product] ?? null) : null;
        abort_if($amount === null, 400, 'Unknown product');

        $orderId = (string) Str::uuid();
        $requestPath = $mode === 'lazy' ? '/request/lazy' : '/v1/request';

        try {
            $response = $this->zibal->post($requestPath, [
                'amount' => $amount,
                'callbackUrl' => route('payment.callback'),
                'description' => "Order {$orderId}",
                'orderId' => $orderId,
            ]);
        } catch (ConnectionException|RuntimeException $e) {
            Log::error("payment request unreachable: {$e->getMessage()}");

            return response('Payment service is unavailable. Please try again.', 502);
        }

        $result = $response['result'] ?? null;
        if ($result !== 100) {
            $reason = ZibalGateway::REQUEST_RESULTS[$result] ?? 'unknown result';
            Log::error("payment request failed: {$result} {$reason}");

            return response('Could not start the payment.', 502);
        }

        Payment::create([
            'order_id' => $orderId,
            'track_id' => $response['trackId'],
            'amount' => $amount,
            'mode' => $mode,
        ]);

        // 303 from a form post keeps the browser on a same-site Referer, which Zibal requires.
        return redirect()->away(ZibalGateway::BASE_URL."/start/{$response['trackId']}", 303);
    }

    private function findByTrackId(mixed $trackId): ?Payment
    {
        if (! preg_match('/^\d{1,19}$/', (string) (is_scalar($trackId) ? $trackId : ''))) {
            return null;
        }

        return Payment::where('track_id', $trackId)->first();
    }
}
```

**`routes/web.php`**

```php
<?php

use App\Http\Controllers\PaymentController;
use Illuminate\Support\Facades\Route;

Route::post('/pay', [PaymentController::class, 'pay']);
Route::post('/pay/lazy', [PaymentController::class, 'payLazy']);
Route::get('/payment/callback', [PaymentController::class, 'callback'])->name('payment.callback');
Route::post('/payment/callback', [PaymentController::class, 'lazyCallback']);
Route::get('/payment/result/{orderId}', [PaymentController::class, 'result'])->name('payment.result');
```

**Checkout form** (Blade). The payer must leave from a page on your site so the browser sends `Referer`:

```blade
<form method="post" action="/pay">
    @csrf
    <input type="hidden" name="product" value="basic">
    <button type="submit">Pay</button>
</form>
```

## Notes

- Delete `payLazy`, `lazyCallback`, their routes and the CSRF exclusion if you do not use lazy mode.
- `route('payment.callback')` follows the current request's host. Behind a proxy, configure trusted proxies so it stays your public domain.
- Add a scheduled command that calls `settle` on `pending` rows older than a few minutes. For lazy payments it must run well inside the 20-minute limit.
