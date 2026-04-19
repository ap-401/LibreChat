#!/usr/bin/env bash
# build-frontend.sh — Build the React frontend and sync assets to S3
#
# Usage: ./build-frontend.sh [environment]
#   environment: dev | staging | prod (default: dev)
#
# This script:
#   1. Installs dependencies with npm ci
#   2. Builds the frontend with npm run frontend (Vite)
#   3. Looks up the frontend S3 bucket from CloudFormation stack outputs
#   4. Syncs client/dist/ to the S3 bucket (with --delete to remove stale files)
#
# Requirements: 1.1

set -euo pipefail

ENV="${1:-dev}"
STACK_NAME="librechat-${ENV}"

echo "==> Building frontend for environment: ${ENV}"

# ── Step 1: Install dependencies ────────────────────────────────────────────
echo "==> Installing dependencies (npm ci)..."
npm ci

# ── Step 2: Build the React frontend ────────────────────────────────────────
echo "==> Building frontend (npm run frontend)..."
npm run frontend

# ── Step 3: Look up the frontend S3 bucket name from CloudFormation outputs ─
echo "==> Looking up FrontendBucketName from stack: ${STACK_NAME}..."
BUCKET_NAME=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --query "Stacks[0].Outputs[?OutputKey=='FrontendBucketName'].OutputValue" \
  --output text)

if [[ -z "${BUCKET_NAME}" || "${BUCKET_NAME}" == "None" ]]; then
  echo "ERROR: Could not find FrontendBucketName output in stack ${STACK_NAME}" >&2
  exit 1
fi

echo "==> Frontend bucket: ${BUCKET_NAME}"

# ── Step 4: Sync built assets to S3 ─────────────────────────────────────────
echo "==> Syncing client/dist/ to s3://${BUCKET_NAME}/ ..."
aws s3 sync client/dist/ "s3://${BUCKET_NAME}/" --delete

echo "==> Frontend build and sync complete."
