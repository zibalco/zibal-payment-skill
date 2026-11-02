# Zibal payment gateway (IPG) for coding agents

<!-- skills.sh badge: replace after the skill is listed -->
[![skills.sh](https://img.shields.io/badge/skills.sh-zibal--ipg-blue)](https://skills.sh)

[فارسی](#فارسی) | [English](#english)

## فارسی

<div dir="rtl">

این مخزن فقط برای درگاه پرداخت اینترنتی زیبال است و به ایجنت‌های برنامه‌نویسی (Claude Code، Cursor، Codex و ...) کمک می‌کند این درگاه را درست و امن به پروژه شما اضافه کنند.

### چه کاری انجام می‌دهد؟

- پیاده‌سازی کامل مسیر پرداخت: درخواست پرداخت، هدایت به درگاه، Callback، تایید سمت سرور و استعلام
- پشتیبانی از روش Lazy و تسهیم
- جلوگیری از اشتباهات رایج: اعتماد به `success=1` در Callback، تحویل دوباره سفارش، خطای ریال و تومان، و نبود هدر `Referer`
- نمونه کد کامل برای Express، Next.js، Laravel، Django و FastAPI؛ برای فریم‌ورک‌های دیگر، نزدیک‌ترین نمونه تطبیق داده می‌شود
- توضیح همه کدهای نتیجه و وضعیت، به‌همراه اقدام لازم برای هر کد

### نصب

</div>

```bash
npx skills add zibalco/zibal-payment-skill
```

<div dir="rtl">

### نمونه درخواست‌ها

بعد از نصب، کافی است از ایجنت خود بخواهید:

- «درگاه پرداخت زیبال را به این پروژه اضافه کن.»
- «برای صفحه تسویه حساب، پرداخت با زیبال بگذار و بعد از تایید، سفارش را پرداخت‌شده کن.»
- «تایید پرداخت زیبال با خطای 202 برمی‌گردد، مشکل را پیدا کن.»
- «کاربر به درگاه منتقل نمی‌شود، بررسی کن.»
- «کد پرداخت زیبال این پروژه را از نظر امنیتی بررسی کن.»

### تست

برای تست از حساب تستی مستندات زیبال استفاده می‌شود و به هیچ کلید خصوصی نیاز ندارد:

</div>

```bash
bash scripts/sandbox-test.sh
```

<div dir="rtl">

کلید واقعی `merchant` را فقط در متغیر محیطی `ZIBAL_MERCHANT` روی سرور نگه دارید و هرگز آن را در مخزن کد ثبت نکنید.

</div>

## English

This repository is only for the Zibal internet payment gateway. It helps coding agents (Claude Code, Cursor, Codex and others) integrate the gateway into your project correctly and securely.

### What it does

- Implements the full payment flow: payment request, redirect, callback, server-side verify, and inquiry
- Covers lazy mode and revenue sharing
- Prevents the common mistakes: trusting `success=1` in the callback, double fulfilment, Rial/Toman errors, and a missing `Referer` header
- Includes complete examples for Express, Next.js, Laravel, Django and FastAPI, and adapts the closest one for other stacks
- Documents every result and status code with the action to take

### Install

```bash
npx skills add zibalco/zibal-payment-skill
```

### Example prompts

After installing, ask your agent:

- "Add the Zibal payment gateway to this project."
- "Add Zibal payment to the checkout page and mark the order paid after verification."
- "Zibal verify keeps returning 202. Find the problem."
- "Users are not reaching the payment page. Investigate."
- "Review this project's Zibal payment code for security issues."

### Testing

Tests use the test account from Zibal's docs, so no private key is needed:

```bash
bash scripts/sandbox-test.sh
```

Keep your real `merchant` only in the `ZIBAL_MERCHANT` environment variable on the server, and never commit it.

## Repository layout

- [SKILL.md](SKILL.md): instructions the agent follows
- [references/](references/): API, result codes, callback and security references
- [examples/](examples/): complete framework examples
- [scripts/sandbox-test.sh](scripts/sandbox-test.sh): smoke test

## License

[MIT](LICENSE)
