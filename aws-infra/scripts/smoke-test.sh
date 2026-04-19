#!/usr/bin/env bash
# smoke-test.sh — Post-deployment smoke tests for LibreChat
#
# Usage: ./smoke-test.sh [environment]
#   environment: dev | staging | prod (default: dev)
#
# This script verifies the deployment is healthy by running:
#   1. GET /health → assert HTTP 200
#   2. GET / via CloudFront → assert HTTP 200 and index.html content
#   3. GET /api/config → assert HTTP 200 and valid JSON body
#   4. HTTP GET / → assert redirect to HTTPS (301/302)
#
# Exits non-zero on any failure.
#
# Requirements: 12.3

set -euo pipefail

ENV="${1:-dev}"
STACK_NAME="librechat-${ENV}"
FAILURES=0

echo "==> Running smoke tests for environment: ${ENV}"

# ── Fetch stack outputs ──────────────────────────────────────────────────────
echo "==> Looking up stack outputs from: ${STACK_NAME}..."

CF_URL=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --query "Stacks[0].Outputs[?OutputKey=='CloudFrontURL'].OutputValue" \
  --output text)

API_URL=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --query "Stacks[0].Outputs[?OutputKey=='APIGatewayURL'].OutputValue" \
  --output text)

if [[ -z "${CF_URL}" || "${CF_URL}" == "None" ]]; then
  echo "ERROR: Could not find CloudFrontURL output in stack ${STACK_NAME}" >&2
  exit 1
fi

if [[ -z "${API_URL}" || "${API_URL}" == "None" ]]; then
  echo "ERROR: Could not find APIGatewayURL output in stack ${STACK_NAME}" >&2
  exit 1
fi

echo "  CloudFront URL: ${CF_URL}"
echo "  API Gateway URL: ${API_URL}"

# ── Helper: run a single test ────────────────────────────────────────────────
run_test() {
  local name="$1"
  local result="$2"  # pass or fail
  local detail="$3"

  if [[ "${result}" == "pass" ]]; then
    echo "  ✓ ${name}"
  else
    echo "  ✗ ${name}: ${detail}" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

# ── Test 1: GET /health → HTTP 200 ──────────────────────────────────────────
echo ""
echo "==> Test 1: GET /health"
HEALTH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${API_URL}/health" --max-time 15 || echo "000")

if [[ "${HEALTH_STATUS}" == "200" ]]; then
  run_test "GET /health → 200" "pass" ""
else
  run_test "GET /health → 200" "fail" "got HTTP ${HEALTH_STATUS}"
fi

# ── Test 2: GET / via CloudFront → HTTP 200 + index.html content ────────────
echo ""
echo "==> Test 2: GET / via CloudFront"
CF_RESPONSE=$(curl -s -w "\n%{http_code}" "${CF_URL}/" --max-time 15 || echo -e "\n000")
CF_BODY=$(echo "${CF_RESPONSE}" | head -n -1)
CF_STATUS=$(echo "${CF_RESPONSE}" | tail -n 1)

if [[ "${CF_STATUS}" == "200" ]]; then
  # Check that the response contains index.html markers (e.g. <html, <div id="root")
  if echo "${CF_BODY}" | grep -qi "</html>"; then
    run_test "GET / via CloudFront → 200 with HTML content" "pass" ""
  else
    run_test "GET / via CloudFront → 200 with HTML content" "fail" "got 200 but response does not contain HTML"
  fi
else
  run_test "GET / via CloudFront → 200 with HTML content" "fail" "got HTTP ${CF_STATUS}"
fi

# ── Test 3: GET /api/config → HTTP 200 + valid JSON ─────────────────────────
echo ""
echo "==> Test 3: GET /api/config"
CONFIG_RESPONSE=$(curl -s -w "\n%{http_code}" "${CF_URL}/api/config" --max-time 15 || echo -e "\n000")
CONFIG_BODY=$(echo "${CONFIG_RESPONSE}" | head -n -1)
CONFIG_STATUS=$(echo "${CONFIG_RESPONSE}" | tail -n 1)

if [[ "${CONFIG_STATUS}" == "200" ]]; then
  # Validate the body is valid JSON
  if echo "${CONFIG_BODY}" | node -e "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'))" 2>/dev/null; then
    run_test "GET /api/config → 200 with valid JSON" "pass" ""
  else
    run_test "GET /api/config → 200 with valid JSON" "fail" "got 200 but body is not valid JSON"
  fi
else
  run_test "GET /api/config → 200 with valid JSON" "fail" "got HTTP ${CONFIG_STATUS}"
fi

# ── Test 4: HTTP GET / → redirect to HTTPS (301/302) ────────────────────────
echo ""
echo "==> Test 4: HTTP → HTTPS redirect"
# Strip https:// and build an http:// URL for the redirect test
CF_HOST="${CF_URL#https://}"
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://${CF_HOST}/" --max-time 15 -L --max-redirs 0 2>/dev/null || echo "000")

if [[ "${HTTP_STATUS}" == "301" || "${HTTP_STATUS}" == "302" ]]; then
  run_test "HTTP → HTTPS redirect (${HTTP_STATUS})" "pass" ""
else
  run_test "HTTP → HTTPS redirect" "fail" "expected 301 or 302, got HTTP ${HTTP_STATUS}"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
if [[ "${FAILURES}" -gt 0 ]]; then
  echo "==> SMOKE TESTS FAILED: ${FAILURES} test(s) failed." >&2
  exit 1
else
  echo "==> All smoke tests passed."
  exit 0
fi
