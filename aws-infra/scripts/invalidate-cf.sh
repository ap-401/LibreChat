#!/usr/bin/env bash
# invalidate-cf.sh — Invalidate the CloudFront distribution cache
#
# Usage: ./invalidate-cf.sh [environment] [--profile PROFILE]
#   environment: dev | staging | prod (default: dev)
#   --profile:   AWS CLI profile name (optional)
#
# This script:
#   1. Looks up the CloudFront distribution ID from CloudFormation stack outputs
#   2. Creates a cache invalidation for all paths (/*) to ensure fresh content

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

echo "==> Invalidating CloudFront cache for environment: ${ENV}"

# ── Step 1: Look up CloudFront distribution ID from stack outputs ───────────
echo "==> Looking up CloudFrontDistributionId from stack: ${STACK_NAME}..."
DISTRIBUTION_ID=$(aws cloudformation describe-stacks \
  ${PROFILE_ARG} \
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
  ${PROFILE_ARG} \
  --distribution-id "${DISTRIBUTION_ID}" \
  --paths "/*" \
  --query "Invalidation.Id" \
  --output text)

echo "==> Invalidation created: ${INVALIDATION_ID}"
echo "==> CloudFront cache invalidation initiated successfully."
