/**
 * init-secrets.js — cold-start secret loader
 *
 * Loaded via NODE_OPTIONS=--require /opt/nodejs/init-secrets.js before the
 * Lambda handler module is evaluated. Fetches the JSON secret from Secrets
 * Manager and merges every key into process.env so the Express app sees them
 * as ordinary environment variables.
 *
 * Fails fast (process.exit(1)) if the secret cannot be loaded, which causes
 * Lambda to discard the execution environment and retry on the next invocation.
 *
 * Uses @aws-sdk/client-secrets-manager (AWS SDK v3).
 *
 * Requirements: 2.6, 6.2
 */

'use strict';

const { SecretsManagerClient, GetSecretValueCommand } = require('@aws-sdk/client-secrets-manager');
const { spawnSync } = require('child_process');

const secretArn = process.env.SECRET_ARN;

if (!secretArn) {
  console.error('[FATAL] SECRET_ARN environment variable is not set');
  process.exit(1);
}

// Run the async secret fetch in a child process so we can block synchronously.
// The child writes the secret JSON to stdout; we parse it and merge into process.env.
const inlineScript = `
const { SecretsManagerClient, GetSecretValueCommand } = require('@aws-sdk/client-secrets-manager');
const client = new SecretsManagerClient({ region: process.env.AWS_REGION || 'us-east-1' });
client.send(new GetSecretValueCommand({ SecretId: process.env.SECRET_ARN }))
  .then(r => { process.stdout.write(r.SecretString); })
  .catch(err => { process.stderr.write(err.message); process.exit(1); });
`;

const result = spawnSync(process.execPath, ['--eval', inlineScript], {
  env: process.env,
  encoding: 'utf8',
  timeout: 10000, // 10 s — fail fast if SM is unreachable
});

if (result.status !== 0 || result.error) {
  const msg = result.stderr || (result.error && result.error.message) || 'unknown error';
  console.error('[FATAL] Failed to load secrets from Secrets Manager:', msg);
  process.exit(1);
}

let secrets;
try {
  secrets = JSON.parse(result.stdout);
} catch (parseErr) {
  console.error('[FATAL] Secret value is not valid JSON:', parseErr.message);
  process.exit(1);
}

Object.assign(process.env, secrets);
