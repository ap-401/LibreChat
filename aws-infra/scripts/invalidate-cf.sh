#!/usr/bin/env bash
# invalidate-cf.sh — Invalidate the CloudFront distribution cache
#
# Usage: ./invalidate-cf.sh [environment]
#   environment: dev | staging | prod (default: dev)
#
# This script:
#   1. Looks up the CloudFront distribution ID from CloudFormation stack outputs
#   2. Creates a cache invalidation for all paths (/*) to ensure fresh content
#
# Requirements: 1.7

set -euo pipefail

ENV="${1:-dev}"
STACK_NAME="librechat-${ENV}"

echo "==> Invalidating CloudFront cache for environment: ${ENV}"

# ── Step 1: Look up CloudFront distribution ID from stack outputs ───────────
echo "==> Looking up CloudFrontDistributionId from stack: ${STACK_NAME}..."
DISTRIBUTION_ID=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --query "Stacks[0].Outputs[?OutputKey=='CloudFrontDistributionId'].OutputValue" \
  --output text)

if [[ -z "${DISTRIBUTION_ID}" || "${DISTRIBUTION_ID}" == "None" ]]; then
  echo "ERROR: Could not find CloudFrontDistributionId output in stack ${STACK_NAME}" >&2
  exit 1
fi

echo "==> Distribution ID: ${DISTRIBUTION_ID}"

# ── Step 2: Create invalidation for all paths ───────────────────────────────
echo "==> Creating invalidation for /*..."
INVALIDATION_ID=$(aws cloudfront create-invalidation \
  --distribution-id "${DISTRIBUTION_ID}" \
  --paths "/*" \
  --query "Invalidation.Id" \
  --output text)

echo "==> Invalidation created: ${INVALIDATION_ID}"
echo "==> CloudFront cache invalidation initiated successfully."
