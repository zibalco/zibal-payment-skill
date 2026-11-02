# Zibal with FastAPI

FastAPI, `httpx` and SQLAlchemy 2. Routes are plain `def`, so FastAPI runs the blocking database and HTTP calls in its thread pool. If the project is fully async, use `httpx.AsyncClient` and an async session with the same logic.

## Setup

```bash
pip install fastapi uvicorn httpx sqlalchemy python-multipart
```

**`.env`** (load it with your usual method)

```bash
ZIBAL_MERCHANT=zibal             # zibal is the documented test account
APP_URL=http://localhost:8000    # public base URL; its domain must relate to the gateway's registered website
DATABASE_URL=sqlite:///./payments.db
```

Run with `uvicorn main:app`.

## Code

**`main.py`**

```python
import logging
import os
import time
import uuid
from typing import Annotated

import httpx
from fastapi import Depends, FastAPI, Form, HTTPException
from fastapi.responses import PlainTextResponse, RedirectResponse
from pydantic import BaseModel
from sqlalchemy import BigInteger, String, create_engine, select, update
from sqlalchemy.orm import DeclarativeBase, Mapped, Session, mapped_column, sessionmaker

logger = logging.getLogger("payments")

ZIBAL_BASE = "https://gateway.zibal.ir"
MERCHANT = os.environ["ZIBAL_MERCHANT"]
APP_URL = os.environ["APP_URL"]
DATABASE_URL = os.environ.get("DATABASE_URL", "sqlite:///./payments.db")

# Prices live on the server. The amount never comes from the client.
PRICES_RIAL = {"basic": 160000, "pro": 490000}

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

RESULT_MESSAGES = {
    "paid": "Payment successful.",
    "failed": "Payment failed or was cancelled.",
    "pending": "We are still confirming your payment.",
    "needs_review": "Your payment is being reviewed. Please contact support.",
}


class Base(DeclarativeBase):
    pass


class Payment(Base):
    __tablename__ = "payments"

    id: Mapped[int] = mapped_column(primary_key=True)
    order_id: Mapped[str] = mapped_column(String(64), unique=True)
    track_id: Mapped[int | None] = mapped_column(BigInteger, unique=True)
    amount: Mapped[int] = mapped_column(BigInteger)  # Rials
    mode: Mapped[str] = mapped_column(String(16), default="standard")  # standard | lazy
    status: Mapped[str] = mapped_column(String(16), default="pending")  # pending | paid | failed | needs_review
    ref_number: Mapped[str | None] = mapped_column(String(64))
    paid_at: Mapped[str | None] = mapped_column(String(40))  # verbatim from Zibal: the docs give no timezone


engine = create_engine(DATABASE_URL)
SessionLocal = sessionmaker(engine, expire_on_commit=False)
Base.metadata.create_all(engine)

http = httpx.Client(base_url=ZIBAL_BASE, timeout=15)
app = FastAPI()


def get_db():
    with SessionLocal() as session:
        yield session


Db = Annotated[Session, Depends(get_db)]


def zibal_post(path: str, body: dict, retries: int = 0) -> dict:
    attempt = 0
    while True:
        try:
            response = http.post(path, json={"merchant": MERCHANT, **body})
            if response.status_code >= 500:
                raise httpx.HTTPError(f"Zibal HTTP {response.status_code}")
            return response.json()
        except (httpx.HTTPError, ValueError):
            if attempt >= retries:
                raise
            time.sleep(0.5 * 2**attempt)
            attempt += 1


def fulfil(payment: Payment) -> None:
    # Ship the order here. Runs once per payment.
    logger.info("fulfilling order %s", payment.order_id)


def set_status(db: Session, payment: Payment, status: str) -> None:
    db.execute(
        update(Payment)
        .where(Payment.id == payment.id, Payment.status.in_(["pending", "failed"]))
        .values(status=status)
    )
    db.commit()


def mark_paid(db: Session, payment: Payment, verified: dict) -> None:
    changed = db.execute(
        update(Payment)
        .where(Payment.id == payment.id, Payment.status != "paid")
        .values(
            status="paid",
            ref_number=None if verified.get("refNumber") is None else str(verified["refNumber"]),
            paid_at=verified.get("paidAt"),
        )
    ).rowcount
    db.commit()
    if changed == 1:
        fulfil(payment)


def settle(db: Session, payment: Payment) -> str:
    """Decides the payment's outcome from the verify response only."""
    if payment.status in ("paid", "needs_review"):
        return payment.status

    body = {"trackId": payment.track_id}
    verify_path = "/verify" if payment.mode == "lazy" else "/v1/verify"

    try:
        verified = zibal_post(verify_path, body, retries=2)
        if verified.get("result") == 201:
            # Already verified: confirm the session's real amount and status.
            verified = zibal_post("/v1/inquiry", body, retries=2)
            if verified.get("result") != 100:
                set_status(db, payment, "needs_review")
                return "needs_review"
    except (httpx.HTTPError, ValueError) as error:
        logger.error("verify unreachable for payment %s: %s", payment.id, type(error).__name__)
        return "pending"  # a background job must verify this later

    result = verified.get("result")

    if result == 202:
        set_status(db, payment, "failed")
        return "failed"
    if result == -1:
        return "pending"  # lazy: another request is processing it
    if result != 100:
        reason = VERIFY_RESULTS.get(result, "unknown result")
        logger.error("verify failed for payment %s: %s %s", payment.id, result, reason)
        return "pending"

    if verified.get("status") != 1 or verified.get("amount") != payment.amount:
        logger.error("verify mismatch for payment %s: needs manual review", payment.id)
        set_status(db, payment, "needs_review")
        return "needs_review"

    mark_paid(db, payment, verified)
    return "paid"


def create_payment(db: Session, product: str, mode: str) -> RedirectResponse:
    amount = PRICES_RIAL.get(product)
    if amount is None:
        raise HTTPException(400, "Unknown product")

    order_id = str(uuid.uuid4())
    request_path = "/request/lazy" if mode == "lazy" else "/v1/request"

    try:
        response = zibal_post(
            request_path,
            {
                "amount": amount,
                "callbackUrl": f"{APP_URL}/payment/callback",
                "description": f"Order {order_id}",
                "orderId": order_id,
            },
        )
    except (httpx.HTTPError, ValueError) as error:
        logger.error("payment request unreachable: %s", type(error).__name__)
        raise HTTPException(502, "Payment service is unavailable. Please try again.")

    result = response.get("result")
    if result != 100:
        logger.error(
            "payment request failed: %s %s", result, REQUEST_RESULTS.get(result, "unknown result")
        )
        raise HTTPException(502, "Could not start the payment.")

    db.add(Payment(order_id=order_id, track_id=response["trackId"], amount=amount, mode=mode))
    db.commit()

    # 303 from a form post keeps the browser on a same-site Referer, which Zibal requires.
    return RedirectResponse(f"{ZIBAL_BASE}/start/{response['trackId']}", status_code=303)


def find_by_track_id(db: Session, track_id: int | str | None) -> Payment | None:
    value = str(track_id or "")
    if not value.isascii() or not value.isdigit() or len(value) > 19 or int(value) >= 2**63:
        return None
    return db.scalar(select(Payment).where(Payment.track_id == int(value)))


@app.post("/pay")
def pay(product: Annotated[str, Form()], db: Db):
    return create_payment(db, product, "standard")


@app.post("/pay/lazy")
def pay_lazy(product: Annotated[str, Form()], db: Db):
    return create_payment(db, product, "lazy")


# Standard callback: GET with a query string.
@app.get("/payment/callback")
def callback(db: Db, trackId: str | None = None):
    payment = find_by_track_id(db, trackId)
    if payment is None:
        raise HTTPException(404, "Unknown payment")
    settle(db, payment)
    return RedirectResponse(f"/payment/result/{payment.order_id}", status_code=303)


class LazyCallback(BaseModel):
    trackId: int | str | None = None


# Lazy callback: POST with a JSON body.
@app.post("/payment/callback")
def lazy_callback(body: LazyCallback, db: Db):
    payment = find_by_track_id(db, body.trackId)
    if payment is None:
        raise HTTPException(404, "Unknown payment")
    # To decline a lazy payment, return here without calling settle.
    # Zibal returns the money to the card 20 minutes after payment.
    return {"status": settle(db, payment)}


# The result page reads the database, never the callback parameters.
@app.get("/payment/result/{order_id}", response_class=PlainTextResponse)
def result(order_id: str, db: Db):
    payment = db.scalar(select(Payment).where(Payment.order_id == order_id))
    if payment is None:
        raise HTTPException(404, "Unknown payment")
    return RESULT_MESSAGES[payment.status]
```

**Checkout form.** Serve this from your own site. The payer must leave from a page on your site so the browser sends `Referer`:

```html
<form method="post" action="/pay">
  <input type="hidden" name="product" value="basic">
  <button type="submit">Pay</button>
</form>
```

## Notes

- Delete `pay_lazy` and `lazy_callback` if you do not use lazy mode.
- For production, manage the schema with Alembic instead of `create_all`, and use PostgreSQL or MySQL.
- Add a scheduled job that calls `settle` on `pending` rows older than a few minutes. For lazy payments it must run well inside the 20-minute limit.
