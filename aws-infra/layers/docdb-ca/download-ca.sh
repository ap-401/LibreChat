#!/usr/bin/env bash
# Downloads the AWS RDS combined CA bundle and places it in the layer content directory.
# Run this script before `sam build` to ensure the CA bundle is present.
# The bundle is placed at nodejs/rds-combined-ca-bundle.pem so Lambda exposes it at
# /opt/rds-combined-ca-bundle.pem (the /opt prefix is added by the Lambda runtime).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${SCRIPT_DIR}/nodejs/rds-combined-ca-bundle.pem"

mkdir -p "${SCRIPT_DIR}/nodejs"

echo "Downloading rds-combined-ca-bundle.pem..."
curl -fsSL \
  "https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem" \
  -o "${DEST}"

echo "CA bundle written to ${DEST}"
