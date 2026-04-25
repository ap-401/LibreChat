#!/usr/bin/env bash
# sync-secrets.sh — Auto-populate Secrets Manager with infrastructure outputs
#
# Usage: ./sync-secrets.sh [environment] [--profile PROFILE]
#   environment: dev | staging | prod (default: dev)
#   --profile:   AWS CLI profile name (optional)
#
# This script:
#   1. Reads the current secret from Secrets Manager
#   2. Fetches DocumentDB and ElastiCache endpoints from CloudFormation outputs
#   3. Generates secure random values for any keys still set to placeholders
#   4. Assembles MONGO_URI and REDIS_URI from infrastructure endpoints + credentials
#   5. Patches the secret with the updated values
#
# Keys that are NOT overwritten if they've already been changed from placeholders:
#   OPENAI_API_KEY, ANTHROPIC_API_KEY, GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET,
#   EMAIL_FROM
#
# Run this once after initial deployment, or after any infrastructure change
# that affects endpoints.

set -euo pipefail

ENV="${1:-dev}"
shift || true
PROFILE_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE_ARG="--profile $2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

STACK_NAME="librechat-${ENV}"
SECRET_NAME="librechat/${ENV}/secrets"

echo "==> Syncing secrets for environment: ${ENV}"

# ── Helper: generate a random alphanumeric string ────────────────────────────
gen_random() {
  local len="${1:-32}"
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${len}"
}

# ── Step 1: Fetch current secret ────────────────────────────────────────────
echo "==> Reading current secret: ${SECRET_NAME}..."
CURRENT_SECRET=$(aws secretsmanager get-secret-value \
  ${PROFILE_ARG} \
  --secret-id "${SECRET_NAME}" \
  --query "SecretString" \
  --output text)

# ── Step 2: Fetch infrastructure endpoints from stack outputs ────────────────
echo "==> Fetching stack outputs from: ${STACK_NAME}..."

get_output() {
  local key="$1"
  aws cloudformation describe-stacks \
    ${PROFILE_ARG} \
    --stack-name "${STACK_NAME}" \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue" \
    --output text 2>/dev/null || echo ""
}

DOCDB_ENDPOINT=$(get_output "DocumentDBEndpoint")
ELASTICACHE_ENDPOINT=$(get_output "ElastiCacheEndpoint")

echo "  DocumentDB endpoint: ${DOCDB_ENDPOINT:-NOT FOUND}"
echo "  ElastiCache endpoint: ${ELASTICACHE_ENDPOINT:-NOT FOUND}"

# ── Step 3: Merge and patch the secret using Node.js ─────────────────────────
echo "==> Generating updated secret values..."

UPDATED_SECRET=$(CURRENT_SECRET="${CURRENT_SECRET}" \
  DOCDB_ENDPOINT="${DOCDB_ENDPOINT}" \
  ELASTICACHE_ENDPOINT="${ELASTICACHE_ENDPOINT}" \
  node -e "
const crypto = require('crypto');

const secret = JSON.parse(process.env.CURRENT_SECRET);
const docdbEndpoint = process.env.DOCDB_ENDPOINT;
const redisEndpoint = process.env.ELASTICACHE_ENDPOINT;

function isPlaceholder(val) {
  return !val || val.startsWith('placeholder');
}

function genRandom(len) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  let result = '';
  const bytes = crypto.randomBytes(len);
  for (let i = 0; i < len; i++) result += chars[bytes[i] % chars.length];
  return result;
}

// Generate secure random values for placeholder secrets
if (isPlaceholder(secret.DOCDB_PASSWORD)) secret.DOCDB_PASSWORD = genRandom(32);
if (isPlaceholder(secret.REDIS_AUTH_TOKEN)) secret.REDIS_AUTH_TOKEN = genRandom(32);
if (isPlaceholder(secret.JWT_SECRET)) secret.JWT_SECRET = genRandom(64);
if (isPlaceholder(secret.JWT_REFRESH_SECRET)) secret.JWT_REFRESH_SECRET = genRandom(64);
if (isPlaceholder(secret.CREDS_KEY)) secret.CREDS_KEY = genRandom(32);
if (isPlaceholder(secret.CREDS_IV)) secret.CREDS_IV = genRandom(16);
if (isPlaceholder(secret.MEILI_MASTER_KEY)) secret.MEILI_MASTER_KEY = genRandom(32);

// Assemble MONGO_URI from endpoint + credentials
if (docdbEndpoint) {
  const user = encodeURIComponent(secret.DOCDB_USERNAME || 'librechat');
  const pass = encodeURIComponent(secret.DOCDB_PASSWORD);
  secret.MONGO_URI = 'mongodb://' + user + ':' + pass + '@' + docdbEndpoint + ':27017/LibreChat?tls=true&retryWrites=false';
  console.error('  Updated MONGO_URI');
}

// Assemble REDIS_URI from endpoint + auth token
if (redisEndpoint) {
  const token = encodeURIComponent(secret.REDIS_AUTH_TOKEN);
  secret.REDIS_URI = 'rediss://:' + token + '@' + redisEndpoint + ':6379';
  console.error('  Updated REDIS_URI');
}

process.stdout.write(JSON.stringify(secret));
")

# ── Step 4: Write updated secret back ────────────────────────────────────────
echo "==> Updating secret in Secrets Manager..."
aws secretsmanager put-secret-value \
  ${PROFILE_ARG} \
  --secret-id "${SECRET_NAME}" \
  --secret-string "${UPDATED_SECRET}"

echo "==> Secret sync complete."
echo ""
echo "NOTE: The following keys still need manual configuration if not yet set:"
echo "  - OPENAI_API_KEY"
echo "  - ANTHROPIC_API_KEY"
echo "  - GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET"
echo "  - EMAIL_FROM"
