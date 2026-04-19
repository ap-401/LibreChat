#!/usr/bin/env bash
# seed-docdb.sh — Seed DocumentDB with the LibreChat database and indexes
#
# Usage: ./seed-docdb.sh [environment]
#   environment: dev | staging | prod (default: dev)
#
# This script:
#   1. Retrieves MONGO_URI from Secrets Manager (librechat/{env}/secrets)
#   2. Connects to DocumentDB using a Node.js script
#   3. Creates the LibreChat database and required indexes idempotently
#
# Prerequisites:
#   - Network access to DocumentDB (run from a bastion host, VPC-connected
#     environment, or CI runner with VPC connectivity)
#   - Node.js and npm available
#   - The mongoose package (installed via npm ci at repo root)
#
# Requirements: 3.6

set -euo pipefail

ENV="${1:-dev}"
SECRET_NAME="librechat/${ENV}/secrets"

echo "==> Seeding DocumentDB for environment: ${ENV}"

# ── Step 1: Retrieve MONGO_URI from Secrets Manager ─────────────────────────
echo "==> Retrieving MONGO_URI from Secrets Manager (${SECRET_NAME})..."
MONGO_URI=$(aws secretsmanager get-secret-value \
  --secret-id "${SECRET_NAME}" \
  --query "SecretString" \
  --output text | node -e "
    const input = require('fs').readFileSync('/dev/stdin', 'utf8');
    const secrets = JSON.parse(input);
    process.stdout.write(secrets.MONGO_URI);
  ")

if [[ -z "${MONGO_URI}" ]]; then
  echo "ERROR: Could not retrieve MONGO_URI from secret ${SECRET_NAME}" >&2
  exit 1
fi

echo "==> MONGO_URI retrieved successfully."

# ── Step 2: Create database and indexes idempotently via Node.js ─────────────
echo "==> Creating LibreChat database and indexes..."
MONGO_URI="${MONGO_URI}" node -e "
const mongoose = require('mongoose');

async function seed() {
  console.log('Connecting to DocumentDB...');
  await mongoose.connect(process.env.MONGO_URI, {
    dbName: 'LibreChat',
    // DocumentDB does not support retryable writes
    retryWrites: false,
  });

  const db = mongoose.connection.db;
  console.log('Connected. Creating indexes...');

  // Users collection indexes
  await db.collection('users').createIndex({ email: 1 }, { unique: true, background: true });
  await db.collection('users').createIndex({ username: 1 }, { unique: true, sparse: true, background: true });
  console.log('  ✓ users indexes');

  // Conversations collection indexes
  await db.collection('conversations').createIndex({ user: 1, updatedAt: -1 }, { background: true });
  await db.collection('conversations').createIndex({ conversationId: 1 }, { unique: true, background: true });
  console.log('  ✓ conversations indexes');

  // Messages collection indexes
  await db.collection('messages').createIndex({ conversationId: 1, createdAt: 1 }, { background: true });
  await db.collection('messages').createIndex({ messageId: 1 }, { unique: true, background: true });
  await db.collection('messages').createIndex({ user: 1 }, { background: true });
  console.log('  ✓ messages indexes');

  // Sessions collection indexes
  await db.collection('sessions').createIndex({ expireAt: 1 }, { expireAfterSeconds: 0, background: true });
  await db.collection('sessions').createIndex({ user: 1 }, { background: true });
  console.log('  ✓ sessions indexes');

  // Presets collection indexes
  await db.collection('presets').createIndex({ user: 1 }, { background: true });
  await db.collection('presets').createIndex({ presetId: 1 }, { unique: true, sparse: true, background: true });
  console.log('  ✓ presets indexes');

  // Transactions / balance collection indexes
  await db.collection('transactions').createIndex({ user: 1, createdAt: -1 }, { background: true });
  await db.collection('balances').createIndex({ user: 1 }, { unique: true, background: true });
  console.log('  ✓ transactions/balances indexes');

  await mongoose.disconnect();
  console.log('Seed complete.');
}

seed().catch((err) => {
  console.error('Seed failed:', err.message);
  process.exit(1);
});
" 

echo "==> DocumentDB seeding complete."
