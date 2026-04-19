/**
 * HelloWorldMCP — Placeholder MCP Lambda function.
 *
 * Demonstrates the stateless MCP pattern:
 *   - Reads/writes shared state to ElastiCache (Redis/Valkey)
 *   - Retrieves secrets from Secrets Manager at cold start
 *   - Invoked by the API Lambda via Function URL with IAM auth (SigV4)
 */

'use strict';

const {
  SecretsManagerClient,
  GetSecretValueCommand,
} = require('@aws-sdk/client-secrets-manager');

// ── Cold-start secret loading ───────────────────────────────────────────────
let secrets;

async function loadSecrets() {
  if (secrets) return secrets;
  const client = new SecretsManagerClient({});
  const { SecretString } = await client.send(
    new GetSecretValueCommand({ SecretId: process.env.SECRET_ARN }),
  );
  secrets = JSON.parse(SecretString);
  return secrets;
}

// ── Handler ─────────────────────────────────────────────────────────────────
exports.handler = async (event) => {
  try {
    const appSecrets = await loadSecrets();

    // The REDIS_URI from Secrets Manager would be used to connect to
    // ElastiCache for any shared state. This placeholder simply echoes
    // the request to prove the wiring works.
    const body = event.body ? JSON.parse(event.body) : {};

    return {
      statusCode: 200,
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        message: 'HelloWorldMCP is alive',
        environment: process.env.ENVIRONMENT,
        echo: body,
        hasRedisUri: !!appSecrets.REDIS_URI,
        timestamp: new Date().toISOString(),
      }),
    };
  } catch (err) {
    console.error('[HelloWorldMCP] Error:', err);
    return {
      statusCode: 500,
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ error: 'Internal server error' }),
    };
  }
};
