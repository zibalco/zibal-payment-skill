# Zibal with Django

Django 5 or later, `requests`, and the Django ORM, in an app called `payments`.

## Setup

```bash
pip install django requests
```

**`.env`** (load it with your usual method)

```bash
ZIBAL_MERCHANT=zibal             # zibal is the documented test account
APP_URL=http://localhost:8000    # public base URL; its domain must relate to the gateway's registered website
```

**`settings.py`** (add)

```python
import os

INSTALLED_APPS += ["payments"]

ZIBAL_MERCHANT = os.environ["ZIBAL_MERCHANT"]
APP_URL = os.environ["APP_URL"]

# Required. Django's default, "same-origin", removes the Referer header when
# the payer leaves for the gateway, and Zibal then refuses to open the payment page.
SECURE_REFERRER_POLICY = "strict-origin-when-cross-origin"
```

**`urls.py`** (project)

```python
from django.urls import include, path

urlpatterns = [path("", include("payments.urls"))]
```

## Data model

**`payments/models.py`**

```python
from django.db import models


class Payment(models.Model):
    class Status(models.TextChoices):
        PENDING = "pending"
        PAID = "paid"
        FAILED = "failed"
        NEEDS_REVIEW = "needs_review"

    order_id = models.CharField(max_length=64, unique=True)
    track_id = models.BigIntegerField(unique=True, null=True)
    amount = models.BigIntegerField()  # Rials
    mode = models.CharField(max_length=16, default="standard")  # standard | lazy
    status = models.CharField(max_length=16, choices=Status, default=Status.PENDING)
    ref_number = models.CharField(max_length=64, null=True)
    paid_at = models.CharField(max_length=40, null=True)  # verbatim from Zibal: the docs give no timezone
    created_at = models.DateTimeField(auto_now_add=True)
```

Then run `python manage.py makemigrations payments && python manage.py migrate`.

## Code

**`payments/zibal.py`**

```python
import logging
import time

import requests
from django.conf import settings

from .models import Payment

logger = logging.getLogger(__name__)

ZIBAL_BASE = "https://gateway.zibal.ir"

# Result codes for /v1/request and /request/lazy. Log these; never show them to payers.
REQUEST_RESULTS = {
    102: "merchant not found",
    103: "merchant inactive or contract not signed",
    104: "merchant invalid",
    105: "amount must be at least 1,000 Rials",
    106: "callbackUrl invalid or not related to the registered website",
    107: "percentMode invalid",
    108: "invalid beneficiary in multiplexingInfos",
    109: "inactive beneficiary in multiplexingInfos",
    110: "no wagePayer or self beneficiary with feeMode 0",
    111: "amount does not equal the sum of multiplexingInfos shares",
    112: "fee wallet balance insufficient",
    113: "amount exceeds the allowed ceiling",
    114: "national code invalid",
    115: "server IP not registered in the Zibal panel",
    116: "feeMode invalid",
    118: "multiplexingInfos structure invalid",
    140: "callbackUrl not sent",
    141: "fee payer share is less than the fee",
}

# Result codes for /v1/verify and /verify that need a developer.
VERIFY_RESULTS = {
    102: "merchant not found",
    103: "merchant inactive",
    104: "merchant invalid",
    115: "server IP not registered in the Zibal panel",
    203: "trackId invalid",
}


def zibal_post(path, body, retries=0):
    attempt = 0
    while True:
        try:
            response = requests.post(
                f"{ZIBAL_BASE}{path}",
                json={"merchant": settings.ZIBAL_MERCHANT, **body},
                timeout=15,
            )
            if response.status_code >= 500:
                raise requests.HTTPError(f"Zibal HTTP {response.status_code}")
            return response.json()
        except (requests.RequestException, ValueError):
            if attempt >= retries:
                raise
            time.sleep(0.5 * 2**attempt)
            attempt += 1


def fulfil(payment):
    # Ship the order here. Runs once per payment.
    logger.info("fulfilling order %s", payment.order_id)


def set_status(payment, status):
    Payment.objects.filter(
        pk=payment.pk, status__in=[Payment.Status.PENDING, Payment.Status.FAILED]
    ).update(status=status)


def mark_paid(payment, verified):
    changed = (
        Payment.objects.filter(pk=payment.pk)
        .exclude(status=Payment.Status.PAID)
        .update(
            status=Payment.Status.PAID,
            ref_number=verified.get("refNumber"),
            paid_at=verified.get("paidAt"),
        )
    )
    if changed == 1:
        fulfil(payment)


def settle(payment):
    """Decides the payment's outcome from the verify response only."""
    if payment.status in (Payment.Status.PAID, Payment.Status.NEEDS_REVIEW):
        return payment.status

    body = {"trackId": payment.track_id}
    verify_path = "/verify" if payment.mode == "lazy" else "/v1/verify"

    try:
        verified = zibal_post(verify_path, body, retries=2)
        if verified.get("result") == 201:
            # Already verified: confirm the session's real amount and status.
            verified = zibal_post("/v1/inquiry", body, retries=2)
            if verified.get("result") != 100:
                set_status(payment, Payment.Status.NEEDS_REVIEW)
                return Payment.Status.NEEDS_REVIEW
    except (requests.RequestException, ValueError) as error:
        logger.error("verify unreachable for payment %s: %s", payment.pk, type(error).__name__)
        return Payment.Status.PENDING  # a background job must verify this later

    result = verified.get("result")

    if result == 202:
        set_status(payment, Payment.Status.FAILED)
        return Payment.Status.FAILED
    if result == -1:
        return Payment.Status.PENDING  # lazy: another request is processing it
    if result != 100:
        reason = VERIFY_RESULTS.get(result, "unknown result")
        logger.error("verify failed for payment %s: %s %s", payment.pk, result, reason)
        return Payment.Status.PENDING

    if verified.get("status") != 1 or verified.get("amount") != payment.amount:
        logger.error("verify mismatch for payment %s: needs manual review", payment.pk)
        set_status(payment, Payment.Status.NEEDS_REVIEW)
        return Payment.Status.NEEDS_REVIEW

    mark_paid(payment, verified)
    return Payment.Status.PAID
```

