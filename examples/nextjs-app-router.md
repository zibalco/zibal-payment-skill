# Zibal with Next.js App Router

Next.js 15 or later, TypeScript, the built-in `fetch`, and Prisma 6. All Zibal code runs on the server; `merchant` must never use the `NEXT_PUBLIC_` prefix.

## Setup

```bash
npm install @prisma/client@6
npm install -D prisma@6
npx prisma migrate dev --name add-payments
```

**`.env`**

```bash
ZIBAL_MERCHANT=zibal                 # zibal is the documented test account
APP_URL=http://localhost:3000        # public base URL; its domain must relate to the gateway's registered website
DATABASE_URL=file:./dev.db
```

## Data model

**`prisma/schema.prisma`**

```prisma
generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "sqlite"
  url      = env("DATABASE_URL")
}

model Payment {
  id        Int       @id @default(autoincrement())
  orderId   String    @unique
  trackId   String?   @unique // int64 from Zibal, kept as a string in JS
  amount    BigInt // Rials
  mode      String    @default("standard") // standard | lazy
  status    String    @default("pending") // pending | paid | failed | needs_review
  refNumber String?
  paidAt    String? // verbatim from Zibal: the docs give no timezone
  createdAt DateTime  @default(now())
}
```

## Code

**`lib/db.ts`**

```ts
import { PrismaClient } from '@prisma/client';

const globalForPrisma = globalThis as unknown as { prisma?: PrismaClient };

export const db = globalForPrisma.prisma ?? new PrismaClient();

if (process.env.NODE_ENV !== 'production') globalForPrisma.prisma = db;
```

**`lib/zibal.ts`**

```ts
import type { Payment } from '@prisma/client';
import { db } from './db';

export const ZIBAL_BASE = 'https://gateway.zibal.ir';

export type PaymentState = 'paid' | 'failed' | 'pending' | 'needs_review';

type ZibalResponse = {
  result: number;
  message?: string;
  trackId?: number;
  status?: number | null;
  amount?: number;
  refNumber?: number | null;
  paidAt?: string | null;
};

// Result codes for /v1/request and /request/lazy. Log these; never show them to payers.
export const REQUEST_RESULTS: Record<number, string> = {
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
const VERIFY_RESULTS: Record<number, string> = {
  102: 'merchant not found',
  103: 'merchant inactive',
  104: 'merchant invalid',
  115: 'server IP not registered in the Zibal panel',
  203: 'trackId invalid',
};

function merchant(): string {
  const value = process.env.ZIBAL_MERCHANT;
  if (!value) throw new Error('ZIBAL_MERCHANT is required');
  return value;
}

export async function zibalPost(
  path: string,
  body: Record<string, unknown>,
  { retries = 0 } = {},
): Promise<ZibalResponse> {
  for (let attempt = 0; ; attempt += 1) {
    try {
      const response = await fetch(`${ZIBAL_BASE}${path}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ merchant: merchant(), ...body }),
        signal: AbortSignal.timeout(15_000),
        cache: 'no-store',
      });
      if (response.status >= 500) throw new Error(`Zibal HTTP ${response.status}`);
      return (await response.json()) as ZibalResponse;
    } catch (error) {
      if (attempt >= retries) throw error;
      await new Promise((resolve) => setTimeout(resolve, 500 * 2 ** attempt));
    }
  }
}

async function fulfil(payment: Payment) {
  // Ship the order here. Runs once per payment.
  console.log(`fulfilling order ${payment.orderId}`);
}

async function setStatus(payment: Payment, status: PaymentState) {
  await db.payment.updateMany({
    where: { id: payment.id, status: { in: ['pending', 'failed'] } },
    data: { status },
  });
}

async function markPaid(payment: Payment, verified: ZibalResponse) {
  const update = await db.payment.updateMany({
    where: { id: payment.id, status: { not: 'paid' } },
    data: {
      status: 'paid',
      refNumber: verified.refNumber == null ? null : String(verified.refNumber),
      paidAt: verified.paidAt ?? null,
    },
  });
  if (update.count === 1) await fulfil(payment);
}

// Decides the payment's outcome from the verify response only.
export async function settle(payment: Payment): Promise<PaymentState> {
  if (payment.status === 'paid' || payment.status === 'needs_review') {
    return payment.status;
  }

  const body = { trackId: Number(payment.trackId) };
  const verifyPath = payment.mode === 'lazy' ? '/verify' : '/v1/verify';

  let verified: ZibalResponse;
  try {
    verified = await zibalPost(verifyPath, body, { retries: 2 });
    if (verified.result === 201) {
      // Already verified: confirm the session's real amount and status.
      verified = await zibalPost('/v1/inquiry', body, { retries: 2 });
      if (verified.result !== 100) {
        await setStatus(payment, 'needs_review');
        return 'needs_review';
      }
    }
  } catch (error) {
    console.error(`verify unreachable for payment ${payment.id}:`, error);
    return 'pending'; // a background job must verify this later
  }

  if (verified.result === 202) {
    await setStatus(payment, 'failed');
    return 'failed';
  }
  if (verified.result === -1) return 'pending'; // lazy: another request is processing it
  if (verified.result !== 100) {
    const reason = VERIFY_RESULTS[verified.result] ?? 'unknown result';
    console.error(`verify failed for payment ${payment.id}: ${verified.result} ${reason}`);
    return 'pending';
  }

  if (verified.status !== 1 || BigInt(verified.amount ?? -1) !== payment.amount) {
    console.error(`verify mismatch for payment ${payment.id}: needs manual review`);
    await setStatus(payment, 'needs_review');
    return 'needs_review';
  }

  await markPaid(payment, verified);
  return 'paid';
}

