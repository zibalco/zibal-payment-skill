#!/usr/bin/env bash
#
# Smoke test against Zibal's documented test account (merchant: zibal).
# It creates unpaid sessions and confirms each API answers as documented.
# It never uses ZIBAL_MERCHANT, so it cannot touch a real gateway.
#
# Usage: bash sandbox-test.sh
# Optional env: ZIBAL_TEST_CALLBACK_URL (default: the sample URL from the docs)
#
# A paid path cannot be tested here: paying needs a browser on /start/{trackId}.

set -euo pipefail

BASE_URL="https://gateway.zibal.ir"
MERCHANT="zibal"
AMOUNT=160000
CALLBACK_URL="${ZIBAL_TEST_CALLBACK_URL:-https://zibal.ir/callback}"
FAILED=0

post() {
  curl --silent --show-error --max-time 15 \
    --request POST "${BASE_URL}$1" \
    --header 'Content-Type: application/json' \
    --data "$2"
}

# Reads a top-level integer field from a flat JSON response.
field() {
  printf '%s' "$1" | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*-?[0-9]+" | head -n 1 | grep -oE -- '-?[0-9]+$' || true
}

check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ok    ${label}: ${actual}"
  else
    echo "  FAIL  ${label}: expected ${expected}, got '${actual}'"
    FAILED=1
  fi
}

run_flow() {
  local name="$1" request_path="$2" verify_path="$3" response track_id

  echo "== ${name}: POST ${request_path}"
  response="$(post "$request_path" "{\"merchant\":\"${MERCHANT}\",\"amount\":${AMOUNT},\"callbackUrl\":\"${CALLBACK_URL}\",\"description\":\"sandbox smoke test\",\"orderId\":\"smoke-$(date +%s)-${name}\"}")"
  check "result" 100 "$(field "$response" result)"
  track_id="$(field "$response" trackId)"
  if [ -z "$track_id" ]; then
    echo "  FAIL  no trackId in response: ${response}"
    FAILED=1
    return
  fi
  echo "  trackId: ${track_id}"
  echo "  start URL: ${BASE_URL}/start/${track_id}"

  echo "== ${name}: POST /v1/inquiry"
  response="$(post /v1/inquiry "{\"merchant\":\"${MERCHANT}\",\"trackId\":${track_id}}")"
  check "result" 100 "$(field "$response" result)"
  check "status (awaiting payment)" -1 "$(field "$response" status)"
  check "amount" "$AMOUNT" "$(field "$response" amount)"

  echo "== ${name}: POST ${verify_path} (unpaid session)"
  response="$(post "$verify_path" "{\"merchant\":\"${MERCHANT}\",\"trackId\":${track_id}}")"
  check "result (unpaid or failed)" 202 "$(field "$response" result)"
}

run_flow standard /v1/request /v1/verify
run_flow lazy /request/lazy /verify

echo "== invalid trackId: POST /v1/verify"
response="$(post /v1/verify "{\"merchant\":\"${MERCHANT}\",\"trackId\":1}")"
check "result (invalid trackId)" 203 "$(field "$response" result)"

echo "== amount below minimum: POST /v1/request"
response="$(post /v1/request "{\"merchant\":\"${MERCHANT}\",\"amount\":500,\"callbackUrl\":\"${CALLBACK_URL}\"}")"
check "result (amount below 1,000 Rials)" 105 "$(field "$response" result)"

if [ "$FAILED" -ne 0 ]; then
  echo "Smoke test FAILED."
  exit 1
fi
echo "Smoke test passed."