**`payments/views.py`**

```python
import json
import logging
import uuid

import requests
from django.conf import settings
from django.http import HttpResponse, JsonResponse
from django.shortcuts import get_object_or_404, redirect
from django.urls import reverse
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_GET, require_http_methods, require_POST

from .models import Payment
from .zibal import REQUEST_RESULTS, ZIBAL_BASE, settle, zibal_post

logger = logging.getLogger(__name__)

# Prices live on the server. The amount never comes from the client.
PRICES_RIAL = {"basic": 160000, "pro": 490000}

RESULT_MESSAGES = {
    Payment.Status.PAID: "Payment successful.",
    Payment.Status.FAILED: "Payment failed or was cancelled.",
    Payment.Status.PENDING: "We are still confirming your payment.",
    Payment.Status.NEEDS_REVIEW: "Your payment is being reviewed. Please contact support.",
}


def create_payment(request, mode):
    amount = PRICES_RIAL.get(request.POST.get("product"))
    if amount is None:
        return HttpResponse("Unknown product", status=400)

    order_id = str(uuid.uuid4())
    request_path = "/request/lazy" if mode == "lazy" else "/v1/request"

    try:
        response = zibal_post(
            request_path,
            {
                "amount": amount,
                "callbackUrl": f"{settings.APP_URL}{reverse('payment-callback')}",
                "description": f"Order {order_id}",
                "orderId": order_id,
            },
        )
    except (requests.RequestException, ValueError) as error:
        logger.error("payment request unreachable: %s", type(error).__name__)
        return HttpResponse("Payment service is unavailable. Please try again.", status=502)

    result = response.get("result")
    if result != 100:
        logger.error(
            "payment request failed: %s %s", result, REQUEST_RESULTS.get(result, "unknown result")
        )
        return HttpResponse("Could not start the payment.", status=502)

    Payment.objects.create(
        order_id=order_id, track_id=response["trackId"], amount=amount, mode=mode
    )

    # 303 from a form post keeps the browser on a same-site Referer, which Zibal requires.
    return HttpResponse(status=303, headers={"Location": f"{ZIBAL_BASE}/start/{response['trackId']}"})


@require_POST
def pay(request):
    return create_payment(request, "standard")


@require_POST
def pay_lazy(request):
    return create_payment(request, "lazy")


def find_by_track_id(track_id):
    value = str(track_id or "")
    if not value.isascii() or not value.isdigit() or len(value) > 19 or int(value) >= 2**63:
        return None
    return Payment.objects.filter(track_id=int(value)).first()


# The lazy callback is a POST from outside your site, so it cannot carry a CSRF token.
@csrf_exempt
@require_http_methods(["GET", "POST"])
def callback(request):
    if request.method == "GET":
        # Standard callback: GET with a query string.
        payment = find_by_track_id(request.GET.get("trackId"))
        if payment is None:
            return HttpResponse("Unknown payment", status=404)
        settle(payment)
        return redirect("payment-result", order_id=payment.order_id)

    # Lazy callback: POST with a JSON body.
    try:
        body = json.loads(request.body)
    except ValueError:
        body = None
    payment = find_by_track_id(body.get("trackId")) if isinstance(body, dict) else None
    if payment is None:
        return JsonResponse({"error": "unknown payment"}, status=404)
    # To decline a lazy payment, return here without calling settle.
    # Zibal returns the money to the card 20 minutes after payment.
    return JsonResponse({"status": settle(payment)})


# The result page reads the database, never the callback parameters.
@require_GET
def result(request, order_id):
    payment = get_object_or_404(Payment, order_id=order_id)
    return HttpResponse(RESULT_MESSAGES[payment.status])
```

**`payments/urls.py`**

```python
from django.urls import path

from . import views

urlpatterns = [
    path("pay", views.pay, name="pay"),
    path("pay/lazy", views.pay_lazy, name="pay-lazy"),
    path("payment/callback", views.callback, name="payment-callback"),
    path("payment/result/<str:order_id>", views.result, name="payment-result"),
]
```

**Checkout form** (template). The payer must leave from a page on your site so the browser sends `Referer`:

```html
<form method="post" action="{% url 'pay' %}">
  {% csrf_token %}
  <input type="hidden" name="product" value="basic">
  <button type="submit">Pay</button>
</form>
```

## Notes

- Delete `pay_lazy`, its URL and the `POST` branch of `callback` if you do not use lazy mode. Then `@csrf_exempt` can go too.
- Add a management command, run on a schedule, that calls `settle` on `pending` rows older than a few minutes. For lazy payments it must run well inside the 20-minute limit.