export function findByTrackId(trackId: unknown) {
  const value = String(trackId ?? '');
  if (!/^\d+$/.test(value)) return null;
  return db.payment.findUnique({ where: { trackId: value } });
}
```

**`lib/create-payment.ts`**

```ts
import { randomUUID } from 'node:crypto';
import { NextResponse } from 'next/server';
import { db } from './db';
import { REQUEST_RESULTS, ZIBAL_BASE, zibalPost } from './zibal';

// Prices live on the server. The amount never comes from the client.
const PRICES_RIAL = new Map([
  ['basic', 160000],
  ['pro', 490000],
]);

export async function createPayment(request: Request, mode: 'standard' | 'lazy') {
  const form = await request.formData().catch(() => null);
  const amount = PRICES_RIAL.get(String(form?.get('product')));
  if (!amount) return new NextResponse('Unknown product', { status: 400 });

  const orderId = randomUUID();
  const requestPath = mode === 'lazy' ? '/request/lazy' : '/v1/request';

  let response;
  try {
    response = await zibalPost(requestPath, {
      amount,
      callbackUrl: `${process.env.APP_URL}/api/payment/callback`,
      description: `Order ${orderId}`,
      orderId,
    });
  } catch (error) {
    console.error('payment request unreachable:', error);
    return new NextResponse('Payment service is unavailable. Please try again.', { status: 502 });
  }

  if (response.result !== 100) {
    const reason = REQUEST_RESULTS[response.result] ?? 'unknown result';
    console.error(`payment request failed: ${response.result} ${reason}`);
    return new NextResponse('Could not start the payment.', { status: 502 });
  }
  if (!Number.isSafeInteger(response.trackId)) {
    console.error('trackId is outside the safe integer range');
    return new NextResponse('Could not start the payment.', { status: 502 });
  }

  await db.payment.create({
    data: { orderId, trackId: String(response.trackId), amount: BigInt(amount), mode },
  });

  // 303 from a form post keeps the browser on a same-site Referer, which Zibal requires.
  return NextResponse.redirect(`${ZIBAL_BASE}/start/${response.trackId}`, 303);
}
```

**`app/api/pay/route.ts`**

```ts
import { createPayment } from '@/lib/create-payment';

export async function POST(request: Request) {
  return createPayment(request, 'standard');
}
```

**`app/api/pay/lazy/route.ts`**

```ts
import { createPayment } from '@/lib/create-payment';

export async function POST(request: Request) {
  return createPayment(request, 'lazy');
}
```

**`app/api/payment/callback/route.ts`**

```ts
import { NextRequest, NextResponse } from 'next/server';
import { findByTrackId, settle } from '@/lib/zibal';

// Standard callback: GET with a query string.
export async function GET(request: NextRequest) {
  const payment = await findByTrackId(request.nextUrl.searchParams.get('trackId'));
  if (!payment) return new NextResponse('Unknown payment', { status: 404 });
  await settle(payment);
  return NextResponse.redirect(`${process.env.APP_URL}/payment/result/${payment.orderId}`, 303);
}

// Lazy callback: POST with a JSON body.
export async function POST(request: NextRequest) {
  const body = await request.json().catch(() => null);
  const payment = await findByTrackId(body?.trackId);
  if (!payment) return NextResponse.json({ error: 'unknown payment' }, { status: 404 });
  // To decline a lazy payment, return here without calling settle.
  // Zibal returns the money to the card 20 minutes after payment.
  return NextResponse.json({ status: await settle(payment) });
}
```

**`app/payment/result/[orderId]/page.tsx`**

```tsx
import { notFound } from 'next/navigation';
import { db } from '@/lib/db';

const MESSAGES: Record<string, string> = {
  paid: 'Payment successful.',
  failed: 'Payment failed or was cancelled.',
  pending: 'We are still confirming your payment.',
  needs_review: 'Your payment is being reviewed. Please contact support.',
};

// The result page reads the database, never the callback parameters.
export default async function PaymentResult({
  params,
}: {
  params: Promise<{ orderId: string }>;
}) {
  const { orderId } = await params;
  const payment = await db.payment.findUnique({ where: { orderId } });
  if (!payment) notFound();
  return <p>{MESSAGES[payment.status]}</p>;
}
```

**Checkout form.** The payer must leave from a page on your site so the browser sends `Referer`:

```tsx
export default function Checkout() {
  return (
    <form method="post" action="/api/pay">
      <input type="hidden" name="product" value="basic" />
      <button type="submit">Pay</button>
    </form>
  );
}
```

## Notes

- Delete `app/api/pay/lazy/route.ts` and the callback's `POST` handler if you do not use lazy mode.
- If you set a `Referrer-Policy` header in `next.config` or middleware, do not use `no-referrer` or `same-origin` on the checkout page. Either one removes the `Referer` Zibal requires.
- Serverless platforms can time out during a slow verify. Check the function limit is above the combined timeout and retries.
- Add a scheduled job that calls `settle` on `pending` rows older than a few minutes. For lazy payments it must run well inside the 20-minute limit.
